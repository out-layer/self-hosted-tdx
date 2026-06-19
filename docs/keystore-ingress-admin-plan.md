# Plan: self-hosted keystore + nginx ingress + admin UI

Status: PLAN (not yet executed). Written 2026-06-19. Context: the execution worker is fully
working on the self-hosted TDX node via `scripts/deploy_tdx.sh` (one-command: deploy → read
measurements → owner-approve → restart → register). This plan adds (1) the **keystore** worker,
(2) a stable **public HTTPS endpoint** for it via nginx, and (3) an **admin web UI** for
`worker-ctl.sh status`/logs. Node: `ssh root@173.237.9.76`, worker/vmm run as `outlayer`.

## Can we run the keystore the same way? — Yes, with two real differences

The keystore is a dstack CVM like the worker (KMS-encrypted env, TDX quote, same `40-deploy`
skeleton), BUT:
1. **It needs INBOUND HTTP (port 8081).** It's an axum HTTP server called by workers + the
   coordinator (`/decrypt`, `/wallet/*`, `/tee-challenge`, …); it does NOT poll. We run **no
   dstack-gateway** (workers are outbound-only), so we provide ingress with **nginx** (TLS
   terminator) → CVM:8081. On Phala this was `https://<hash>-8081.dstack-…phala.network`.
2. **Governance is a DAO proposal + vote**, not just owner-approve. The keystore self-submits
   `submit_keystore_registration` to `dao.outlayer.<net>` on boot (logs a Proposal ID); a DAO
   member (`zavodil.<net>`) must `vote(proposal_id, true)`. Plus the owner approves measurements
   (`add_approved_measurements` on the **DAO** contract, same method name as the worker uses on
   the register-contract). After approval+vote the keystore pulls its master from MPC CKD
   (`v1.signer-prod.testnet` / `v1.signer`) and becomes ready.

