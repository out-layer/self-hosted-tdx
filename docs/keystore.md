# Keystore (self-hosted TDX) — deploy + register a keystore CVM

The keystore is an inbound axum HTTP server (`:8081`) that workers + the coordinator call to decrypt
secrets / sign. It runs as a dstack CVM, derives its master key **in-TEE from MPC CKD** after a DAO
vote approves its measurements, and is reached over HTTPS where **TLS terminates inside the attested
dstack-gateway** (the public endpoint is `https://<keystore-app-id>-8081.<gateway-domain>`).

**This is a complete standalone runbook.** Following it on a node whose base stack + gateway are up
gets you from nothing to a registered, READY keystore with a public TEE-terminated endpoint, with no
knowledge of the session that first set it up. Order: Prerequisites → Configure → Deploy → Govern
(approve + vote) → Verify → testnet+mainnet on one node → Ops → Redeploy/gotchas.

> One node can run **testnet AND mainnet keystores simultaneously** behind ONE gateway — see that
> section. Keystores are single-instance (no scaling).

---

## Prerequisites

### A. Base node + gateway up
The keystore sits on top of the full base node AND the gateway (it needs the gateway for a public
endpoint). Have these done first:

| Step | Gives the keystore |
|---|---|
| README 0–3 | TDX host + attestation + the outlayer `dstack-vmm` (`127.0.0.1:11000`) |
| README 4 + **4b** (`30-deploy-kms.sh` + `kms/apply-auth-simple.sh`) | per-node KMS + **`allowAnyApp` + `gatewayAppId`** (MANDATORY — see `gateway.md` Prereq B) |
| `gateway.md` (40-deploy-gateway.sh deploy + bootstrap) | a running gateway with a wildcard cert, and the KMS `gatewayAppId` set to the gateway's app-id |

Verify the gateway is up and the KMS trusts it (run on the node):
```bash
curl -sk -X POST 'https://127.0.0.1:11001/prpc/GetMeta?json' -d '{}' \
  | python3 -c 'import json,sys; print("KMS gateway_app_id:", json.load(sys.stdin).get("gateway_app_id"))'
# must be non-empty and equal to the live dstack-gateway app-id (worker-ctl.sh status)
```
If `gateway_app_id` is empty, the keystore will reboot-loop with `Missing allowed dstack-gateway app
id`. Re-run `40-deploy-gateway.sh deploy` (it auto-sets it) — do NOT hand-deploy the keystore first.

### B. The OS + keystore image
- `IMAGE_OS=dstack-0.5.11` must exist in the vmm image dir (`vmm-cli lsimage`).
- The keystore container image is pinned **by digest** and is Sigstore-attested. `40-deploy-keystore.sh`
  resolves the `| keystore |` digest for the chosen `--version` from the GitHub release. On a node
  **without `gh`** (the TDX node), resolve + verify the digest once on a trusted machine and pass it in:
  ```bash
  gh release view v0.1.35 --repo fastnear/near-outlayer --json body -q .body | grep -iE '\| *keystore *\|'
  gh attestation verify oci://docker.io/outlayer/near-outlayer-keystore@<digest> -R fastnear/near-outlayer
  # then on the node:  WORKER_DIGEST=sha256:<digest> ...
  ```
  The Mac orchestrator (`scripts/deploy_tdx.sh`, parent repo) does this resolve+verify for you.

### C. The secrets env file (per network)
Copy the template for the network to the node as a gitignored file and fill the `<SECRET>`/`<...>`:
```bash
cp keystore/testnet-keystore.env.template  keystore/.env.testnet-keystore-tdx   # testnet
cp keystore/mainnet-keystore.env.template  keystore/.env.mainnet-keystore-tdx   # mainnet
```
Env values are **encrypted by the per-node KMS at deploy** (`vmm-cli --env-file`) and are NOT baked
into the measured compose — plaintext secrets never enter the app-compose. NEVER commit the filled
file. Rule: **no inline `# comment` after a value** (the parser takes the whole line after `=`).

Fill, per network:
- `NEAR_RPC_URL` — `https://rpc.<net>.fastnear.com?apiKey=<RPC_API_KEY>` (the apiKey is a secret).
- `INIT_ACCOUNT_ID` / `INIT_ACCOUNT_PRIVATE_KEY` — the account that self-submits
  `submit_keystore_registration` on boot and pays its gas (full-access ed25519 key).
- `ALLOWED_WORKER_TOKEN_HASHES` / `ALLOWED_COORDINATOR_TOKEN_HASHES` — `sha256` of the bearer token
  each caller (worker / coordinator) sends; must match their `KEYSTORE_AUTH_TOKEN`.
