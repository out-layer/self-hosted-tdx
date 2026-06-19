# Gateway ingress (self-hosted TDX) — TEE-terminated HTTPS for the keystore

The keystore is an HTTP server (`:8081`) that workers + the coordinator call. It must be reachable
over **HTTPS where TLS terminates INSIDE an attested TEE** — decrypted secrets must never exist in
host memory (so host nginx TLS termination is forbidden). The dstack-native way (what Phala did) is a
**dstack-gateway CVM**: it terminates TLS in its own attested CVM and forwards to the keystore CVM
over a WireGuard mesh. Public endpoint:

```
https://<keystore-app-id>-8081.dstack.outlayer.ai
```

This dstack version (0.5.11) has **no clean-custom-hostname** with gateway TLS termination — only
`<app-id>-<port>.<gateway-domain>` (a CNAME breaks SNI-based termination). `KEYSTORE_BASE_URL`
(worker + coordinator) points at the app-id URL; it hides the ugly host.

**This document is a complete standalone runbook.** Following it on a FRESH server (after the base
node is up — see Prerequisites) gets you from nothing to a working gateway with a wildcard cert, with
no knowledge of the session that first set it up. Order: Prerequisites → Configure → Deploy →
Bootstrap ACME → Verify → Ops → Redeploy/version-bump → Gotchas.

## Architecture

```
client (worker / coordinator)
  └─HTTPS─> :443 on the node IP  ──> dstack-gateway CVM (attested; terminates TLS, owns *.dstack.outlayer.ai wildcard cert)
                                        └─WireGuard mesh, by app-id──> keystore CVM :8081 (plain HTTP, in-TEE)
```

- **Gateway-only-for-keystore.** `gateway_enabled` is a per-app, deploy-time flag. Deploy the gateway
  and the keystore with it; leave the **workers untouched** → they stay outbound-only (setting
  `vmm.toml gateway_urls` does not pull already-deployed CVMs into the mesh). Worker logs/ports are
  never WAN-exposed.
- TLS terminates in the gateway CVM (itself measured/attested via the same auth-simple allowlist), so
  plaintext lives only inside TEEs.

---

## Prerequisites

### A. The base node must already be up

The gateway is an **addition** on top of a working node. Do the README steps first; the gateway
assumes ALL of these are done:

| README step | What it gives the gateway |
|---|---|
| Steps 0–2 | TDX host + attestation stack (QGS/PCCS), FMSPC recorded |
| Step 3 (`20-start-vmm.sh`) | the outlayer-owned `dstack-vmm` on `127.0.0.1:11000` |
| Step 4 (`30-deploy-kms.sh`) | the per-node KMS-as-CVM + auth-simple webhook |
| **Step 4b (`kms/apply-auth-simple.sh`)** | **`allowAnyApp:true` + the `gatewayAppId` config field — MANDATORY (see B)** |

See `../README.md`. **Do NOT skip Step 4b** — it is the single most common reason a fresh-server
gateway fails. Details below.

### B. auth-simple must have the OutLayer customization (`allowAnyApp` + `gatewayAppId`)

`30-deploy-kms.sh` deploys **stock** auth-simple. The gateway runbook depends on the OutLayer
`index.ts` customization applied by `kms/apply-auth-simple.sh` (README Step 4b) for **two** reasons —
both will silently break the gateway if it's missing:

1. **`allowAnyApp:true`** — the gateway CVM gets a fresh app-id on every (re)deploy (launch-token
   randomization). With stock auth-simple, that app-id is not in `apps`, so the KMS **denies the
   gateway at boot** and it never gets its app key. `allowAnyApp` lets any app passing TCB + `osImages`
   boot without a per-app allowlist entry. (This is also why `40-deploy-gateway.sh` skips the L1 KMS
   allowlist step.)
2. **The `gatewayAppId` config field** — `40-deploy-gateway.sh deploy` writes
   `gatewayAppId=<this gateway's app-id>` into `auth-config.json` and reloads the webhook, so
   gateway-enabled CVMs (the keystore) learn which gateway to trust. **Stock auth-simple's schema has
   no `gatewayAppId` field and never returns it to a booting CVM** — so even if you set it in the JSON,
   it is a no-op, and the keystore reboot-loops with `Missing allowed dstack-gateway app id`. The
   `apply-auth-simple.sh` patch adds `gatewayAppId: z.string().default('')` to the schema AND makes
   `checkAppBoot` return it. Without the patch, step (6) in the deploy below does nothing useful.

