# Setup a new node — adding a worker-only TDX node to an existing fleet

Standing up an **additional execution node** next to one that already runs the fleet. Unlike
[`INSTALL.md`](INSTALL.md) (the full stack: gateway + keystore + workers on one box), this is the
short path: **workers are outbound-only**, so a pure worker node needs no gateway, no keystore, and
no public ingress — only its own dstack control plane (vmm + KMS) and the worker CVM.

Worked example below: `root@23.109.254.164` (`node-tdx-ams-1`) joining a fleet whose first node is
`root@173.237.9.76`. Substitute your own.

## Prerequisites (must already be true on the new box)

`INSTALL.md` step 1 — the hardware/host layer:

- TDX enabled in BIOS + the canonical/tdx host kernel: `journalctl -k -b | grep virt/tdx` shows
  `TDX module: attributes ... major_version 1`
- PCCS active with the platform registered; record the **FMSPC**:
  `sqlite3 /opt/intel/sgx-dcap-pccs/pckcache.db 'select distinct fmspc from fmspc_tcbs;'`
- gramine sealing key-provider on `127.0.0.1:3443` (the KMS seals its root key through it)
- base packages from `00-host-setup.sh` (qemu 8.2.2+tdx, docker, node/npm, python3 + the vmm-cli
  pip deps incl. `eth-hash[pycryptodome]`)

If the FMSPC **matches a node already registered on-chain**, the register-contract already holds
usable collateral for this platform and you do not need to add any. If it differs, add this node's
collateral at its FMSPC slot first (see [`mainnet-launch.md`](mainnet-launch.md)).

## Why this node gets its **own** KMS

It is not optional and the existing node's KMS cannot be reused as-is:

- CVMs reach the KMS at `https://kms.1022.dstack.org:11001`, and that domain publicly resolves to
  **`10.0.2.2`** — the qemu-slirp gateway, i.e. *the CVM's own host*. A CVM on the new node using
  that URL reaches the new node, never the old one. Pointing it elsewhere means a different domain
  and therefore re-bootstrapping the KMS's RA-TLS cert, which is bound to that name.
- The KMS root key is sealed by the **local** key-provider on `127.0.0.1:3443`, i.e. bound to that
  node's hardware. Sharing one KMS across nodes would make node B's CVM keys derivable on node A and
  would require exposing port 11001 to the WAN — inbound attack surface on the box that holds the
  custody root, plus a hard runtime dependency (link to node A down → CVMs on node B cannot boot).
- A worker gains nothing from a shared root: it generates its NEAR key **inside the enclave** and
  registers itself on-chain, so there is no key continuity to preserve. Continuity matters only for
  the keystore (`MPC_PUBLIC_KEY`, see [`keystore.md`](keystore.md) Prereq C) — and a worker-only
  node runs no keystore.

If a shared key root is ever genuinely needed, the supported path is **KMS HA onboarding** (a second
KMS CVM replicates the root from the primary via `/bootAuth/kms` + `GetKmsKey`, with its
`mrAggregated` allowlisted on the primary), not remote CVM → KMS traffic. See the comments in
[`../30-deploy-kms.sh`](../30-deploy-kms.sh).

## Port / path layout

The OutLayer stack is deliberately isolated from anything else on the box (e.g. a NEAR MPC node's
own dstack on `:10000` / CID 30000):

| Thing | Value |
|---|---|
| vmm RPC | `127.0.0.1:11000` (`outlayer-dstack-vmm.service`) |
| CVM CID range | 40000 + 1000 |
| KMS RPC | `127.0.0.1:11001` → CVM:8000 |
| KMS guest-agent | `127.0.0.1:11005` |
| auth-simple webhook | `127.0.0.1:3001` (`outlayer-kms-auth.service`) |
| dstack tree | `/home/outlayer/meta-dstack` (build + `dstack/` source) |
| runbook repo | `/home/outlayer/self-hosted-tdx` |
| KMS state | `/home/outlayer/outlayer-kms` (auth-config.json, admin token) |

## 1. User + repo + toolchain

```bash
ssh root@23.109.254.164

useradd -m -s /bin/bash outlayer
usermod -aG sudo,kvm,docker outlayer
printf 'outlayer ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/90-outlayer
chmod 440 /etc/sudoers.d/90-outlayer && visudo -c -f /etc/sudoers.d/90-outlayer
# dstack-vmm v0.5.x wants /run/user/<uid> even as a systemd *system* service (see 20-start-vmm.sh)
loginctl enable-linger outlayer
```