- `MPC_CONTRACT_ID` (`v1.signer-prod.testnet` / `v1.signer`), `MPC_DOMAIN_ID=2`, and **`MPC_PUBLIC_KEY`**
  (BLS12-381 G2 CKD key). The templates ship the current keys.

> **KEY CONTINUITY — read before a first MAINNET deploy.** The master is derived in-TEE from MPC CKD
> keyed by `(MPC_CONTRACT_ID, MPC_DOMAIN_ID, MPC_PUBLIC_KEY)` and the DAO predecessor — NOT by the
> CVM measurements. A wrong/changed MPC key or contract derives a **different master**, and every
> already-stored user secret becomes unreadable. For mainnet, confirm `MPC_PUBLIC_KEY` matches the key
> the existing (Phala) keystore used before deploying. (Do NOT set `KEYSTORE_MASTER_SECRET` — it is
> incompatible with TEE mode and would override the TEE-derived master.)

---

## Configure — deploy-time names (drive the app-id)

Two deploy-time args (NOT env vars), both passed to `40-deploy-keystore.sh`:
- **`APP_NAME`** — the CVM's VM label (shown in `lsvm`, targeted by `worker-ctl.sh`). Unique per instance.
- **`COMPOSE_NAME`** — the name baked into the **measured** app-compose → drives the compose hash →
  RTMR3 → **measurements + app-id**. Keep it **STABLE per (network, version)** so you approve the
  measurements once. Defaults to `APP_NAME` if unset.

Use a network-qualified COMPOSE_NAME so testnet + mainnet get distinct app-ids/URLs:
`outlayer-keystore-testnet-<version>` / `outlayer-keystore-mainnet-<version>`.

---

## Deploy

### Path A — Mac orchestrator (recommended; does digest + governance for you)
From the parent repo on your laptop (`scripts/deploy_tdx.sh`):
```bash
scripts/deploy_tdx.sh keystore testnet <vm-name> \
  --version 0.1.35 --node root@<node-ip> \
  --gateway-url https://gateway.dstack.outlayer.ai:9202
```
It resolves+verifies the digest (gh), runs the node-side deploy, then drives governance ([3–6/6]:
read measurements → owner-approve on the DAO → create proposal + vote → wait for READY) and prints
`KEYSTORE_BASE_URL=…`. **`--gateway-url` is REQUIRED for a public endpoint** — omit it and you get a
PLAIN, loopback-only keystore (the gateway URL 404s); the orchestrator now WARNS when it's missing.

### Path B — directly on the node (manual governance, below)
```bash
cd ~/self-hosted-tdx        # the deploy dir on the node
APP_NAME=outlayer-keystore-testnet-0.1.35-1 \
COMPOSE_NAME=outlayer-keystore-testnet-0.1.35 \
ENVFILE=keystore/.env.testnet-keystore-tdx \
GATEWAY_URL=https://gateway.dstack.outlayer.ai:9202 \
WORKER_DIGEST=sha256:<keystore-digest> \
  ./40-deploy-keystore.sh v0.1.35
```
`40-deploy-keystore.sh` handles the four gateway-mode requirements automatically (see Gotchas):
`--gateway` + dropping `--no-instance-id`, the `port_policy`/`public_tcbinfo` jq-injection, `--gateway-url`,
`--disk 20G`, `ports: 8081:8081` (in the compose), and the temporary `/etc/hosts` KMS dance +
clean-DNS reboot. It prints `KEYSTORE_BASE_URL=…` at the end.

---

## Govern — approve measurements + vote (Path B / what the orchestrator automates)

On first boot the keystore gets its KMS app key + a TDX quote and self-submits its DAO registration
(logs `Proposal ID: N`), then **stalls on "measurements not approved"** (expected — the CVM stays up).
As the DAO **owner/signer**, on `dao.outlayer.<net>`:
1. Harvest the keystore's 5 measurements from its logs (`worker-ctl.sh ... logs`).
2. Approve those measurements (owner) and vote the proposal through:
   ```bash
   near contract call-function as-transaction dao.outlayer.testnet \
     vote json-args '{"proposal_id":<N>,"approve":true}' \
     prepaid-gas '100.0 Tgas' attached-deposit '0 NEAR' \
     sign-as zavodil.testnet network-config testnet sign-with-legacy-keychain send
   ```
Once the proposal passes, the keystore pulls its MPC-CKD master and logs **"Keystore is now ready to
serve requests."** On **testnet** the single trusted-signer vote is enough; on **mainnet** the DAO may
require additional signers — verify the DAO's vote threshold before counting on a one-vote pass.