Verify the patch + config are in place (run on the node):

```bash
grep -c gatewayAppId /home/outlayer/meta-dstack/dstack/kms/auth-simple/index.ts   # > 0 means patched
python3 -c 'import json; d=json.load(open("/home/outlayer/outlayer-kms/auth-config.json")); print("allowAnyApp:", d.get("allowAnyApp"), "| gatewayAppId field present:", "gatewayAppId" in d)'
```

If `allowAnyApp` is not `True` or the grep is `0`, run `cd ~/self-hosted-tdx/kms && ./apply-auth-simple.sh`.

### C. DNS — Cloudflare gray-cloud / DNS-only (NOT proxied)

Proxying makes Cloudflare's edge decrypt the traffic → breaks the TEE rule. At the `outlayer.ai`
zone add a wildcard A record to the node's public IP:

```
*.dstack.outlayer.ai   A   <node-public-ip>   (DNS only / gray cloud — the orange cloud OFF)
```

`gateway.dstack.outlayer.ai` is covered by the wildcard (used as the gateway RPC `MY_URL` /
`RPC_DOMAIN`). For a different node you change BOTH the subdomain base (`<gateway-domain>`) and the
target IP — they are this node's values (`dstack.outlayer.ai` → `173.237.9.76`).

### D. Host resolver — public DNS + no negative caching (the ACME DNS-01 gotcha)

The node's resolver must use a reliable public DNS and NOT cache negative answers. Otherwise the
in-CVM certbot self-check queries the just-created `_acme-challenge.<domain>` TXT *before* it
propagates, the resolver caches the NXDOMAIN, serves it stale, and certbot times out after 300s
("challenge not found"). All CVMs resolve through the host (slirp), so fix it once on the host —
drop-in `/etc/systemd/resolved.conf.d/outlayer-acme-dns.conf`:

```ini
[Resolve]
DNS=1.1.1.1 8.8.8.8
Cache=no-negative
```

then:

```bash
sudo systemctl restart systemd-resolved && resolvectl flush-caches
```

Verify (after certbot has created the TXT, i.e. during bootstrap): `dig +short TXT _acme-challenge.<domain>`
returns the value. You can pre-confirm the resolver config now with `resolvectl status` (Current DNS
Server should be 1.1.1.1/8.8.8.8).

### E. Scoped Cloudflare API token (stashed on the node)

For in-CVM ACME DNS-01 (the ONLY production cert path in 0.5.11 — there is no operator-cert load
path). Create it in the Cloudflare dashboard → My Profile → API Tokens → Create Token → Custom token:

- **Permissions:** `Zone : DNS : Edit` **and** `Zone : Zone : Read`
- **Zone Resources:** Include → Specific zone → `outlayer.ai` (single zone only — least privilege)

Stash it on the node, never in git:

```bash
printf %s '<token>' > /home/outlayer/gateway-cf-token \
  && chown outlayer:outlayer /home/outlayer/gateway-cf-token \
  && chmod 600 /home/outlayer/gateway-cf-token
```

Verify it. A **zone-scoped token FAILS** `/user/tokens/verify` (that needs account scope) — test a
zone call instead:

```bash
curl -s -H "Authorization: Bearer $(cat /home/outlayer/gateway-cf-token)" \
  'https://api.cloudflare.com/client/v4/zones?name=outlayer.ai'   # -> "success":true
```

`40-deploy-gateway.sh` reads this file at deploy/bootstrap time and never echoes it. The deploy
ABORTS if the file is missing or empty.

### F. Gateway container image — pullable from inside the CVM

The guest boots and runs `docker compose up` against the pinned `GATEWAY_IMAGE`; it pulls from a
registry and has **no access to host-local images**, so the image MUST be published to a registry the
CVM can reach. The upstream Docker Hub image does NOT exist for 0.5.11, so we publish our own.

**Common path (fresh server, same version): just pull the already-published digest — NO rebuild.**
`gateway/gateway.env.template` already pins
`outlayer/dstack-gateway@sha256:072e01293f6f9904a863fc059c848812529f233aa0b87cc649dd955da76eaece`
(dstack 0.5.11). It is public on Docker Hub; the CVM pulls it at boot. You do nothing for the image —
just confirm it is pullable:

