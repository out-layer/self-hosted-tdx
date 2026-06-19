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

## Security mitigations (baked into the deploy; do not regress)

| # | Mitigation |
|---|---|
| C1 | OS_IMAGE=dstack-0.5.11 + GATEWAY_IMAGE = our digest-pinned `outlayer/dstack-gateway@sha256:…` (never the stale upstream 0.5.5 default, never an un-owned image). |
| C2 | Host firewall (ufw/iptables): WAN = only 22, 24567 (NEAR P2P) + the gateway's 443 & 9202; keep KMS/auth-simple/vmm/admin/agent loopback. `DEFAULT_FORWARD_POLICY=ACCEPT` or CVM egress breaks. |
| C3 | `NET_MODE=user` (bridge skips the `--port` gate); admin RPC `127.0.0.1:9203` host map **and** in-CVM `ADMIN_LISTEN_ADDR=127.0.0.1`. The admin RPC is an unauthenticated control plane — never WAN. |
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

## Ops

```bash
NAME=dstack-gateway CONTAINER=dstack-gateway-1 worker-ctl.sh follow   # gateway app logs
NAME=dstack-gateway worker-ctl.sh status | restart | stop | start
```

- **Switch keystores:** the canonical URL is `https://<keystore-app-id>-8081.dstack.outlayer.ai`. Run
  several keystores; flip which app-id you publish (or, with the same app-id, the gateway load-balances
  by WG handshake). Keep `KEYSTORE_BASE_URL` stable for workers/coordinator.
- **Cert renewal** is automatic in the gateway CVM (distributed certbot). The CF token must stay valid.
- **Version bump:** rebuild + push the gateway image, re-pin the digest in `gateway/gateway.env`,
  re-run `40-deploy-gateway.sh deploy` (changing the image changes measurements → fine, allowAnyApp).
```
