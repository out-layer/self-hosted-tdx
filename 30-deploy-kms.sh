#!/usr/bin/env bash
# Deploy the per-node dstack KMS as a CVM (production, auth-simple webhook).
# The KMS encrypts the worker's env so secrets never enter the measured compose.
#
# VERIFIED end-to-end on the live node (2026-06-17). This wraps upstream
# dstack/kms/dstack-app/deploy-simple.sh and drives bootstrap over RPC (no browser).
# Authoritative upstream refs: <dstack>/docs/deployment.md §"Deploy KMS as CVM",
# <dstack>/docs/auth-simple-operations.md.
#
# Run as root (writes systemd units); the services run as $NODE_USER.
# Prereqs: 00-host-setup.sh + 20-start-vmm.sh done (vmm on :11000), key-provider on :3443.
set -euo pipefail

NODE_USER="${NODE_USER:-outlayer}"
DSTACK="${DSTACK:-/home/$NODE_USER/meta-dstack/dstack}"      # dstack source tree
BUILD="${BUILD:-/home/$NODE_USER/meta-dstack/build}"          # vmm build dir (has images/)
KMSDIR="${KMSDIR:-/home/$NODE_USER/outlayer-kms}"             # our KMS state (config, token)
OS_IMAGE="${OS_IMAGE:-dstack-0.5.11}"
KMS_VER="${KMS_VER:-v0.5.11}"
# KMS container image, pinned by digest — MUST match $KMS_VER.
# deploy-simple.sh only defaults KMS_IMAGE inside the .env.simple TEMPLATE it writes when that file
# is MISSING. We pre-write .env.simple below, so that default never applies, and KMS_IMAGE is NOT in
# deploy-simple.sh's required_env_vars — an unset value silently renders `image:` empty and the CVM
# boots but app-compose.service dies with "services.kms.image must be a string" (KMS never listens,
# and every later `vmm-cli deploy --kms-url` fails with a TLS "connection reset by peer").
KMS_IMAGE="${KMS_IMAGE:-dstacktee/dstack-kms@sha256:84b793feed825a5b5e70d04386e931e0e110461492793f17ab2128e39808d989}"
IMGSRV_PORT="${IMGSRV_PORT:-11008}"     # host-local OS-image server (KMS image verification)
VMM_RPC="${VMM_RPC:-http://127.0.0.1:11000}"
AUTH_PORT="${AUTH_PORT:-3001}"          # auth-simple host port (bound 127.0.0.1)
KMS_PORT="${KMS_PORT:-11001}"           # KMS RPC host port -> CVM:8000
GUEST_AGENT_PORT="${GUEST_AGENT_PORT:-11005}"   # guest-agent host port -> CVM:8090
KMS_DOMAIN="${KMS_DOMAIN:-kms.1022.dstack.org}" # *.1022.dstack.org -> 10.0.2.2 (host) inside CVMs
BUN="/home/$NODE_USER/.bun/bin/bun"
AS="$DSTACK/kms/auth-simple"
APP="$DSTACK/kms/dstack-app"
# OS image hash (auth-simple osImages entry) = digest.txt of the guest image.
OS_HASH="0x$(cat "$BUILD/images/$OS_IMAGE/digest.txt")"

echo "=== [1/8] bun (auth-simple runtime) ==="
sudo -u "$NODE_USER" -H bash -lc "command -v bun >/dev/null || (curl -fsSL https://bun.sh/install | bash)"

echo "=== [2/8] auth-simple: bind 127.0.0.1 + install deps ==="
# Bind loopback (secure). CVMs still reach it via 10.0.2.2 (qemu user-net -> host loopback),
# the same path the local-key-provider uses on :3443. sed delim is '#' ('||' + '/' in repl).
if ! grep -q "hostname:" "$AS/index.ts"; then
  sed -i 's#^  fetch: app.fetch,#  hostname: process.env.HOST || "127.0.0.1",\n  fetch: app.fetch,#' "$AS/index.ts"
fi
sudo -u "$NODE_USER" -H bash -lc "cd '$AS' && $BUN install"