```bash
docker pull outlayer/dstack-gateway@sha256:072e01293f6f9904a863fc059c848812529f233aa0b87cc649dd955da76eaece
```

**Only when bumping the gateway version** do you rebuild + push (and re-pin the new digest in
`gateway/gateway.env`):

```bash
cd /home/outlayer/meta-dstack/dstack/gateway/dstack-app/builder
./build-image.sh dstacktee/dstack-gateway:0.5.11
docker tag  dstacktee/dstack-gateway:0.5.11 outlayer/dstack-gateway:0.5.11
docker login                                    # needs push creds for the `outlayer` Docker Hub org
docker push outlayer/dstack-gateway:0.5.11
docker logout
docker buildx imagetools inspect outlayer/dstack-gateway:0.5.11   # read the manifest @sha256 digest
# then set GATEWAY_IMAGE=outlayer/dstack-gateway@sha256:<new-digest> in gateway/gateway.env
```

> `docker login` needs **push credentials for the `outlayer` Docker Hub org** — an operator decision
> (supply your own org/creds, or pull the existing public digest and skip the rebuild entirely).

### G. Firewall — 443 + 9202 WAN-reachable, control plane loopback

The gateway's WAN ports are `443` (TLS) and `9202` (RPC tcp + WireGuard udp). The control plane
(admin `:9203`, guest-agent `:9206`) is protected by being mapped to the host **loopback**, so it
needs no firewall rule — it is unreachable from the WAN by binding, regardless of the firewall.

This node does **not** run a deny-by-default firewall (ufw is inactive; iptables `INPUT` policy is
`ACCEPT` with targeted DROP rules on the bridge interface for the KMS/auth/vmm control ports). So in
practice 443 + 9202 are already WAN-reachable once the gateway binds them — there is nothing to open.

If your node DOES run a deny-by-default firewall (ufw/nftables), you must explicitly allow inbound:

```bash
# only if you run ufw / a default-deny firewall:
sudo ufw allow 443/tcp
sudo ufw allow 9202/tcp
sudo ufw allow 9202/udp
# do NOT add rules for 9203/9206 — they stay loopback (the WAN gate is the host port binding).
# keep DEFAULT_FORWARD_POLICY=ACCEPT or CVM egress (slirp) breaks.
```

Confirm 443/9202 actually bind after deploy: `ss -ltnup | grep -E ':443 |:9202 '` (owned by
`qemu-system-x86`).

---

## Configure — `gateway/gateway.env`

On the node, copy the template and review the per-node values:

```bash
cd ~/self-hosted-tdx
cp gateway/gateway.env.template gateway/gateway.env   # gitignored — never commit
```

The template carries every value (domain, IP, image, addresses, mitigations). `CF_API_TOKEN` is read
from `/home/outlayer/gateway-cf-token` at deploy and `GATEWAY_APP_ID` is computed by the script —
leave both **empty** in the file.

**Per-node values you MUST change for a new server** (everything else is fixed/derived):

| Variable | This node | A new node changes it to |
|---|---|---|
| `SRV_DOMAIN` | `dstack.outlayer.ai` | the new gateway domain base (must match the DNS wildcard in C) |
| `PUBLIC_IP` | `173.237.9.76` | the new node's public IP (must match the DNS A record in C) |
| `RPC_DOMAIN` / `MY_URL` | `gateway.dstack.outlayer.ai` | derive from the new `SRV_DOMAIN` (`gateway.<SRV_DOMAIN>`) |
| `GATEWAY_IMAGE` | the pinned `@sha256:072e…` | unchanged unless you bumped the version (F) |
| `KMS_URL` | `https://kms.1022.dstack.org:11001` | unchanged (the per-node KMS slirp URL is the same on every node) |
| `OS_IMAGE` | `dstack-0.5.11` | unchanged unless you bumped dstack (must exist in `vmm-cli lsimage`) |

`gateway.env.template` marks these inline. The security-mitigation block (NET_MODE, admin loopback,
WAN ports) is **non-negotiable** — `40-deploy-gateway.sh` re-asserts it regardless, so a hand-run of
the upstream `deploy-to-vmm.sh` with this env stays safe too.

---

## Deploy

Run on the node as `outlayer` (owns the vmm + can read the CF-token file), from
`/home/outlayer/self-hosted-tdx`:

