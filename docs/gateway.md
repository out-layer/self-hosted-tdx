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

## Prerequisites (one-time)

1. **Cloudflare DNS — gray-cloud / DNS-only (NOT proxied).** Proxying makes Cloudflare's edge decrypt
   the traffic → breaks the TEE rule. Add at the `outlayer.ai` zone:
   ```
   *.dstack.outlayer.ai   A   <node-public-ip>   (DNS only / gray cloud)
   ```
   `gateway.dstack.outlayer.ai` is covered by the wildcard (used as the gateway RPC `MY_URL`).

   > **⚠️ Host resolver (critical for ACME DNS-01).** The node's resolver must use a reliable public
   > DNS and NOT cache negative answers. Otherwise the in-CVM certbot self-check queries the
   > just-created `_acme-challenge.<domain>` TXT *before* it propagates, the resolver caches the
   > NXDOMAIN, serves it stale, and certbot times out after 300s ("challenge not found"). All CVMs
   > resolve through the host (slirp), so fix it once on the host — drop-in
   > `/etc/systemd/resolved.conf.d/outlayer-acme-dns.conf`:
   > ```
   > [Resolve]
   > DNS=1.1.1.1 8.8.8.8
   > Cache=no-negative
   > ```
   > then `sudo systemctl restart systemd-resolved && resolvectl flush-caches`. Verify:
   > `dig +short TXT _acme-challenge.<domain>` returns the value once certbot has created it.
2. **Scoped Cloudflare API token** for in-CVM ACME DNS-01 (the ONLY production cert path in 0.5.11 —
   there is no operator-cert load path). Scope: `Zone.DNS:Edit` + `Zone.Zone:Read` on the
   `outlayer.ai` zone only. Stash it on the node, never in git:
   ```
   printf %s '<token>' > /home/outlayer/gateway-cf-token && chown outlayer:outlayer /home/outlayer/gateway-cf-token && chmod 600 /home/outlayer/gateway-cf-token
   ```
   Verify it (a zone-scoped token FAILS `/user/tokens/verify` — test a zone call instead):
   ```
   curl -s -H "Authorization: Bearer $(cat /home/outlayer/gateway-cf-token)" \
     'https://api.cloudflare.com/client/v4/zones?name=outlayer.ai'   # -> "success":true
   ```
3. **Gateway container image** built from our pinned 0.5.11 source and pushed to a registry the CVM
   can pull (the guest runs `docker compose up --build`; it has no access to host-local images). We
   publish `outlayer/dstack-gateway` and pin the digest in `gateway/gateway.env.template`:
   ```
   cd /home/outlayer/meta-dstack/dstack/gateway/dstack-app/builder && ./build-image.sh dstacktee/dstack-gateway:0.5.11
   docker tag  dstacktee/dstack-gateway:0.5.11 outlayer/dstack-gateway:0.5.11
   docker login && docker push outlayer/dstack-gateway:0.5.11 && docker logout    # then pin the @sha256 digest
   ```
4. `gateway/gateway.env` on the node = `cp gateway/gateway.env.template gateway/gateway.env`. The
   template carries every value (domain, IP, image, addresses, mitigations); `CF_API_TOKEN` is read
   from the node file at deploy and `GATEWAY_APP_ID` is computed by the script — leave both empty.

## Deploy

Run on the node as `outlayer` (owns the vmm + can read the CF-token file), from
`/home/outlayer/self-hosted-tdx`:

```bash
# 1) Dry-run / prep (NON-mutating): builds the app-compose, prints the app-id + the live steps.
sudo -u outlayer ./40-deploy-gateway.sh            # mode 'prep' (default)

# 2) L2 — deploy the gateway CVM (LIVE): prep, then deploy + clean-DNS reboot.
sudo -u outlayer ./40-deploy-gateway.sh deploy
```

`deploy` mode does **L1-skipped + L2**: L1 (KMS allowlist) is unnecessary because auth-simple runs
with `allowAnyApp:true`; L2 deploys the CVM with the security mitigations baked in (below), wrapped in
the `/etc/hosts` KMS dance + a clean-DNS reboot (same as `40-deploy-keystore.sh`). It then prints the
remaining live steps:

```bash
# L3 — NOT a vmm restart. ⚠️ DO NOT `systemctl restart outlayer-dstack-vmm.service`: every CVM
#   (kms, workers, gateway) runs inside that service's cgroup, so restarting it KILLS them all.
#   The keystore registers with the gateway via a PER-VM URL at deploy time (no vmm.toml/restart):
#     vmm-cli deploy ... --gateway-url https://gateway.dstack.outlayer.ai:9202     (40-deploy-keystore.sh passes this)
#   gateway_urls in vmm.toml is only a fallback default for CVMs deployed without --gateway-url.

# L4 — obtain the *.dstack.outlayer.ai wildcard cert via in-CVM ACME DNS-01 (LIVE; once per cluster).
#   Run AFTER the gateway CVM is up (admin RPC live on 127.0.0.1:9203):
sudo -u outlayer ./40-deploy-gateway.sh bootstrap

# L5 — (keystore step) redeploy the keystore with --gateway + a port policy so ONLY :8081 is reachable
#   through the gateway (never the guest-agent :8090 logs). vmm-cli compose has no flag for this, so
#   inject into the keystore app-compose AFTER 40-deploy-keystore.sh's compose step, BEFORE deploy:
jq '.gateway_enabled=true | .public_tcbinfo=true | .port_policy={restrict_mode:true, ports:[{port:8081}]}' \
   keystore/app-compose.json > keystore/app-compose.gw.json
```