echo "=== [3/8] auth-config.json (osImages set; kms.mrAggregated filled in step 6) ==="
# kms.mrAggregated starts EMPTY because the value is only knowable after the KMS CVM exists (it is
# a hash over that CVM's MRTD+RTMR0-3, so it differs per node AND per KMS redeploy). Step 6 reads it
# from the running CVM and writes it back here.
# It is NOT optional: /bootAuth/kms gates Onboard.Bootstrap too, not just KMS HA onboarding — with
# an empty list the KMS refuses to bootstrap ("boot denied: aggregated MR not allowed"), stays in
# onboard mode on plain http, and every `vmm-cli deploy --kms-url` then dies on the TLS handshake.
# App entries: allowAnyApp + the node device allowlist, both written by kms/apply-auth-simple.sh
# (README step 4b). This script only seeds the file; on an existing config it changes nothing
# (setdefault), so the device allowlist is enforced only once step 4b has run.
# kms.devices is seeded EMPTY (upstream: empty = any device) so the KMS CVM can bootstrap.
sudo -u "$NODE_USER" mkdir -p "$KMSDIR"
if [ -s "$KMSDIR/auth-config.json" ]; then
  echo "  keeping existing $KMSDIR/auth-config.json (osImages refreshed)"
  sudo -u "$NODE_USER" python3 - "$KMSDIR/auth-config.json" "$OS_HASH" <<'PY'
import json, sys
p, os_hash = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c.setdefault("osImages", [])
if os_hash not in c["osImages"]:
    c["osImages"].append(os_hash)
c.setdefault("kms", {}).setdefault("mrAggregated", [])
c["kms"].setdefault("allowAnyDevice", False)
c["kms"].setdefault("devices", [])
c.setdefault("apps", {})
json.dump(c, open(p, "w"), indent=2)
PY
else
  cat > "$KMSDIR/auth-config.json" <<JSON
{
  "osImages": ["$OS_HASH"],
  "kms": { "mrAggregated": [], "allowAnyDevice": false, "devices": [] },
  "apps": {}
}
JSON
fi
chown -R "$NODE_USER:$NODE_USER" "$KMSDIR"

cat > /etc/systemd/system/outlayer-kms-auth.service <<UNIT
[Unit]
Description=OutLayer KMS auth-simple webhook (boot authorization)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$AS
Environment=PORT=$AUTH_PORT
Environment=HOST=127.0.0.1
Environment=AUTH_CONFIG_PATH=$KMSDIR/auth-config.json
ExecStart=$BUN run index.ts
Restart=on-failure
RestartSec=5
User=$NODE_USER
Group=$NODE_USER
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now outlayer-kms-auth
sleep 2
curl -s "http://127.0.0.1:$AUTH_PORT/" -o /dev/null -w "auth-simple GET /: %{http_code}\n"

echo "=== [4/8] local OS-image server (the KMS verifies the guest image it boots) ==="
# [core.image] verify=true makes the KMS download $OS_IMAGE.tar.gz and check its hash against the
# CVM it is asked to authorize, with a 2-minute download_timeout. Serving that ~180MB tarball from
# the host (10.0.2.2:$IMGSRV_PORT, loopback-bound — slirp maps the CVM's 10.0.2.2 to host loopback,
# same path the key-provider uses) keeps it off the WAN and out of timeout territory.
IMGSRV="$KMSDIR/imgsrv"
sudo -u "$NODE_USER" mkdir -p "$IMGSRV"
# Pack it from the image THIS vmm boots, FLAT (members at the archive root: ./sha256sum.txt, ...).
# Do NOT serve the GitHub release tarball: it nests everything under $OS_IMAGE/, and the KMS
# extracts then runs `sha256sum -c sha256sum.txt` in the extraction root, so an app asking for keys
# is denied with "Checksum verification failed: sha256sum: sha256sum.txt: No such file or directory"
# — which surfaces as the CVM rebooting in a loop, not as a KMS error.
TARBALL_OK=false
if [ -s "$IMGSRV/$OS_IMAGE.tar.gz" ]; then
  LIST="$(tar -tzf "$IMGSRV/$OS_IMAGE.tar.gz" 2>/dev/null || true)"
  case "$LIST" in *"./sha256sum.txt"*) TARBALL_OK=true ;; esac
  $TARBALL_OK || echo "  existing $OS_IMAGE.tar.gz has the wrong (nested) layout — repacking"
fi
if ! $TARBALL_OK; then
  echo "  packing $OS_IMAGE.tar.gz from $BUILD/images/$OS_IMAGE ..."
  sudo -u "$NODE_USER" tar -czf "$IMGSRV/$OS_IMAGE.tar.gz" -C "$BUILD/images/$OS_IMAGE" .
