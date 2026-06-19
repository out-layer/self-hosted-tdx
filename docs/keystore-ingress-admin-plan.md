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

> ⚠️ **Security caveat to decide on (Part 2):** Phala terminates TLS *inside* an attested CVM
> (gateway). A host nginx terminates TLS *outside* the TEE → decrypted tokens/secrets transit
> host memory between nginx and the CVM. This is a genuine confidentiality reduction vs Phala —
> it's the substance of the "keystore migrates last / needs gateway" note. Mitigations: bind the
> CVM's 8081 to **loopback only** (nginx-only reach), and/or later terminate TLS inside the CVM.
> For now: accept it as the self-hosted trust model + document loudly. (Decide before mainnet.)

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

## Part 2 — nginx ingress: stable domain + TLS + multiple keystores

### 2.1 Prereqs (USER provides)
- DNS: `testnet-keystore.outlayer.ai` (and `mainnet-keystore.outlayer.ai`) A-record → the node's
  public IP.
- TLS cert + key for those names (user supplies; or Let's Encrypt via certbot if port 80 reachable).
- Decide the canonical names (confirm `.outlayer.ai`).

### 2.2 Keystore CVM port exposure
`40-deploy-keystore.sh` maps CVM:8081 → `127.0.0.1:<KS_PORT>` (loopback). Each keystore instance
gets its own free `<KS_PORT>` (collision-safe, like the worker agent-port finder). NOT WAN-bound —
nginx is the only public listener.

### 2.3 nginx (host) + switch
- Install nginx on the node. `server { listen 443 ssl; server_name testnet-keystore.outlayer.ai;
  ssl_certificate/key …; location / { proxy_pass http://127.0.0.1:<KS_PORT>; proxy_set_header … } }`.
- **Multiple keystores + switch (recommended: active-backend switch).** One canonical URL
  (`testnet-keystore.outlayer.ai`) whose nginx upstream points at the *active* keystore's
  `<KS_PORT>`. A `keystore-switch.sh <cvm-name>` rewrites the upstream + `nginx -s reload` —
  transparent to workers/coordinator (KEYSTORE_BASE_URL unchanged). Keep N keystores running on
  distinct ports; switch the backend instantly. (Alt: per-keystore subpaths/subdomains if you want
  to address each by URL — document both, default to active-backend.)
- `KEYSTORE_BASE_URL=https://testnet-keystore.outlayer.ai` → set in the **execution worker** env
  (`.env.<net>-worker-tdx`) + given to the coordinator.
- Firewall (iptables): open 443 WAN; keep vmm(11000)/KMS(11001)/agent ports loopback as today.

### 2.4 Mainnet
Same pattern with `mainnet-keystore.outlayer.ai` → mainnet keystore CVM (if we run a dedicated
one — see Part 1 open Q).

---

## Part 3 — Admin web UI (worker-ctl.sh status + logs, admin-only)

### 3.1 Service (read-only first)
Small host service (Python stdlib `http.server` or Flask — node has python3) that shells out to
`worker-ctl.sh status` (lsvm table → JSON/HTML), per-worker logs (snapshot + SSE stream for
`follow`), and optionally `journalctl -u outlayer-kms-auth` (KMS boot decisions). Runs as a user
that can reach vmm + read qemu cmdlines (outlayer) on a loopback port.

### 3.2 Auth + exposure
nginx `location /admin` (or `admin.outlayer.ai`) with **HTTP Basic auth** (`htpasswd`, the admin
login/password you set) over 443 → proxy to the loopback UI service. Not reachable without creds.

### 3.3 Scope
Start **read-only** (status + logs). Defer destructive actions (restart/stop/remove) — if added
later, gate behind the same auth + explicit confirm; never expose `remove`.

### Decisions (Part 3)
- Stack: tiny Python service (recommended, minimal deps) vs Node.
- Domain/path: `admin.outlayer.ai` vs `testnet-keystore.outlayer.ai/admin`.
- Read-only vs also actions (recommend read-only v1).

---

## Part 4 — Documentation (under deploy/self-hosted-tdx/docs/)
- `keystore.md` — deploy + governance (proposal/vote) + `KEYSTORE_BASE_URL` wiring + accounts.
- `ingress.md` — nginx + domain + TLS + the multi-keystore switch + firewall + the TLS-outside-TEE
  caveat (Part 2 ⚠️).
- `admin-ui.md` — the UI + basic-auth.
- Update `README.md` + `mainnet-launch.md` (add keystore + ingress steps).

## What I need from you before executing
1. Confirm domains: `testnet-keystore.outlayer.ai` + `mainnet-keystore.outlayer.ai` (or other).
2. TLS cert+key for them (or OK to use Let's Encrypt/certbot).
3. Accept the **TLS-outside-TEE** trust reduction for self-hosted (Part 2 ⚠️), or require in-CVM
   TLS termination (bigger change).
4. Mainnet keystore: dedicated self-hosted, or reuse the existing Phala keystore?
5. Admin UI: read-only OK for v1? domain/path? login/password to set.
6. Many node changes here (nginx, firewall, new systemd services) hit the safety classifier — you
   apply them (I prepare exact configs/scripts) or add Bash permission rules so I can.

## Execution order (suggested)
1. Part 1 testnet keystore (deploy + govern, no public URL yet — reachable via loopback for a
   smoke test). 2. Part 2 nginx + testnet domain → wire `KEYSTORE_BASE_URL` into a worker, end-to-end
   secret-decrypt test. 3. Part 3 admin UI. 4. Docs. 5. Repeat Part 1+2 for mainnet.
