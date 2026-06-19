# Self-hosted TDX deployment (OutLayer worker on your own bare-metal TDX)

Deploy & initialize an OutLayer execution worker on a **self-hosted Intel TDX**
server (via dstack), instead of (or alongside) Phala Cloud. Each node is
**self-contained**: it runs its own dstack stack + a per-node KMS-as-CVM, reusing
the host's TDX/PCCS/attestation. No central KMS, no public domain required.

> The KMS itself is **upstream `dstack-kms`** (from Dstack-TEE/dstack) — we don't
> fork it; we deploy + configure it. The "code" here is deployment config + scripts.

Rolling out a new node = clone this repo → run the scripts in order → provide the
node-specific values (NEAR account, public IP, secrets). Nothing node-specific or
secret is committed (see `*.template` files + the `.env` you create locally).

---

## Architecture (per node)

```
bare-metal TDX host (Ubuntu 24.04, canonical/tdx kernel)
├─ Intel SGX/TDX attestation stack: QGS + local PCCS (Intel PCS API key)
├─ dstack-vmm  (this node's, e.g. 127.0.0.1:11000 — separate from any other vmm)
│   ├─ KMS-CVM         (dstack-kms in a CVM; per-node; encrypts worker env)
│   ├─ gateway-CVM     (internal routing; ZT-HTTPS optional/off)
│   └─ worker-CVM      (OutLayer worker; outbound-only; /var/run/dstack.sock)
└─ auth-simple (host webhook; JSON allowlist of OS image + KMS + worker measurements)
```

- The worker's **master/custody keys come from NEAR MPC via the keystore** — the
  per-node KMS only encrypts the worker's **operational env** (gas key, auth tokens).
- On-chain: the OutLayer **register-contract** verifies the worker's TDX quote
  (dcap-qvl) against its approved measurements + collateral for the node's **FMSPC**.

---

## Prerequisites (hardware + accounts)

- Intel **Xeon 5th/6th gen with TDX**, **all DIMM channels populated** (8 DIMMs per
  populated socket — SGX/TDX requirement; partial population disables SGX → no
  attestation). Dual-socket = 16 DIMMs (or pull the 2nd CPU and run 8 on one).
- A funded NEAR account for the worker's **init/gas** account + the worker
  `OPERATOR_ACCOUNT_ID` (the register-contract account).
- An **Intel PCS API subscription key** (free): https://api.portal.trustedservices.intel.com/
  → subscribe "Intel SGX Provisioning Certification Service" → Primary key.