```bash
# 1) Dry-run / prep (NON-mutating): builds the app-compose, prints the app-id + the live steps.
sudo -u outlayer ./40-deploy-gateway.sh            # mode 'prep' (default)

# 2) Deploy the gateway CVM (LIVE): prep, then deploy + clean-DNS reboot + auto-set gatewayAppId.
sudo -u outlayer ./40-deploy-gateway.sh deploy
```

`deploy` mode does **L1-skipped + L2 + the gatewayAppId update**:

- **L1 (KMS allowlist) is skipped** — auth-simple runs with `allowAnyApp:true` (Prereq B), so a new
  app-id boots without an allowlist entry.
- **L2 deploys the CVM** with the security mitigations baked in (below), wrapped in the `/etc/hosts`
  KMS dance + a clean-DNS reboot (same as `40-deploy-keystore.sh`). Replace-on-redeploy removes any
  existing `dstack-gateway` CVM first (freeing `:443`/`:9202`).
- **It auto-sets `gatewayAppId`** in `outlayer-kms/auth-config.json` to this gateway's app-id and
  reloads `outlayer-kms-auth` (so the keystore can later register — see Prereq B and Gotchas). This
  is why no manual KMS edit is needed across redeploys.

Then it prints the remaining live steps:

```bash
# L3 — NOT a vmm restart. ⚠️ DO NOT `systemctl restart outlayer-dstack-vmm.service`: every CVM
#   (kms, workers, gateway) runs inside that service's cgroup, so restarting it KILLS them all.
#   The keystore registers with the gateway via a PER-VM URL at deploy time (no vmm.toml/restart):
#     vmm-cli deploy ... --gateway-url https://gateway.dstack.outlayer.ai:9202   (40-deploy-keystore.sh passes this)
#   gateway_urls in vmm.toml is only a fallback default for CVMs deployed without --gateway-url.

# L4 — obtain the *.dstack.outlayer.ai wildcard cert via in-CVM ACME DNS-01 (LIVE; once per cluster).
#   Run AFTER the gateway CVM is up (admin RPC live on 127.0.0.1:9203):  see "Bootstrap ACME" below.
```

Watch the gateway boot:

```bash
NAME=dstack-gateway CONTAINER=dstack-gateway-1 ./worker-ctl.sh follow
```

A healthy boot shows `tcp bridge listening on 0.0.0.0:443`, `endpoint=https://0.0.0.0:8000 (TCP +
mTLS)`, `endpoint=http://127.0.0.1:8001` (admin), the KMS issuing the app key (allowAnyApp), and the
image pulled.

---

## Bootstrap ACME (once per cluster)

After the gateway CVM is up and its admin RPC is reachable on `127.0.0.1:9203`, obtain the
`*.<SRV_DOMAIN>` wildcard cert via in-CVM ACME DNS-01 (Cloudflare):

```bash
sudo -u outlayer ./40-deploy-gateway.sh bootstrap
```

This runs `SetCertbotConfig` + `CreateDnsCredential` + `AddZtDomain` against the admin RPC →
`Bootstrap complete`. The cert then issues in the background:
`new certificate obtained from ACME … wildcard certificate for *.<SRV_DOMAIN> (89 days) …
CertResolver initialized with 1 domains`. Auto-renewal runs inside the CVM thereafter.

The ACME account + ZT-domain live on the CVM's encrypted disk/WaveKV and **survive a stop/start**, so
you do NOT re-run `bootstrap` after a restart. (Only re-run it on a fresh CVM / fresh cluster.)

---

## Verify (end-to-end)

```bash
# 1) Cert landed (CertResolver should show 1+ domains):
NAME=dstack-gateway CONTAINER=dstack-gateway-1 ./worker-ctl.sh logs | grep -iE 'CertResolver|wildcard certificate'

# 2) Public HTTPS reaches a keystore through the gateway (after the keystore is deployed gateway-mode):
curl https://<keystore-app-id>-8081.dstack.outlayer.ai/health     # -> the keystore's health response

# 3) The WAN ports are bound:
ss -ltnup | grep -E ':443 |:9202 '                                # qemu-system-x86 owns them
```

For the keystore side (gateway-mode deploy that produces the `<keystore-app-id>` URL), see
`40-deploy-keystore.sh` with `GATEWAY_URL=https://gateway.dstack.outlayer.ai:9202` (it adds
`--gateway` + injects the `port_policy` so ONLY `:8081` is reachable through the gateway, never the
guest-agent `:8090`).