**Auth makes a plain nginx TLS proxy safe**: the keystore authenticates every caller itself —
Bearer token (SHA256 vs `ALLOWED_{WORKER,COORDINATOR}_TOKEN_HASHES`) + a TEE challenge-response
session (`X-TEE-Session`, bound to the caller's on-chain access key on `worker.outlayer.<net>`).
nginx needs no auth logic; it only terminates TLS and forwards.

> ✅ **HARD REQUIREMENT (user, 2026-06-19): keys/plaintext must NEVER leave the TEE.** So a host
> nginx terminating TLS is **NOT acceptable** for the keystore — it would expose decrypted
> payloads/tokens in host memory. **TLS must terminate INSIDE an attested CVM**, exactly like
> Phala's dstack-gateway does. There is no key "migration": the self-hosted keystore re-derives
> its master in-TEE from MPC CKD; we just point traffic at the new node and turn Phala off. ⇒
> **Part 2 = run a dstack-gateway CVM** (TEE TLS terminator + router), NOT host TLS termination.
> (Host nginx is still fine for the *admin UI* in Part 3 — that carries no TEE secrets.)

---

## Part 1 — Keystore worker on the TDX node

### 1.1 Env templates + compose (mirror the Phala keystore, clean)
- `deploy/self-hosted-tdx/keystore/docker-compose.yaml` — from `docker/docker-compose.keystore-phala.yml`:
  image `docker.io/outlayer/near-outlayer-keystore@sha256:…` (placeholder, digest-pinned at deploy),
  pass the env vars below, mount `/var/run/dstack.sock` (needed for the registration TDX quote),
  expose 8081.
- `deploy/self-hosted-tdx/keystore/{testnet,mainnet}-keystore.env.template` — keys (no inline
  comments — env parser keeps the whole line after `=`):
  `SERVER_HOST=0.0.0.0`, `SERVER_PORT=8081`, `NEAR_NETWORK`, `NEAR_RPC_URL=…?apiKey=<RPC_API_KEY>`,
  `OFFCHAINVM_CONTRACT_ID`, `NEAR_CONTRACT_ID`, `KEYSTORE_DAO_CONTRACT=dao.outlayer.<net>`,
  `INIT_ACCOUNT_ID=init-keystore.outlayer.<net>`, `INIT_ACCOUNT_PRIVATE_KEY=<SECRET>`,
  `ALLOWED_WORKER_TOKEN_HASHES=<sha256>`, `ALLOWED_COORDINATOR_TOKEN_HASHES=<sha256>`,
  `USE_TEE_REGISTRATION=true`, `TEE_MODE=outlayer_tee`, `OPERATOR_ACCOUNT_ID=worker.outlayer.<net>`,
  `MPC_CONTRACT_ID`, `MPC_DOMAIN_ID=2`, `MPC_PUBLIC_KEY=bls12381g2:<…>`,
  `DSTACK_SIMULATOR_ENDPOINT=/var/run/dstack.sock`, `RUST_LOG=info,keystore_worker=debug`,
  `LOG_MASTER_KEY_HASH=true`. (Do NOT set `KEYSTORE_MASTER_SECRET` — incompatible with TEE mode.)
  Real `.env.<net>-keystore-tdx` filled on the node (gitignored), like the worker.

### 1.2 `deploy/self-hosted-tdx/40-deploy-keystore.sh` (fork of 40-deploy-worker.sh)
Reuse verbatim: digest resolution (`| keystore |` row; `WORKER_DIGEST`-style override for the
gh-less node; image `outlayer/near-outlayer-keystore`), render-to-mktemp, the **/etc/hosts KMS
dance + clean-DNS reboot**, KMS-encrypted env (`compose --kms --env-file`, `deploy --kms-url`),
replace-on-redeploy, measurement harvest.
Change: **port mapping must expose 8081 inbound** → `--port "tcp:127.0.0.1:<KS_PORT>:8081"`
(LOOPBACK so only nginx reaches it; pick a free port like the worker's agent-port finder) **plus**
the loopback agent port for logs. Default resources 2 vCPU / 2G / 1G (Phala used that; resources
affect RTMR0/RTMR1 — keep constant for reuse).

### 1.3 Governance (the keystore-specific extra)
After deploy + measurement harvest, do BOTH:
1. Owner-approve measurements on the DAO: `dao.outlayer.<net> add_approved_measurements
   {measurements, clear_others:false}` signed as `owner.outlayer.<net>` (idempotent: check
   `is_measurements_approved` first). [Mac orchestrator, owner key local.]
2. Vote on the keystore's self-submitted proposal: the keystore (on boot, as
   `init-keystore.outlayer.<net>`) calls `submit_keystore_registration` → logs `Proposal ID: N`.
   Grep it from the keystore logs, then `dao.outlayer.<net> vote {proposal_id:N, approve:true}`
   signed as **`zavodil.<net>`** (auto on testnet; print the command for manual run on mainnet —
   mirror `deploy_phala.sh` step 7). Threshold = (members/2)+1 = 1 with the single member zavodil.
After the vote passes, the keystore pulls the MPC-CKD master + flips `is_ready` (`/health` 200).

### 1.4 Mac orchestrator: `scripts/deploy_tdx.sh keystore <net> [name] --version … --node …`
Currently `deploy_tdx.sh` (node-side) hard-refuses keystore — implement it. Flow:
deploy on node (1.2) → read measurements → owner-approve on DAO (1.3.1, local) → wait for the
keystore to submit its proposal (poll logs for Proposal ID) → vote as zavodil (1.3.2, local;
testnet auto, mainnet print) → poll `/health` until ready. Owner + zavodil keys stay on the Mac.

### Decisions/unknowns (Part 1)
- Reuse existing accounts `init-keystore.outlayer.<net>`, `dao.outlayer.<net>`, voter `zavodil.<net>`
  — confirm the owner has all needed keys in the legacy keychain.
- Mainnet: does the self-hosted mainnet worker reuse the **existing Phala keystore** or get a
  dedicated self-hosted one? (open Q in `docs/mainnet-launch.md`). Affects whether we deploy a
  mainnet keystore at all.
- `scripts/build_and_push_keystore_tee.sh` not yet read — we resolve a released digest instead.
- MPC dependency: the keystore needs MPC CKD (`v1.signer-prod.testnet`/`v1.signer`) reachable for
  the master-key derivation — verify it works from the node.

---

## Part 2 — Ingress: dstack-gateway CVM (TLS terminates IN the TEE)

The keystore must be reached over HTTPS where TLS terminates **inside an attested CVM** (HARD
REQUIREMENT above). The dstack-native way — and exactly what Phala did — is a **dstack-gateway
CVM**. We currently run none (`vmm.toml`: `gateway_urls=[]`; workers are outbound-only). Add one
for the keystore. A host nginx that terminates TLS is explicitly ruled out for keystore traffic.

### 2.1 RESEARCH FIRST (next agent's first ingress task) — confirm the gateway path
The gateway exists in `meta-dstack/dstack/gateway`. Determine:
- How to deploy a dstack-gateway as a CVM on our vmm (analogous to the KMS-as-CVM in
  `30-deploy-kms.sh`); how it registers with the KMS/auth-simple; how to wire `vmm.toml`
  `gateway_urls=[…]`.
- Cert/domain model: it serves **RA-TLS** (cert bound to the gateway's TEE attestation) and needs a
  **wildcard cert** for the gateway domain — obtained how? (user provides, or in-CVM ACME).
- URL scheme: Phala exposed `https://<app-id>-<port>.<gateway-domain>`. Does it support a **clean
  custom hostname** (`testnet-keystore.outlayer.ai` → a chosen app CVM:8081), or only `<app-id>-
  <port>` (then CNAME `testnet-keystore.outlayer.ai` → that host)?
- How it routes to the keystore CVM:8081 over the vmm network, and how **"switch keystores"** works
  (re-point the hostname/route at a different keystore app-id).
- Fallback option **B** (only if a full gateway is impractical): keystore serves RA-TLS itself +
  host does TCP/**SNI passthrough** (nginx `stream`, no decryption — encrypted bytes only). Default
  to **A (gateway)** — the faithful Phala model — unless B is clearly simpler and keeps TLS in-TEE.

### 2.2 Keystore CVM port exposure
The keystore CVM serves plain HTTP 8081 *internally*; the **gateway** terminates TLS and forwards to
it over the vmm network. Do **not** expose 8081 to the host/WAN in plaintext. (Under option B, the
keystore's in-CVM TLS port is exposed and the host only passes encrypted bytes through.)

### 2.3 Domain, cert, switch (user: domains = yes)
- `testnet-keystore.outlayer.ai` (+ `mainnet-keystore.outlayer.ai` later). DNS → node public IP, or
  CNAME → the gateway's `<app-id>-<port>` host (depends on 2.1).
- Wildcard/host cert for the gateway domain (user provides, or in-CVM ACME — decide in 2.1).
- **Switch keystores**: re-point the canonical hostname/route to a different keystore app-id (gateway
  config), keeping `KEYSTORE_BASE_URL` stable for workers/coordinator. Multiple keystores stay
  running; flip the route. Document once 2.1 settles the mechanism.
- `KEYSTORE_BASE_URL=https://testnet-keystore.outlayer.ai` → set in worker `.env.<net>-worker-tdx`
  + given to the coordinator.
- Firewall: open the gateway's public 443 (WAN); keep vmm(11000)/KMS(11001)/worker-agent ports
  loopback as today.

### 2.4 Mainnet
Same gateway + `mainnet-keystore.outlayer.ai` → a **dedicated** mainnet keystore (user: yes, after
testnet). One gateway can serve both nets, or one per net — decide in 2.1.

---

## Part 3 — Admin web UI (worker-ctl.sh status + logs, admin-only)

### 3.1 Service (read-only first)
Small host service (Python stdlib `http.server` or Flask — node has python3) that shells out to
`worker-ctl.sh status` (lsvm table → JSON/HTML), per-worker logs (snapshot + SSE stream for
`follow`), and optionally `journalctl -u outlayer-kms-auth` (KMS boot decisions). Runs as a user
that can reach vmm + read qemu cmdlines (outlayer) on a loopback port.

### 3.2 Auth + exposure
Host nginx serving **`workers.outlayer.ai`** (user-confirmed) over 443 with **HTTP Basic auth**
(`htpasswd`, the admin login/password the user sets) → proxy to the loopback UI service. Not
reachable without creds. This nginx DOES terminate TLS — fine here, the admin UI carries no TEE
secrets (only `lsvm` status + worker logs). Keep it a SEPARATE nginx server block from the keystore
ingress (which must stay TEE-terminated, Part 2).

### 3.3 Scope
**Read-only v1** (user-confirmed): status + logs only. Defer destructive actions
(restart/stop/remove); if ever added, gate behind the same auth + explicit confirm; never expose
`remove`.

---

## Part 4 — Documentation (under deploy/self-hosted-tdx/docs/)
- `keystore.md` — deploy + governance (proposal/vote) + `KEYSTORE_BASE_URL` wiring + accounts.
- `ingress.md` — nginx + domain + TLS + the multi-keystore switch + firewall + the TLS-outside-TEE
  caveat (Part 2 ⚠️).
- `admin-ui.md` — the UI + basic-auth.
- Update `README.md` + `mainnet-launch.md` (add keystore + ingress steps).

## Decisions (user answered 2026-06-19)
1. Domains **YES**: `testnet-keystore.outlayer.ai`, `mainnet-keystore.outlayer.ai`; admin UI =
   `workers.outlayer.ai`. User creates DNS + provides cert.
2. **TLS must terminate INSIDE the TEE** — keys never leave the TEE. ⇒ dstack-gateway CVM (Part 2);
   host TLS termination is ruled out for keystore traffic. Phala just gets turned off — there is no
   key migration (the new keystore re-derives its master in-TEE).
3. Mainnet keystore: **dedicated self-hosted**, after testnet works.
4. Admin UI: **yes**, at `workers.outlayer.ai` — host nginx + basic-auth is fine (no TEE secrets);
   read-only v1; user sets login/password.
5. Node changes (gateway CVM, firewall, admin-UI nginx, systemd): user applies, or adds Bash
   permission rules so the agent can (classifier-gated).

## Still to research / verify
- Gateway specifics (Part 2.1): cert source (user wildcard vs in-CVM ACME); URL scheme (custom
  hostname vs `<app-id>-<port>` + CNAME); routing + the keystore-switch mechanism.
- ⚠️ **KEY CONTINUITY — verify BEFORE turning Phala off (the real risk, not ingress):** does the
  self-hosted keystore derive the **same** master via MPC CKD as the Phala keystore, so it can
  **decrypt secrets already created** under Phala? The CKD master comes from the MPC
  (`v1.signer-prod.testnet` / `v1.signer`) keyed by the keystore's CKD identity. If that identity is
  tied to per-CVM measurements, a new keystore gets a **different** master → cannot read old
  secrets. Confirm the derivation is stable across keystores (read `keystore-dao-contract`
  `request_key(CKDRequestArgs)` + `keystore-worker` `mpc_ckd::initialize_mpc_keystore`) before
  relying on "turn Phala off." If it's NOT stable, existing secrets must be re-wrapped — plan that.

## Execution order (suggested)
1. Part 1 testnet keystore (deploy + govern, no public URL yet — reachable via loopback for a
   smoke test). 2. Part 2 nginx + testnet domain → wire `KEYSTORE_BASE_URL` into a worker, end-to-end
   secret-decrypt test. 3. Part 3 admin UI. 4. Docs. 5. Repeat Part 1+2 for mainnet.