- Register-contract **owner** key (to approve this node's measurements + collateral).

---

## Step 0 — BIOS (via iDRAC/racadm on Dell, or vendor equivalent)

Enable (see `docs/bios.md` for Dell racadm commands):
`MemoryEncryption=MultipleKeys`, `IntelTdx=Enabled`, `TdxSeamldr=Enabled`,
`IntelSgx=On`, `SgxAutoRegistrationAgent=Enabled`, `Node Interleaving=Disabled`,
`x2APIC=Enabled`, `CpuPaLimit=Disabled`. Update BIOS/microcode (TCB must be UpToDate).

## Step 1 — Host OS + TDX kernel + attestation stack

```bash
sudo ./00-host-setup.sh
```
Installs: canonical/tdx host kernel (reboot), docker + qemu-system-x86 (8.2.2),
build deps, Node.js, and the attestation stack (QGS + local PCCS). After reboot,
verify: `sudo dmesg | grep -i tdx` → `module initialized`.

## Step 2 — SGX multi-package registration + PCCS collateral

Multi-package (2-socket) platforms in "won't save keys" mode need the platform
**manifest pushed to the local PCCS** so it caches PCK certs:

```bash
sudo /usr/bin/pccs-configure       # set your Intel PCS API key (or edit config/default.json .ApiKey)
sudo systemctl restart pccs
# push the platform manifest (URL is the BASE — no /sgx/certification/v4/, or it doubles the path):
PCKIDRetrievalTool -url https://localhost:8081 -user_token <PCCS_USER_TOKEN> -use_secure_cert false
```
Verify: `sqlite3 /opt/intel/sgx-dcap-pccs/pckcache.db 'select count(*) from pck_cert;'` > 0,
and the PCCS log shows `GET /pckcert… 200`. Record your platform **FMSPC**:
`sqlite3 …/pckcache.db 'select distinct fmspc from fmspc_tcbs;'`.

## Step 3 — Build dstack + dedicated vmm for this node

```bash
./10-build-dstack.sh           # clones meta-dstack (pinned ver), build.sh host, downloads guest image
./20-start-vmm.sh              # installs vmm.toml (from vmm.toml.template), starts dstack-vmm (systemd)
```
`vmm.toml.template` uses **separate ports/CID range** so this stack never collides
with any other vmm on the box (e.g. a NEAR MPC node). Defaults: vmm `127.0.0.1:11000`,
`cid_start=40000`.

## Step 4 — KMS-as-CVM (production) + auth-simple

Per-node KMS so the worker can use **encrypted env** (dstack `--env-file` requires KMS).
`30-deploy-kms.sh` does the whole verified flow (wraps upstream
`dstack/kms/dstack-app/deploy-simple.sh`; authoritative refs:
`dstack/docs/deployment.md` §"Deploy KMS as CVM" + `auth-simple-operations.md`):

```bash
sudo ./30-deploy-kms.sh        # bun + auth-simple + KMS-CVM deploy + bootstrap (RPC) + verify
```

What it does, in order:
1. Installs `bun` and runs **auth-simple** as a systemd service bound to `127.0.0.1:3001`
   (CVMs still reach it via `10.0.2.2:3001` — qemu user-net forwards to host loopback,
   same path the local-key-provider uses on `:3443`).
2. Writes `kms/auth-config.json` with `osImages = [<guest-image digest.txt>]`. **`kms.mrAggregated`
   is left empty on purpose** — a single primary KMS never calls `/bootAuth/kms` (that path is
   only for KMS *HA onboarding* via `GetKmsKey`); it unseals its root key locally
   (local-key-provider) on restart. Populate `kms.mrAggregated` only when adding KMS replicas.
3. Writes `dstack-app/.env.simple` (`KMS_RPC_ADDR=127.0.0.1:11001`, `AUTH_WEBHOOK_URL=http://10.0.2.2:3001`,
   `OS_IMAGE`, a persisted `ADMIN_TOKEN` in `kms/kms-admin-token.txt`) and runs `deploy-simple.sh`.
4. **Bootstraps over RPC** (no browser): `POST http://127.0.0.1:11001/prpc/Onboard.Bootstrap?json
   {"domain":"kms.1022.dstack.org"}` then `Onboard.Finish`. The `?json` suffix + `Onboard.` prefix
   are required. After Finish the KMS switches to **mTLS https** on `:11001` and serves the KMS RPC.

The KMS is reachable from CVMs at `https://kms.1022.dstack.org:11001` (`*.1022.dstack.org` → 10.0.2.2
= host; the bootstrap domain must match this, as it's the TLS cert CN). No public DNS needed.
The vmm.toml `kms_urls` already points here.

## Step 5 — Worker as a CVM (KMS mode, encrypted env)

```bash
cp worker/worker.env.template worker/worker.env   # fill secrets (NOT committed)
./40-deploy-worker.sh <version>                    # e.g. v0.1.35 — pins the verifiable image digest
```
`40-deploy-worker.sh`:
- resolves the **verifiable worker image digest** for `<version>` from the GitHub
  release (`outlayer/near-outlayer-worker@sha256:…`, Sigstore-attested), pins it in
  `worker/docker-compose.yaml`;
- `vmm-cli compose --kms --env-file worker.env` (env encrypted by our KMS, NOT baked
  into the measured compose) → `vmm-cli deploy` (no inbound ports — outbound-only).
- The worker boots, reads `/var/run/dstack.sock`, generates its TDX quote, and tries
  to register on the OutLayer register-contract.

## Step 6 — Approve the node on-chain + register

First boot fails registration ("measurements not approved" / collateral mismatch).
Harvest the worker's 5 measurements from its logs, then (register-contract **owner**):
```bash
# add this node's collateral (per-FMSPC) and measurements:
near contract call-function as-transaction <register-contract> update_collateral  json-args '{"fmspc":"<FMSPC>","collateral":"<json>"}' …  sign-as <owner>
near contract call-function as-transaction <register-contract> add_approved_measurements json-args '{...5 measurements...}' … sign-as <owner>
```
> Requires the **Phase-1 per-FMSPC collateral** contract upgrade (`quote_collateral:
> Option<String>` → `LookupMap<fmspc, String>`) so this node's FMSPC coexists with
> others. See `../../register-contract/` + the plan in
> `~/.claude/plans/self-hosted-tdx-migration.md`.

The worker retries → registers → polls the coordinator → executes tasks.

---

## File layout

| File | Purpose |
|---|---|
| `00-host-setup.sh` | Host: TDX kernel + deps + attestation stack (idempotent) |
| `10-build-dstack.sh` | Build dstack + download guest image (pinned version) |
| `20-start-vmm.sh` | Install vmm.toml + start dstack-vmm (systemd) |
| `30-deploy-kms.sh` | auth-simple + KMS-CVM deploy + bootstrap |
| `40-deploy-worker.sh` | Resolve verifiable digest + deploy worker CVM (KMS mode) |
| `vmm.toml.template` | Dedicated vmm config (separate ports/CID) |
| `kms/auth-config.json.template` | auth-simple allowlist (osImages, kms.mrAggregated, apps) |
| `kms/kms.toml.template` | KMS app config |
| `gateway/gateway.toml.template` | Gateway config (internal; ZT-HTTPS optional) |
| `worker/docker-compose.yaml` | Worker CVM compose (image pinned by digest; mounts dstack.sock) |
| `worker/worker.env.template` | Worker env (non-secret defaults + secret placeholders) |
| `docs/bios.md` | Dell racadm BIOS commands |

## Multi-node rollout

Per-node, self-contained. For each new node: Steps 0–6 with that node's values
(account, IP, FMSPC, secrets). Because each node runs its own KMS + worker and is
approved on-chain by FMSPC + measurements, nodes are independent — add/remove freely.
Workers across nodes register to the same OutLayer register-contract and all poll the
same coordinator (mixed fleet with Phala workers is supported once Phase-1 collateral
is live).

## Status / reference

This node's live bring-up + exact values (FMSPC `B0C06F000000`, ports, the NEAR MPC
node sharing the host, etc.) are tracked in `~/.claude/plans/self-hosted-tdx-migration.md`
and `~/.claude/plans/near-mpc-testnet-node.md`.