## Verified end-to-end (testnet, 2026-06-19) — the happy path + gotchas

What actually worked, in order, on `node-tdx-dal-2`:

1. Built `outlayer/dstack-gateway:0.5.11` from the on-node 0.5.11 source, `docker push`ed it, pinned
   the `@sha256:072e…` digest. DNS `*.dstack.outlayer.ai A 173.237.9.76` **gray-cloud**; scoped CF
   token at `/home/outlayer/gateway-cf-token`; host resolver set to public DNS + `Cache=no-negative`.
2. `sudo -u outlayer ./40-deploy-gateway.sh deploy` → gateway CVM up. Boot log shows
   `tcp bridge listening on 0.0.0.0:443`, `endpoint=https://0.0.0.0:8000 (TCP + mTLS)`,
   `endpoint=http://127.0.0.1:8001` (admin). KMS issued the app key (allowAnyApp); image pulled.
3. **L3 is NOT a vmm restart** — the keystore uses `--gateway-url` per-VM. Restarting
   `outlayer-dstack-vmm.service` would kill every CVM (they share its cgroup).
4. `sudo -u outlayer ./40-deploy-gateway.sh bootstrap` → SetCertbotConfig + CreateDnsCredential +
   AddZtDomain → `Bootstrap complete`.
5. Cert issued: `new certificate obtained from ACME … wildcard certificate for *.dstack.outlayer.ai
   (89 days) … CertResolver initialized with 1 domains`. Auto-renewal task running.

Verify the cert any time:
```
NAME=dstack-gateway CONTAINER=dstack-gateway-1 worker-ctl.sh logs | grep -iE 'CertResolver|wildcard certificate'
```

### Gotchas that cost time (fixed in the script — don't repeat)
- **Bootstrap hangs at "Waiting for gateway admin API".** Cause: in-CVM `ADMIN_LISTEN_ADDR=127.0.0.1`
  — with `NET_MODE=user`, slirp's host-forward reaches the guest's eth0, NOT its loopback, so an
  in-CVM loopback bind is unreachable from the host's `127.0.0.1:9203`. Fix: `ADMIN_LISTEN_ADDR=0.0.0.0`
  (the host port map `127.0.0.1:9203` remains the WAN gate). Baked into `40-deploy-gateway.sh`.
- **ACME DNS-01 times out ("challenge not found", 300s).** Cause: negative DNS caching on the host
  resolver (see the prerequisite above). Fix the resolver, then re-trigger by **restarting the gateway
  CVM** (`NAME=dstack-gateway worker-ctl.sh restart`) — it re-runs the cert check on boot. The ACME
  account + ZT-domain live on the CVM's encrypted disk/WaveKV and survive a stop/start, so you do NOT
  need to re-run `bootstrap`.
- **Redeploy** (`./40-deploy-gateway.sh deploy` again) replaces the gateway in place (replace-on-redeploy
  removes the old CVM first, freeing :443/:9202); the app-id changes per run (launch-token), which is
  fine (allowAnyApp). Deploy + the matching `.app_env` are produced in the same run.
- **Gateway-enabled apps (the keystore) need the KMS to allow THIS gateway's app-id.** Otherwise the
  app reboot-loops at first boot with `Error: Missing allowed dstack-gateway app id` (dstack-util
  `system_setup.rs:588`) — a clean reboot right after `Filesystem options: encryption=true`, not a
  panic. `40-deploy-gateway.sh deploy` now writes `gatewayAppId=<this gateway's app-id>` into the KMS
  auth-config (`outlayer-kms/auth-config.json`) + reloads `outlayer-kms-auth` automatically, so it
  tracks the per-redeploy gateway app-id with NO manual step. The gateway-enabled CVM verifies the
  gateway by that app-id over RA-TLS (using `"any"` instead would skip the check — a downgrade).

## Security mitigations (baked into the deploy; do not regress)

| # | Mitigation |
|---|---|
| C1 | OS_IMAGE=dstack-0.5.11 + GATEWAY_IMAGE = our digest-pinned `outlayer/dstack-gateway@sha256:…` (never the stale upstream 0.5.5 default, never an un-owned image). |
| C2 | Host firewall (ufw/iptables): WAN = only 22, 24567 (NEAR P2P) + the gateway's 443 & 9202; keep KMS/auth-simple/vmm/admin/agent loopback. `DEFAULT_FORWARD_POLICY=ACCEPT` or CVM egress breaks. |
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
- **Re-deploy** (new image / config): `sudo -u outlayer ./40-deploy-gateway.sh deploy` (replace-on-redeploy
  removes the old CVM first). **Do NOT** restart the vmm to apply changes — it kills every CVM.

- **Switch keystores:** the canonical URL is `https://<keystore-app-id>-8081.dstack.outlayer.ai`. Run
  several keystores; flip which app-id you publish (or, with the same app-id, the gateway load-balances
  by WG handshake). Keep `KEYSTORE_BASE_URL` stable for workers/coordinator.
- **Cert renewal** is automatic in the gateway CVM (distributed certbot). The CF token must stay valid.
- **Version bump:** rebuild + push the gateway image, re-pin the digest in `gateway/gateway.env`,
  re-run `40-deploy-gateway.sh deploy` (changing the image changes measurements → fine, allowAnyApp).
```