### Reference: what worked end-to-end (testnet, 2026-06-19, `node-tdx-dal-2`)

1. Pinned `outlayer/dstack-gateway@sha256:072e…` (0.5.11); DNS `*.dstack.outlayer.ai A 173.237.9.76`
   **gray-cloud**; scoped CF token at `/home/outlayer/gateway-cf-token`; host resolver public DNS +
   `Cache=no-negative`; auth-simple patched (`allowAnyApp` + `gatewayAppId`).
2. `./40-deploy-gateway.sh deploy` → gateway CVM up; KMS issued the app key (allowAnyApp); image
   pulled; `gatewayAppId` auto-set in auth-config.
3. L3 NOT a vmm restart — the keystore uses `--gateway-url` per-VM.
4. `./40-deploy-gateway.sh bootstrap` → SetCertbotConfig + CreateDnsCredential + AddZtDomain →
   `Bootstrap complete`.
5. Cert issued: wildcard for `*.dstack.outlayer.ai` (89 days); auto-renewal running.

---

## Security mitigations (baked into the deploy; do not regress)

| # | Mitigation |
|---|---|
| C1 | OS_IMAGE=dstack-0.5.11 + GATEWAY_IMAGE = our digest-pinned `outlayer/dstack-gateway@sha256:…` (never the stale upstream 0.5.5 default, never an un-owned image). |
| C2 | Control plane stays off the WAN by **loopback host-port binding** (admin `127.0.0.1:9203`, guest-agent `127.0.0.1:9206`, KMS/auth/vmm loopback) — not by a firewall. Only `443` + `9202` (tcp+udp) are WAN. If a default-deny firewall is in use, allow exactly those two and keep `DEFAULT_FORWARD_POLICY=ACCEPT` (else CVM egress breaks). |
| C3 | `NET_MODE=user` (bridge skips the `--port` gate); admin RPC host map `127.0.0.1:9203` (loopback = the WAN gate) + in-CVM `ADMIN_LISTEN_ADDR=0.0.0.0` (with slirp the host forward reaches the guest eth0, not its loopback, so an in-CVM `127.0.0.1` bind is unreachable and the bootstrap hangs). Unauthenticated control plane — never WAN. |
| H1 | Gateway is per-app: don't gateway-enable workers; they stay outbound-only. |
| H2 | `--public-sysinfo` dropped; `--public-logs` kept (ops tooling needs the loopback `/logs`); keystore `port_policy` forwards ONLY :8081 through the gateway (never :8090). |
| M3 | CF token scoped to single-zone `Zone.DNS:Edit`+`Zone.Zone:Read`; read from the node file, never committed/echoed; rotate after redeploy/debug. |

## Ports

