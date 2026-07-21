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

echo "=== [1/7] bun (auth-simple runtime) ==="
sudo -u "$NODE_USER" -H bash -lc "command -v bun >/dev/null || (curl -fsSL https://bun.sh/install | bash)"

echo "=== [2/7] auth-simple: bind 127.0.0.1 + install deps ==="
# Bind loopback (secure). CVMs still reach it via 10.0.2.2 (qemu user-net -> host loopback),
# the same path the local-key-provider uses on :3443. sed delim is '#' ('||' + '/' in repl).
if ! grep -q "hostname:" "$AS/index.ts"; then
  sed -i 's#^  fetch: app.fetch,#  hostname: process.env.HOST || "127.0.0.1",\n  fetch: app.fetch,#' "$AS/index.ts"
fi
sudo -u "$NODE_USER" -H bash -lc "cd '$AS' && $BUN install"

echo "=== [3/7] auth-config.json (osImages set; kms.mrAggregated empty) ==="
# NOTE: empty kms.mrAggregated is fine for a SINGLE primary KMS. /bootAuth/kms is only
# called for KMS HA onboarding (GetKmsKey); the primary unseals its root key locally
# (local-key-provider) on restart and never consults the webhook for itself. App (worker)
# entries are added later by 40-deploy-worker.sh (appId + composeHash).
sudo -u "$NODE_USER" mkdir -p "$KMSDIR"
cat > "$KMSDIR/auth-config.json" <<JSON
{
  "osImages": ["$OS_HASH"],
  "kms": { "mrAggregated": [], "allowAnyDevice": true },
  "apps": {}
}
JSON
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

echo "=== [4/7] local OS-image server (the KMS verifies the guest image it boots) ==="
# [core.image] verify=true makes the KMS download $OS_IMAGE.tar.gz and check its hash against the
# CVM it is asked to authorize, with a 2-minute download_timeout. Serving that ~180MB tarball from
# the host (10.0.2.2:$IMGSRV_PORT, loopback-bound — slirp maps the CVM's 10.0.2.2 to host loopback,
# same path the key-provider uses) keeps it off the WAN and out of timeout territory.
IMGSRV="$KMSDIR/imgsrv"
sudo -u "$NODE_USER" mkdir -p "$IMGSRV"
if [ ! -s "$IMGSRV/$OS_IMAGE.tar.gz" ]; then
  echo "  fetching $OS_IMAGE.tar.gz once (~180MB)..."
  sudo -u "$NODE_USER" curl -fsSL -o "$IMGSRV/$OS_IMAGE.tar.gz" \
    "https://github.com/Dstack-TEE/meta-dstack/releases/download/$KMS_VER/$OS_IMAGE.tar.gz"
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

echo "=== [5/7] .env.simple + deploy KMS CVM (upstream deploy-simple.sh) ==="
TOKEN_FILE="$KMSDIR/kms-admin-token.txt"
[ -f "$TOKEN_FILE" ] || { openssl rand -hex 16 > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; chown "$NODE_USER:$NODE_USER" "$TOKEN_FILE"; }
# KMS_IMAGE must be set HERE (see the note at the top): deploy-simple.sh's own default only lands
# in the .env.simple it generates when the file is absent, which never happens once we write it.
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
# Refuse to stack a second KMS: deploy-simple.sh always creates a NEW CVM named 'kms', and two of
# them fight over :$KMS_PORT. Deliberately NOT auto-removed — deleting a HEALTHY KMS CVM destroys
# its sealed root key and every app key derived from it. Only a KMS that never came up is safe to
# drop by hand:  NAME=kms ./worker-ctl.sh remove
if sudo -u "$NODE_USER" -H bash -lc \
     "python3 '$DSTACK/vmm/src/vmm-cli.py' --url '$VMM_RPC' lsvm 2>/dev/null" | grep -qw kms; then
  echo "A CVM named 'kms' already exists on this vmm." >&2
  echo "  healthy?  -> nothing to do; this script is not needed." >&2
  echo "  broken?   -> NAME=kms $(dirname "$0")/worker-ctl.sh remove   # deletes CVM + disk" >&2
  exit 1
fi
# deploy-simple.sh skips its interactive confirm when stdin is not a tty (</dev/null).
sudo -u "$NODE_USER" -H bash -lc "cd '$APP' && ./deploy-simple.sh < /dev/null"

echo "=== [6/7] bootstrap KMS over RPC (no browser) ==="
echo "Waiting for the KMS onboard server (http on :$KMS_PORT) ..."
for i in $(seq 1 30); do
  curl -s "http://127.0.0.1:$KMS_PORT/" -o /dev/null --max-time 4 2>/dev/null && break || sleep 6
done
# prpc over JSON needs the '?json' suffix and the 'Onboard.' service prefix.
curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Bootstrap?json" \
  -H "Content-Type: application/json" --data "{\"domain\":\"$KMS_DOMAIN\"}" --max-time 60 | head -c 400; echo
curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Finish?json" \
  -H "Content-Type: application/json" --data '{}' --max-time 30 || true
sleep 7

echo "=== [7/7] verify KMS is serving mTLS https ==="
# After Finish the KMS switches to https on :$KMS_PORT (CVM:8000) and serves the KMS service.
curl -sk -X POST "https://127.0.0.1:$KMS_PORT/prpc/GetMeta?json" \
  -H "Content-Type: application/json" --data '{}' --max-time 10 | head -c 300; echo
echo
echo "Done. The vmm already points CVMs at https://$KMS_DOMAIN:$KMS_PORT (vmm.toml kms_urls)."
echo "Next: ./40-deploy-worker.sh <version>  (then add the worker app to $KMSDIR/auth-config.json)."