Copy this repo to the node (from the Mac; keep the secrets out of git and off the wire you don't
need). `worker/.env.<net>-worker-tdx` is the only secret file a worker node needs:

```bash
# on the Mac, from deploy/self-hosted-tdx/
rsync -a --exclude '.git' --exclude '.idea' --exclude 'keystore/.env.*' \
      --exclude 'worker/.env.mainnet-worker-tdx' \
      ./ root@23.109.254.164:/root/stage/self-hosted-tdx/
```

```bash
# back on the node
rsync -a /root/stage/self-hosted-tdx/ /home/outlayer/self-hosted-tdx/
chown -R outlayer:outlayer /home/outlayer/self-hosted-tdx
chmod 600 /home/outlayer/self-hosted-tdx/worker/.env.testnet-worker-tdx

# Rust (build.sh host needs cargo)
sudo -u outlayer -H bash -lc 'curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path'
printf '\n. "$HOME/.cargo/env" 2>/dev/null || true\n' >> /home/outlayer/.profile

# 40-deploy-*.sh and worker-ctl.sh default VMM_CLI to /opt/mpc/dstack/vmm/src/vmm-cli.py (a path
# that exists only on nodes that also host a NEAR MPC dstack). Point them at this node's own tree.
# `su - outlayer -c ...` — which the Mac orchestrator uses — reads .profile, so set it there.
echo 'export VMM_CLI=/home/outlayer/meta-dstack/dstack/vmm/src/vmm-cli.py' >> /home/outlayer/.profile
chown outlayer:outlayer /home/outlayer/.profile
```

The worker env is node-independent (no IPs/hostnames in it) — the same file works on every node of
the fleet, including `KEYSTORE_BASE_URL` pointing at the keystore that runs on another node.

## 2. Build dstack + fetch the guest image (~20–60 min)

```bash
su - outlayer -c 'cd ~/self-hosted-tdx && DSTACK_ROOT=/home/outlayer ./10-build-dstack.sh 0.5.11'
```

`DSTACK_ROOT=/home/outlayer` is **required**: the script's own default is `~/dstack-node`, but
`20-start-vmm.sh` and `30-deploy-kms.sh` expect `/home/outlayer/meta-dstack`. The version must match
the `IMAGE_OS` / `OS_IMAGE` the deploy scripts use (`dstack-0.5.11`) — it feeds MRTD/RTMR0-2.

## 3. Start this node's vmm

```bash
cd /home/outlayer/self-hosted-tdx
NODE_USER=outlayer DSTACK_ROOT=/home/outlayer ./20-start-vmm.sh
systemctl is-active outlayer-dstack-vmm && ss -ltnp | grep 11000
```

## 4. KMS-as-CVM + auth-simple

```bash
cd /home/outlayer/self-hosted-tdx
./30-deploy-kms.sh
KMS_DEVICES=0x<sha256(ppid)> ./kms/apply-auth-simple.sh
                               # MANDATORY: allowAnyApp (else every worker CVM must be hand-added to
                               # outlayer-kms/auth-config.json) + this node's device allowlist (kms/README.md).
                               # Then restart a non-critical CVM and confirm isAllowed: true in
                               # journalctl -u outlayer-kms-auth.service before touching the KMS CVM.
systemctl is-active outlayer-kms-auth
curl -sk -X POST https://127.0.0.1:11001/prpc/GetMeta?json -d '{}' | head -c 200
```

Boot-authorization decisions (allow/deny per CVM boot) are logged on the host:
`journalctl -u outlayer-kms-auth.service -f`.

## 5. Deploy the worker — from the Mac

Everything on-chain (measurement approval) is signed **locally**, so the owner key never touches the
node:

```bash
cd ~/projects/near-offshore
./scripts/deploy_tdx.sh worker testnet testnet-worker-040-1 --version 0.1.40 \
  --node root@23.109.254.164
```