| Port (host) | → CVM | Exposure | Purpose |
|---|---|---|---|
| `0.0.0.0:443` | 443 | WAN | public HTTPS (TLS terminates in the gateway CVM) |
| `0.0.0.0:9202` tcp | 8000 | WAN | gateway RPC (attestation-gated `register_cvm`; `info`/`acme_info` are public, low-sensitivity) |
| `0.0.0.0:9202` udp | 51820 | WAN | WireGuard (a peer can't join without passing attested `register_cvm`) |
| `127.0.0.1:9203` | 8001 | loopback | admin RPC (certbot/DNS-cred/ZT-domain/exit) — MUST stay loopback |
| `127.0.0.1:9206` | 8090 | loopback | guest-agent (logs/measurements via worker-ctl.sh) |

## Ops — start / stop / restart / logs

The gateway CVM is managed like any other, via `worker-ctl.sh` (resolves it by name;
auto-picks the `dstack-gateway-1` container):

```bash
worker-ctl.sh status                      # list all CVMs (find dstack-gateway + its status)
NAME=dstack-gateway worker-ctl.sh logs    # gateway app logs (snapshot)
NAME=dstack-gateway worker-ctl.sh follow  # stream gateway logs (Ctrl-C to stop)
NAME=dstack-gateway worker-ctl.sh restart # stop -f + start  (re-runs the boot-time cert check)
NAME=dstack-gateway worker-ctl.sh stop    # stop the gateway CVM
NAME=dstack-gateway worker-ctl.sh start   # start a stopped gateway CVM
NAME=dstack-gateway worker-ctl.sh serial  # qemu boot/serial console (boot or attestation issues)
```

- **Restart is safe + keeps the cert:** the ACME account + wildcard cert live on the CVM's encrypted
  disk/WaveKV, so a stop/start comes back with the cert and **does NOT need a re-`bootstrap`**. (Use a
  restart to re-trigger a failed cert acquisition after fixing DNS — it re-runs the cert check on boot.)
- The guest-agent host port is reassigned on each start; `worker-ctl.sh` auto-discovers it.
- **Switch keystores:** the canonical URL is `https://<keystore-app-id>-8081.dstack.outlayer.ai`. Run
  several keystores; flip which app-id you publish (or, with the same app-id, the gateway load-balances
  by WG handshake). Keep `KEYSTORE_BASE_URL` stable for workers/coordinator.
- **Cert renewal** is automatic in the gateway CVM (distributed certbot). The CF token must stay valid.

## Redeploy / version bump

- **Redeploy (new config, same image):** `sudo -u outlayer ./40-deploy-gateway.sh deploy`. Replace-on-
  redeploy removes the old CVM first (freeing `:443`/`:9202`). The app-id changes per run
  (launch-token) — fine (`allowAnyApp`), and the deploy re-sets `gatewayAppId` to the new app-id +
  reloads auth-simple automatically. **A gateway redeploy changes the gateway app-id, so any
  gateway-enabled keystore must be re-registered** — it picks up the new `gatewayAppId` on its next
  boot/redeploy (the keystore verifies the gateway by that app-id over RA-TLS). Do **NOT** restart the
  vmm to apply changes — it kills every CVM.
- **Version bump (new gateway image):** rebuild + push the image (Prereq F), re-pin the new digest in
  `gateway/gateway.env`, then `./40-deploy-gateway.sh deploy`. Changing the image changes measurements
  → fine (`allowAnyApp`).

## Gotchas that cost time (handled in the script — don't repeat)

- **Bootstrap hangs at "Waiting for gateway admin API".** Cause: in-CVM `ADMIN_LISTEN_ADDR=127.0.0.1`
  — with `NET_MODE=user`, slirp's host-forward reaches the guest's eth0, NOT its loopback, so an
  in-CVM loopback bind is unreachable from the host's `127.0.0.1:9203`. Fix: `ADMIN_LISTEN_ADDR=0.0.0.0`
  (the host port map `127.0.0.1:9203` remains the WAN gate). Baked into `40-deploy-gateway.sh`.
- **ACME DNS-01 times out ("challenge not found", 300s).** Cause: negative DNS caching on the host
  resolver (see Prereq D). Fix the resolver, then re-trigger by **restarting the gateway CVM**
  (`NAME=dstack-gateway worker-ctl.sh restart`) — it re-runs the cert check on boot. The ACME account +
  ZT-domain survive a stop/start, so you do NOT re-run `bootstrap`.
- **Gateway-enabled apps (the keystore) reboot-loop with `Missing allowed dstack-gateway app id`.**
  (dstack-util `system_setup.rs:588` — a clean reboot right after `Filesystem options:
  encryption=true`, not a panic.) Cause: the KMS isn't returning the gateway's app-id to the keystore.
  Two requirements, both covered above: (a) auth-simple must be PATCHED so `gatewayAppId` is a real
  schema field that `checkAppBoot` returns (Prereq B / `apply-auth-simple.sh`); (b) the gateway's
  current app-id must be set in `auth-config.json` (`40-deploy-gateway.sh deploy` does this + reloads
  auth-simple). If you ever redeploy the gateway, redeploy/reboot the keystore so it re-verifies
  against the new app-id.
- **Do NOT `systemctl restart outlayer-dstack-vmm.service` to "apply" anything.** Every CVM
  (kms/workers/gateway) shares that service's cgroup → a restart KILLS them all. Use the per-VM
  `--gateway-url` (keystore) and `40-deploy-gateway.sh deploy` (gateway) instead.
- **`prep` mode prints an L1 KMS-allowlist block** as a fallback for nodes WITHOUT `allowAnyApp`. On
  this node `allowAnyApp` is set, so L1 is unnecessary — `deploy` mode skips it. Ignore the L1 block
  unless you deliberately run stock auth-simple.
