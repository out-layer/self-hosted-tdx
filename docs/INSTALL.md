# Install — OutLayer self-hosted TDX node, from bare metal to running fleet

The single ordered entry-point for standing up the whole stack on a fresh server: a TDX host, the
dstack control plane (vmm + KMS), the TEE HTTPS ingress (gateway), the keystore(s) (testnet +
mainnet), execution workers, on-chain registration, and the host firewall. Each step links the
detailed runbook — this page is the **order + the glue**, not a re-explanation.

Goal: an operator can deploy the entire stack alone on a new server. One node runs **testnet AND
mainnet** side by side (single gateway, single KMS, one keystore per network).

> This is a clean install + setup guide, NOT a data migration. Key continuity (deriving the SAME
> keystore master as a previous deployment) is a per-keystore concern — see `keystore.md` Prereq C.

## Per-node values to set (everything else is fixed for the OutLayer project)

Fill these for the new server before you start; they thread through the steps below.

| Value | Where | Note |
|---|---|---|
| Public IP | `gateway/gateway.env`, DNS | the new node's WAN IP |
| Gateway domain base | `gateway/gateway.env` `SRV_DOMAIN` | e.g. `dstack.<you>.ai`; needs the wildcard DNS below |
| DNS `*.<SRV_DOMAIN>` A → IP | Cloudflare | **gray-cloud / DNS-only** (proxy breaks TDX attest). `gateway.md` Prereq C |
| Cloudflare DNS-01 token | `/home/outlayer/gateway-cf-token` (chmod 600) | scoped Zone:DNS:Edit + Zone:Read. `gateway.md` Prereq E |
| FastNEAR RPC API key | keystore env `NEAR_RPC_URL` | `rpc.<net>.fastnear.com?apiKey=…` |
| NEAR accounts + keys | keystore env, orchestrator | `worker.outlayer.<net>`, `dao.outlayer.<net>`, `init-keystore.outlayer.<net>`, the DAO signer key. Same accounts as the OutLayer project; only the per-node node-IP/domain change |
| KMS admin token / auth-simple | README Step 4 | per-node KMS secrets |

NEAR RPC is always `rpc.mainnet.fastnear.com` / `rpc.testnet.fastnear.com` (never `*.near.org`).

## Order

### 1. Host: BIOS → TDX kernel → attestation (README Steps 0–2)
`00-host-setup.sh` + `docs/bios.md`. Ends with `dmesg` showing `virt/tdx: module initialized` and the
SGX/PCCS collateral registered (record the node's **FMSPC**). Hardware/BIOS/kernel must be done first.

### 2. dstack + the node's vmm (README Step 3)
`10-build-dstack.sh` then `20-start-vmm.sh` → the outlayer-owned `dstack-vmm` on `127.0.0.1:11000`.

### 3. KMS-as-CVM + auth-simple patch (README Steps 4 **and 4b**)
`30-deploy-kms.sh` deploys the per-node KMS. **Then `kms/apply-auth-simple.sh`** (Step 4b) — adds
`allowAnyApp:true` + the `gatewayAppId` schema field. This is MANDATORY and the #1 cause of a failed
gateway/keystore later if skipped (`gateway.md` Prereq B explains both reasons).

### 4. Gateway — TEE HTTPS ingress → **`docs/gateway.md`**
Build/pull the image, set `gateway/gateway.env` (per-node values above), then
`40-deploy-gateway.sh deploy` → `40-deploy-gateway.sh bootstrap` (in-CVM ACME wildcard cert). The
deploy auto-sets the KMS `gatewayAppId`. Verify the wildcard cert issued. Needed before any keystore.

### 5. Keystore(s) — testnet + mainnet → **`docs/keystore.md`**
Per network: fill `keystore/<net>-keystore.env.template` → `.env.<net>-keystore-tdx` (secrets;
**check `MPC_PUBLIC_KEY` for key continuity** — `keystore.md` Prereq C), then deploy gateway-mode via
the Mac orchestrator:
```bash
scripts/deploy_tdx.sh keystore <net> <vm-name> --version <v> \
  --node root@<ip> --gateway-url https://gateway.<SRV_DOMAIN>:9202
```
The orchestrator drives governance (approve measurements + DAO vote) and prints `KEYSTORE_BASE_URL=…`.
Run it once per network (distinct `COMPOSE_NAME` → distinct app-id/URL, same gateway). On **mainnet**
the DAO must already have the multi-collateral upgrade + this node's collateral — see `mainnet-launch.md`.

### 6. Worker(s) — outbound-only execution CVMs (README Step 5)
`40-deploy-worker.sh <version>` per worker. Workers poll the coordinator outbound; they need no
gateway/inbound. Wire each worker's `KEYSTORE_BASE_URL` to the keystore URL from step 5.

### 7. On-chain: approve measurements + register (README Step 6)
First boot stalls on "measurements not approved" (expected). As the register-contract / DAO **owner**,
add this node's collateral at its FMSPC slot + approve the 5 measurements, and vote the keystore
proposal through. The orchestrator automates the keystore side; `mainnet-launch.md` covers mainnet.

### 8. Host firewall — lock down last (`45-firewall.sh`)
After the stack is verified working, enable the firewall:
```bash
sudo ./45-firewall.sh            # dry-run: prints the plan
sudo ./45-firewall.sh --apply    # enable ufw (SSH allowed first)
```
Default-deny incoming + allow only the WAN-needed ports (SSH 22, NEAR P2P 24567, gateway 443 + 9202,
ACME 80, the NEAR node ports). It keeps **all NEAR MPC node ports** and never blocks CVM→KMS (slirp
traffic arrives on `lo`, which ufw always allows). Run the post-enable verification in the script
header; rollback is `sudo ufw disable`.

### 9. Attestation portal + admin (later)
The public attestation page (`workers.<domain>`) + authenticated `/admin` are a separate Rust service
(`out-layer/attestation-portal`) — not required to run the fleet. Deploy once it ships.

## Day-2 ops
`docs/cvm-operations.md` (CVM lifecycle, logs via `worker-ctl.sh`, gotchas: stop/start reassigns the
agent port; never `systemctl restart` the vmm — shared cgroup kills every CVM).

## Verify the whole stack
```bash
curl -s https://<keystore-app-id>-8081.<SRV_DOMAIN>/health   # {"status":"ok","tee_mode":"outlayer_tee"}
worker-ctl.sh status                                          # all CVMs running
```