The orchestrator deploys the CVM, reads the 5 TEE measurements from its logs, approves them on
`worker.outlayer.testnet` (idempotent per network+version), restarts, and waits for
`Worker key registered successfully`. Measurements on a new box legitimately differ (MRTD from the
image, RTMR0 from that machine's firmware) — the approval step handles it; no manual work.

## 6. `outlayer` — one command from anywhere

`worker-ctl.sh` only works from the repo dir and needs the right `VMM_CLI`. Install this thin
wrapper on **every** node (identical command; it auto-detects the vmm-cli path):

```bash
sudo tee /usr/local/bin/outlayer >/dev/null <<'EOF'
#!/usr/bin/env bash
# OutLayer node CLI — thin wrapper over self-hosted-tdx/worker-ctl.sh, usable from any cwd.
#   outlayer                 # status (lsvm)
#   outlayer follow          # stream worker app logs
#   outlayer logs <cvm>      # snapshot logs of a specific CVM (kms/gateway/keystore auto-detected)
#   outlayer restart|stop|start|port|uuid|serial|info|remove [cvm]
set -euo pipefail
REPO="${OUTLAYER_REPO:-/home/outlayer/self-hosted-tdx}"
[ -x "$REPO/worker-ctl.sh" ] || { echo "outlayer: no worker-ctl.sh at $REPO (set OUTLAYER_REPO)" >&2; exit 1; }
if [ -z "${VMM_CLI:-}" ]; then
  for c in /home/outlayer/meta-dstack/dstack/vmm/src/vmm-cli.py \
           /opt/mpc/dstack/vmm/src/vmm-cli.py; do
    [ -f "$c" ] && { VMM_CLI="$c"; break; }
  done
fi
export VMM_CLI="${VMM_CLI:-}" VMM_URL="${VMM_URL:-http://127.0.0.1:11000}"
exec "$REPO/worker-ctl.sh" "$@"
EOF
sudo chmod +x /usr/local/bin/outlayer
```

Then, from anywhere on the node:

```bash
outlayer                                   # list all CVMs
outlayer follow                            # tail the worker's app log
outlayer logs kms                          # KMS CVM logs (container auto-picked)
outlayer restart testnet-worker-040-1       # by CVM name
TAIL=1000 outlayer logs testnet-worker-040-1
```

Env passthrough still works: `NAME=`, `CONTAINER=`, `TAIL=`, `VMM_URL=`.

## 7. Collateral tooling — `dcap-qvl` on the node

Only needed when you have to (re)generate the Intel collateral for this platform: Intel refreshes
TCB info / CRLs roughly monthly, and registration then fails with a TCB or collateral error. The
collateral is **per-FMSPC, not per-machine and not per-network**, so one node of a given platform can
produce it for the whole fleet and both networks — but every node should be able to, so losing one
box does not block the fleet.

Build the patched CLI (~30 s; Rust is already installed from step 1):

```bash
su - outlayer
git clone --branch v0.3.12 https://github.com/Phala-Network/dcap-qvl.git ~/dcap-qvl   # commit a854bd2
cd ~/dcap-qvl
git apply ~/self-hosted-tdx/tools/dcap-qvl-0.3.12-collateral-dump.patch
cd cli && cargo build --release
```

The patch is two hunks: dump `QuoteCollateralV3` to `/tmp/our_collateral.json` after fetching, and
`danger_accept_invalid_certs(true)` so the CLI talks to the node's **local** PCCS, which serves a
self-signed cert on `https://localhost:8081`.

Any TDX quote from this host works as input — the collateral is per-platform, not per-quote. The
guest agent exposes no quote RPC on its host port, so take one out of a running CVM's `app_cert`
(X.509 extension OID `1.3.6.1.4.1.62397.1.8`):

```bash
python3 ~/self-hosted-tdx/tools/extract-platform-quote.py > ~/platform-quote.hex   # default: KMS CVM agent :11005
cd /tmp && PCCS_URL=https://localhost:8081 ~/dcap-qvl/cli/target/release/dcap-qvl verify --hex ~/platform-quote.hex
#   -> "Quote verified", status UpToDate, and /tmp/our_collateral.json written
```

Then pull it to your laptop **in canonical form** and cache it in the register-contract. Do not plain
`scp` it: the CLI's dump carries `pck_certificate_chain`, the PCK certificate of the CPU that
produced the quote, so the raw file differs depending on which node you generated it on. Dropping it
(and sorting keys) makes the committed file byte-identical whatever node it came from — the
remaining nine fields are pure per-FMSPC Intel material:

```bash
cd ~/projects/near-offshore
ssh root@<node> 'jq -S "del(.pck_certificate_chain)" /tmp/our_collateral.json' > scripts/our_collateral.json
git diff scripts/our_collateral.json      # expect only Intel's issueDate/nextUpdate + signatures
./scripts/update_collateral.sh scripts/our_collateral.json 1 testnet    # slot 1 = self-hosted FMSPC
./scripts/update_collateral.sh scripts/our_collateral.json 1 mainnet    # same file, other network
```

`update_collateral.sh` also strips the field itself, so a collateral obtained any other way (Phala's
API, an unpatched CLI) still uploads correctly — leaving it in pins the slot to one machine and
every other node fails registration (see the troubleshooting entry below).

## Troubleshooting: the worker deploy dies right after "Deploy worker CVM"

`scripts/deploy_tdx.sh` exits with no error after `[3/3] Deploy worker CVM (outbound-only)...`
because `40-deploy-worker.sh` captures the vmm-cli output in `DEPLOY_OUT="$( ... 2>&1)"` — under
`set -e` a failing deploy kills the script *before* that variable is echoed. The real message is
recoverable by running the same command by hand (keep the temporary `/etc/hosts` entry, it is what
lets the **host-side** env encryption reach the KMS):

```bash
su - outlayer
cd ~/self-hosted-tdx
echo "127.0.0.1 kms.1022.dstack.org # tmp" | sudo tee -a /etc/hosts
python3 "$VMM_CLI" --url http://127.0.0.1:11000 deploy --name <vm> \
  --compose worker/app-compose.json --image dstack-0.5.11 \
  --env-file worker/.env.testnet-worker-tdx --kms-url https://kms.1022.dstack.org:11001 \
  --vcpu 2 --memory 1G --disk 1G --port tcp:127.0.0.1:9210:8090
# (vCPU/memory feed RTMR0, so a value different from 40-deploy-worker.sh's produces a different
#  measurement set that has to be approved before the worker can register.)
sudo sed -i '/kms.1022.dstack.org # tmp/d' /etc/hosts     # ALWAYS remove it again
```

`ConnectionResetError: [Errno 104] Connection reset by peer` inside
`get_app_env_encrypt_pub_key` means **the KMS is not serving** — the deploy never even reaches the
vmm (`journalctl -u outlayer-dstack-vmm` shows only `Status` calls). Check the KMS CVM itself:

```bash
outlayer logs kms          # "No such container: dstack-kms-1" -> the app never started
outlayer serial kms        # look for: app-compose.sh ... validating /dstack/docker-compose.yaml
```

`services.kms.image must be a string` = `KMS_IMAGE` was empty when `deploy-simple.sh` rendered the
compose. `30-deploy-kms.sh` now pins it (`KMS_IMAGE=dstacktee/dstack-kms@sha256:…`, must match
`KMS_VER`); upstream's own default only applies to the `.env.simple` *template* it writes when that
file is missing, and `KMS_IMAGE` is not in its `required_env_vars`, so it fails silently. Fix:
delete the dead KMS CVM and redeploy —

```bash
NAME=kms /home/outlayer/self-hosted-tdx/worker-ctl.sh remove   # only ever a KMS that never came up:
                                                               # deleting a HEALTHY one destroys the
                                                               # sealed root key and all app keys
cd /home/outlayer/self-hosted-tdx && ./30-deploy-kms.sh
```

### KMS container runs, but https on :11001 stays dead

`outlayer logs kms` shows `rpc error: KMS is not allowed to bootstrap / Caused by: boot denied:
aggregated MR not allowed`, and `journalctl -u outlayer-kms-auth` shows the denied request. The KMS
asks the auth-simple webhook for permission **to bootstrap itself**, and its own `mr_aggregated` —
a hash over that CVM's MRTD+RTMR0-3, so unique per node *and* per KMS redeploy — was not in
`kms.mrAggregated`. Without a successful bootstrap the KMS never switches from onboarding-http to
mTLS-https, so `GetMeta` returns nothing and worker deploys keep failing on the TLS handshake.

`30-deploy-kms.sh` step 6 now handles this: it reads the value from the CVM's guest agent, appends
it to `auth-config.json`, restarts the webhook, then bootstraps. Re-running the script is the fix —
it detects the existing `kms` CVM, skips the deploy, and resumes from there. The value by hand:

```bash
curl -s http://127.0.0.1:11005/prpc/Info?json \
  | python3 -c 'import sys,json; print(json.loads(json.load(sys.stdin)["tcb_info"])["mr_aggregated"])'
```

### The worker CVM boots, then exits and reboots in a loop

`outlayer status` flips the worker between `running` and `exited`, and `outlayer logs <vm>` says
`no agent port`. The app never starts — read the **serial** log instead:

```bash
NAME=<vm> TAIL=900 ~/self-hosted-tdx/worker-ctl.sh serial > /tmp/w.log
sed -n '/Requesting app keys/,/Failed to request app keys/p' /tmp/w.log
```

`App not allowed: Failed to verify os image hash: … Failed to download image <hash>: Checksum
verification failed: sha256sum: sha256sum.txt: No such file or directory` means the KMS fetched the
OS-image tarball from `IMAGE_DOWNLOAD_URL`, extracted it, and could not find `sha256sum.txt` at the
extraction root. The **GitHub release tarball nests everything under `dstack-<ver>/`** and therefore
cannot be served as-is. Pack it flat from the image the vmm actually boots (what step 4 now does):

```bash
sudo -u outlayer tar -czf /home/outlayer/outlayer-kms/imgsrv/dstack-0.5.11.tar.gz \
  -C /home/outlayer/meta-dstack/build/images/dstack-0.5.11 .
tar -tzf /home/outlayer/outlayer-kms/imgsrv/dstack-0.5.11.tar.gz | head -3   # expect ./ and ./sha256sum.txt
```

### Registration fails: "Signature is invalid for qe_report in quote"

Measurements are approved, the worker builds a valid TDX quote, and `register_worker_key` panics
with `TDX quote verification failed (signature/TCB/collateral mismatch): Signature is invalid for
qe_report in quote`.

This is a **fleet-level** problem, not a node problem: the collateral slot for this FMSPC contains a
`pck_certificate_chain`, and dcap-qvl 0.3.11 *prefers* it over the chain embedded in the quote it is
verifying (`verify.rs / verify_pck_cert_chain`). PCK certificates are per-CPU, so a slot carrying
one is pinned to the machine whose quote generated it — the first node verifies, every later node
fails. (Phala's slot has no such field, which is why one Phala collateral covers all their workers.)

Fix once per network, as the register-contract owner — `scripts/update_collateral.sh` now strips the
field automatically:

```bash
cd ~/projects/near-offshore
./scripts/update_collateral.sh scripts/our_collateral.json 1 testnet   # slot 1 = self-hosted FMSPC
```

Check a slot before blaming a node:

```bash
near contract call-function as-read-only worker.outlayer.<net> get_collaterals \
  json-args '{}' network-config <net> now
# every slot must be 9 keys; "pck_certificate_chain" present == pinned to one machine
```

The same applies to `worker.outlayer.near` and to `dao.outlayer.near` (keystore governance) before a
second node registers there.

## Verify

```bash
outlayer                                        # the worker CVM is running
outlayer follow | grep -m1 "registered successfully"
near contract call-function as-read-only worker.outlayer.testnet get_workers \
  json-args '{}' network-config testnet now     # the new worker is listed
```

## Firewall

A worker node needs **no new inbound ports** — workers poll the coordinator outbound. Keep
`45-firewall.sh`'s default-deny and only whatever that box already needed (SSH, and the NEAR node
ports if it also runs one).

## 8. Attestation agent (optional — puts the node on workers.outlayer.ai)

The public attestation page shows a node only if an `attestation-agent` on it PUSHES to the portal;
there is no discovery. The agent reads this node's dstack-vmm over loopback and posts a fleet
snapshot every 5 min. Its source lives in the separate `out-layer/attestation-portal` repo (it
shares a crate with the portal server); `install-agent.sh` here builds it **on the node** — never
hand-copy a Mac build over (arm64 → `Exec format error` on the Linux node):

```bash
# from deploy/self-hosted-tdx/, building on the node from a portal checkout:
PUSH_TOKEN=<ingest-token> ./install-agent.sh --node root@<ip> --node-id node-tdx-<name> \
    --portal-repo ~/projects/attestation-portal --portal root@<portal-server>

# or, adding to an existing fleet, clone a healthy node's binary + token (no build):
./install-agent.sh --node root@<ip> --node-id node-tdx-<name> \
    --from-node root@<existing-node> --token-from root@<existing-node> --portal root@<portal-server>
```

`--portal` opens this node's egress IP on the portal's `/ingest` allow-list (pinned per node); omit
it and the script prints the one-liner to run there. The agent needs the `outlayer` user and the
OutLayer vmm on `127.0.0.1:11000` — both already true after the steps above.

## Not needed on a worker-only node

- `40-deploy-gateway.sh` — no public ingress
- `40-deploy-keystore.sh` / DAO governance — the fleet's keystore lives on another node and is
  reached over its public HTTPS endpoint (`KEYSTORE_BASE_URL` in the worker env)
- mainnet secrets, unless you also deploy a mainnet worker here (then copy
  `worker/.env.mainnet-worker-tdx` too and re-run step 5 with `mainnet`)

Day-2 operations (CVM lifecycle, log gotchas, "never `systemctl restart` the vmm"):
[`cvm-operations.md`](cvm-operations.md).