fi
cat > /etc/systemd/system/outlayer-imgsrv.service <<UNIT
[Unit]
Description=OutLayer local dstack OS-image server (for KMS image verify)
After=network-online.target
[Service]
Type=simple
WorkingDirectory=$IMGSRV
ExecStart=/usr/bin/python3 -m http.server $IMGSRV_PORT --bind 127.0.0.1 --directory $IMGSRV
Restart=on-failure
User=$NODE_USER
Group=$NODE_USER
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now outlayer-imgsrv
sleep 1
curl -s -o /dev/null -w "imgsrv HEAD $OS_IMAGE.tar.gz: %{http_code}\n" -I \
  "http://127.0.0.1:$IMGSRV_PORT/$OS_IMAGE.tar.gz"

echo "=== [5/8] .env.simple + deploy KMS CVM (upstream deploy-simple.sh) ==="
# The KMS container runs on the CVM's HOST network instead of publishing 8000. This is what the
# first node runs; keep every node identical here, because compose-simple.yaml is MEASURED — any
# difference changes the KMS app-compose hash and therefore its mr_aggregated.
# Idempotent: skipped once applied, original kept as .orig.
CS="$APP/compose-simple.yaml"
if ! grep -q 'network_mode: host' "$CS"; then
  cp "$CS" "$CS.orig"
  python3 - "$CS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = "    image: ${KMS_IMAGE}\n"
assert a in s, "compose-simple.yaml: image anchor not found — dstack version drift?"
s = s.replace(a, a + "    network_mode: host\n", 1)
b = "    ports:\n      - 8000:8000\n"
assert b in s, "compose-simple.yaml: ports anchor not found — dstack version drift?"
s = s.replace(b, "", 1)
open(p, "w").write(s)
print("  patched compose-simple.yaml (network_mode: host; backup .orig)")
PY
else
  echo "  compose-simple.yaml already on host networking"
fi

TOKEN_FILE="$KMSDIR/kms-admin-token.txt"
[ -f "$TOKEN_FILE" ] || { openssl rand -hex 16 > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; chown "$NODE_USER:$NODE_USER" "$TOKEN_FILE"; }
# KMS_IMAGE must be set HERE (see the note at the top): deploy-simple.sh's own default only lands
# in the .env.simple it generates when the file is absent, which never happens once we write it.
#
# KNOWN, DELIBERATE difference from the FIRST node (deployed before this script was hardened):
# it binds KMS_RPC_ADDR / the auth webhook / imgsrv on 0.0.0.0, this script binds them on the host
# loopback. CVMs are unaffected — qemu slirp maps their 10.0.2.2 to the host loopback, which is the
# same path the local key-provider on :3443 already uses, and all three were verified end-to-end on
# the second node (webhook received the KMS boot request, the KMS downloaded the image from imgsrv,
# and a worker CVM reached the KMS at kms.1022.dstack.org:11001). Loopback is strictly tighter than
# relying on ufw alone. Align the first node DOWN to this when it is next redeployed; do not flip
# this script UP to 0.0.0.0.
cat > "$APP/.env.simple" <<ENV
VMM_RPC=$VMM_RPC
AUTH_WEBHOOK_URL=http://10.0.2.2:$AUTH_PORT
KMS_RPC_ADDR=127.0.0.1:$KMS_PORT
GUEST_AGENT_ADDR=127.0.0.1:$GUEST_AGENT_PORT
IMAGE_DOWNLOAD_URL=http://10.0.2.2:$IMGSRV_PORT/$OS_IMAGE.tar.gz
VERIFY_IMAGE=true
OS_IMAGE=$OS_IMAGE
KMS_IMAGE=$KMS_IMAGE
ADMIN_TOKEN=$(cat "$TOKEN_FILE")
ENV
chmod 600 "$APP/.env.simple"; chown "$NODE_USER:$NODE_USER" "$APP/.env.simple"
# Never stack a second KMS: deploy-simple.sh always creates a NEW CVM named 'kms' and two of them
# fight over :$KMS_PORT. If one exists we SKIP the deploy and resume at the allowlist+bootstrap
# steps — that is the normal path when a first run died before bootstrap. Deliberately never
# auto-removed: deleting a HEALTHY KMS CVM destroys its sealed root key and every app key derived
# from it. To start over deliberately:  NAME=kms ./worker-ctl.sh remove
if sudo -u "$NODE_USER" -H bash -lc \
     "python3 '$DSTACK/vmm/src/vmm-cli.py' --url '$VMM_RPC' lsvm 2>/dev/null" | grep -qw kms; then
  echo "  a CVM named 'kms' already exists — skipping deploy, resuming at allowlist + bootstrap"