---

## Verify

```bash
curl -s https://<keystore-app-id>-8081.<gateway-domain>/health
# -> {"status":"ok","tee_mode":"outlayer_tee"}   (HTTP 200, valid Let's Encrypt TLS)
```
The app-id is `sha256(app-compose.json)[:40]`; the deploy prints the full `KEYSTORE_BASE_URL`. It is
**stable** across redeploys (the gateway-mode compose is deterministic for a given COMPOSE_NAME).

Wire that URL into callers as `KEYSTORE_BASE_URL` (the worker + coordinator env).

---

## testnet + mainnet keystores on ONE node

Both run behind the **same gateway** (one `gatewayAppId` covers both — the keystore trusts the
gateway, not the reverse). They differ only by network-qualified names + env → distinct app-ids →
distinct URLs:

| | testnet | mainnet |
|---|---|---|
| `COMPOSE_NAME` | `outlayer-keystore-testnet-<v>` | `outlayer-keystore-mainnet-<v>` |
| `ENVFILE` | `.env.testnet-keystore-tdx` | `.env.mainnet-keystore-tdx` |
| DAO | `dao.outlayer.testnet` | `dao.outlayer.near` |
| MPC | `v1.signer-prod.testnet` | `v1.signer` |
| `--gateway-url` | `https://gateway.dstack.outlayer.ai:9202` | same |

Deploy them as two separate `40-deploy-keystore.sh` runs (distinct `APP_NAME`s, e.g. `…-testnet-…-1`
and `…-mainnet-…-1`). Each gets its own `https://<app-id>-8081.<gateway-domain>`. The mainnet DAO must
have the multi-collateral upgrade + this node's collateral seeded first (see `mainnet-launch.md`).

---

## Ops

```bash
# logs (CONTAINER is always dstack-keystore-1 inside the CVM)
NAME=<app-name> CONTAINER=dstack-keystore-1 ./worker-ctl.sh follow
NAME=<app-name> CONTAINER=dstack-keystore-1 ./worker-ctl.sh logs

# node-local smoke test (deploy printed the loopback host port mapped to guest :8081)
NAME=<app-name> ./worker-ctl.sh status        # uptime / state
```
Production traffic reaches `:8081` over the WireGuard mesh / dstack-gateway, NOT the loopback host
port (which is a node-local smoke-test only).

---

## Redeploy + gotchas

- **Same `APP_NAME` → replace-on-redeploy.** The script stops+removes the existing CVM with that VM
  label first, so re-running redeploys in place. The app-id/URL stay the same (deterministic compose).
- **Gateway REDEPLOY couples to the keystore.** A gateway *restart* is transparent (app-id + port 9202
  + URL stable). A gateway *redeploy* changes the gateway's app-id → the deploy auto-updates the KMS
  `gatewayAppId` → you must then **redeploy the keystore** so it re-registers under the new gateway
  app-id. The keystore's own URL does not change.
- **The four gateway-mode requirements** (all handled by the script — do not undo them):
  1. **`--disk 20G`** — the encrypted-ZFS persistent volume can't be created in 1G; a smaller disk
     reboot-loops at first boot right after `Filesystem options: encryption=true, filesystem=Zfs`.
     (`--disk` is unmeasured — does not change the app-id.)
  2. **Drop `--no-instance-id`** in gateway mode — the gateway's `register_cvm` rejects an empty
     instance id (`instance id is empty` → 400 → reboot-loop), so the CVM needs a real, disk-persisted
     instance id.
  3. **`port_policy` + `public_tcbinfo` jq-injection** — restricts gateway-exposed ports to ONLY
     `:8081` (never the guest-agent `:8090`) and publishes the TCB the gateway routes by. (Changes the
     app-id vs plain mode — correct: the prod keystore IS the gateway-enabled compose.)
  4. **`ports: 8081:8081`** in `keystore/docker-compose.yaml` — publishes `:8081` to the CVM network so
     the gateway reaches it over WireGuard; without it the gateway gets `connection refused (os error 111)`.
- **Plain mode** (no `--gateway-url`) deploys a loopback-only keystore — registers + serves on the
  node, but no public endpoint; the gateway URL 404s. Pass `--gateway-url` for the public endpoint.
- Never `systemctl restart` the vmm to apply anything — the qemu CVMs share its cgroup, so a restart
  kills every CVM on the node. The script never touches `vmm.toml` (uses per-VM `--gateway-url`).

Related: `gateway.md` (the ingress this depends on), `cvm-operations.md` (day-2 ops),
`mainnet-launch.md` (mainnet DAO + collateral).