else
  # deploy-simple.sh skips its interactive confirm when stdin is not a tty (</dev/null).
  sudo -u "$NODE_USER" -H bash -lc "cd '$APP' && ./deploy-simple.sh < /dev/null"
fi

echo "=== [6/8] allowlist the KMS's own mr_aggregated (required before it may bootstrap) ==="
# Authoritative source: the CVM's guest agent, which serves the measured TCB of the running VM.
# (The same value shows up in `journalctl -u outlayer-kms-auth` as the denied boot request.)
echo "  waiting for the KMS guest agent on :$GUEST_AGENT_PORT ..."
MR_AGG=""
for i in $(seq 1 30); do
  MR_AGG=$(curl -s --max-time 5 "http://127.0.0.1:$GUEST_AGENT_PORT/prpc/Info?json" \
    | python3 -c 'import sys,json
try:
    print(json.loads(json.load(sys.stdin)["tcb_info"])["mr_aggregated"])
except Exception:
    pass' 2>/dev/null || true)
  [ -n "$MR_AGG" ] && break
  sleep 6
done
[ -n "$MR_AGG" ] || { echo "Could not read mr_aggregated from the KMS guest agent" >&2; exit 1; }
echo "  mr_aggregated: $MR_AGG"
sudo -u "$NODE_USER" python3 - "$KMSDIR/auth-config.json" "0x$MR_AGG" <<'PY'
import json, sys
p, mr = sys.argv[1], sys.argv[2]
c = json.load(open(p))
lst = c.setdefault("kms", {}).setdefault("mrAggregated", [])
norm = lambda h: h.lower().removeprefix("0x")
if norm(mr) not in [norm(x) for x in lst]:
    lst.append(mr)
    json.dump(c, open(p, "w"), indent=2)
    print("  added to kms.mrAggregated")
else:
    print("  already allowlisted")
PY
systemctl restart outlayer-kms-auth
sleep 2

echo "=== [7/8] bootstrap KMS over RPC (no browser) ==="
echo "Waiting for the KMS onboard server (http on :$KMS_PORT) ..."
for i in $(seq 1 30); do
  curl -s "http://127.0.0.1:$KMS_PORT/" -o /dev/null --max-time 4 2>/dev/null && break || sleep 6
done
# Already bootstrapped AND finished? Then the KMS answers https and there is nothing to do —
# re-running Bootstrap would pointlessly re-key a KMS that may already have issued app keys.
if curl -sk -o /dev/null --max-time 8 -X POST "https://127.0.0.1:$KMS_PORT/prpc/GetMeta?json" \
     -H "Content-Type: application/json" --data '{}'; then
  echo "  KMS already serves https — skipping bootstrap"
else
  # prpc over JSON needs the '?json' suffix and the 'Onboard.' service prefix.
  # NOTE: capture, then truncate. Piping curl into `head -c` under `set -o pipefail` kills the
  # script — head closes the pipe, curl dies of SIGPIPE, and Onboard.Finish never runs (which
  # leaves the KMS bootstrapped but stuck on onboarding-http forever).
  BOOT_RESP="$(curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Bootstrap?json" \
    -H "Content-Type: application/json" --data "{\"domain\":\"$KMS_DOMAIN\"}" --max-time 60 || true)"
  echo "  Bootstrap: ${BOOT_RESP:0:200}"
  FINISH_RESP="$(curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Finish?json" \
    -H "Content-Type: application/json" --data '{}' --max-time 30 || true)"
  echo "  Finish: ${FINISH_RESP:0:200}"
  sleep 7
fi

echo "=== [8/8] verify KMS is serving mTLS https ==="
# After Finish the KMS switches to https on :$KMS_PORT (CVM:8000) and serves the KMS service.
META="$(curl -sk -X POST "https://127.0.0.1:$KMS_PORT/prpc/GetMeta?json" \
  -H "Content-Type: application/json" --data '{}' --max-time 10 || true)"
[ -n "$META" ] || { echo "KMS still not serving https — check: outlayer logs kms" >&2; exit 1; }
echo "  GetMeta: ${META:0:300}"
echo "Done. The vmm already points CVMs at https://$KMS_DOMAIN:$KMS_PORT (vmm.toml kms_urls)."
echo "Next: ./40-deploy-worker.sh <version>  (then add the worker app to $KMSDIR/auth-config.json)."
