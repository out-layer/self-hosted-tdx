#!/usr/bin/env bash
# Prepare a dstack-gateway CVM deploy for the self-hosted TDX node — the TEE TLS terminator that
# gives the keystore a public HTTPS endpoint https://<app-id>-8081.dstack.outlayer.ai (TLS
# terminates INSIDE the attested gateway; keys never leave the TEE). Mirrors 40-deploy-keystore.sh.
#
# WHAT THIS SCRIPT DOES (all NON-mutating to live services):
#   1. Validates gateway/gateway.env + re-asserts the security mitigations (C2/C3/H2/M3).
#   2. Reads CF_API_TOKEN from the node file at runtime (never echoes it).
#   3. Builds the gateway app-compose (.app-compose.json) via vmm-cli `compose` — this only writes
#      a JSON file, it does NOT touch any running CVM/KMS/vmm.
#   4. Computes the app-id (= sha256(.app-compose.json)[:40]) and the compose hash.
#   5. PRINTS the exact, ordered LIVE-MUTATION commands for the human to run (KMS allowlist add,
#      the real `vmm-cli deploy`, vmm.toml gateway_urls, bootstrap-cluster.sh ACME).
#
# It deliberately STOPS BEFORE the live `vmm-cli deploy`. Deploying the CVM, editing the KMS
# auth-config, editing vmm.toml, and running bootstrap-cluster.sh are LIVE MUTATIONS left for the
# operator (see the printed sequence). This script does NOT reimplement deploy-to-vmm.sh's deploy
# logic; it reuses deploy-to-vmm.sh's compose-generation steps (the non-mutating half) so the
# app-id it prints is exactly what the real deploy will use, then hands you the deploy command.
#
# Run as the user that owns the vmm + can read /home/outlayer/gateway-cf-token (outlayer), e.g.:
#   sudo -u outlayer -H ./40-deploy-gateway.sh
#
# Prereqs: dstack-vmm running; per-node KMS deployed; build/images/dstack-0.5.11 present; the
# gateway container image BUILT and PUSHED to a registry the CVM can pull (see GATEWAY_IMAGE note
# below); gateway/gateway.env filled (copy from gateway/gateway.env.template).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NODE_USER="${NODE_USER:-outlayer}"
DSTACK="${DSTACK:-/home/$NODE_USER/meta-dstack/dstack}"
GW_APP_DIR="${GW_APP_DIR:-$DSTACK/gateway/dstack-app}"   # upstream deploy-to-vmm.sh lives here
VMM_CLI="${VMM_CLI:-$DSTACK/vmm/src/vmm-cli.py}"
KMSDIR="${KMSDIR:-/home/$NODE_USER/outlayer-kms}"        # auth-config.json lives here
CF_TOKEN_FILE="${CF_TOKEN_FILE:-/home/$NODE_USER/gateway-cf-token}"
ENVFILE="${ENVFILE:-$HERE/gateway/gateway.env}"
[ -f "$ENVFILE" ] || ENVFILE="$HERE/$ENVFILE"

# APP_NAME  = the CVM's VM LABEL (lsvm). COMPOSE_NAME = the name baked into the MEASURED app-compose
# (drives the compose hash). Keep COMPOSE_NAME STABLE so measurements are reusable / approved once.
APP_NAME="${APP_NAME:-dstack-gateway}"
COMPOSE_NAME="${COMPOSE_NAME:-$APP_NAME}"
# Resources affect RTMR0/RTMR1 — keep CONSTANT once chosen. Upstream gateway used 32/32G; that is
# heavy for a single keystore terminator. Default to a modest, fixed size; override via env if you
# must, but then re-approve measurements.
VCPU="${VCPU:-4}"
MEMORY="${MEMORY:-4G}"
DISK="${DISK:-10G}"

[ -f "$ENVFILE" ] || { echo "Missing $ENVFILE (cp from gateway/gateway.env.template + fill)"; exit 1; }
[ -f "$CF_TOKEN_FILE" ] || { echo "Missing $CF_TOKEN_FILE (scoped Cloudflare DNS-01 token, chmod 600)"; exit 1; }
[ -x "$VMM_CLI" ] || [ -f "$VMM_CLI" ] || { echo "vmm-cli not found at $VMM_CLI"; exit 1; }

echo "[env] reading gateway deploy config from: $ENVFILE  (on $(hostname))"
set -a
# shellcheck disable=SC1090
source "$ENVFILE"
set +a

# CF token: read from the node file at RUNTIME, never from the committed env, never echoed.
CF_API_TOKEN="$(cat "$CF_TOKEN_FILE")"
export CF_API_TOKEN
[ -n "$CF_API_TOKEN" ] || { echo "CF token file $CF_TOKEN_FILE is empty"; exit 1; }

# ---- Re-assert the security mitigations regardless of what the env file said (defense in depth) ----
# C3: admin RPC must be loopback-only on BOTH the host port map AND the in-CVM bind.
NET_MODE=user
GATEWAY_ADMIN_RPC_ADDR=127.0.0.1:9203
ADMIN_LISTEN_ADDR=127.0.0.1
ADMIN_LISTEN_PORT=8001
GUEST_AGENT_ADDR=127.0.0.1:9206
# WAN-facing.
GATEWAY_RPC_ADDR=0.0.0.0:9202
WG_ADDR=0.0.0.0:9202
GATEWAY_SERVING_PORT=443
GATEWAY_SERVING_NUM_PORTS=1
export NET_MODE GATEWAY_ADMIN_RPC_ADDR ADMIN_LISTEN_ADDR ADMIN_LISTEN_PORT GUEST_AGENT_ADDR \
       GATEWAY_RPC_ADDR WG_ADDR GATEWAY_SERVING_PORT GATEWAY_SERVING_NUM_PORTS

# C1: never run the stale upstream defaults.
: "${OS_IMAGE:?set OS_IMAGE in gateway.env (must be dstack-0.5.11)}"
: "${GATEWAY_IMAGE:?set GATEWAY_IMAGE in gateway.env (locally-built 0.5.11 digest, registry-pullable)}"
[ "$OS_IMAGE" = "dstack-0.5.11" ] || echo "WARN: OS_IMAGE=$OS_IMAGE (expected dstack-0.5.11)"
case "$GATEWAY_IMAGE" in
  *@sha256:*) : ;;  # digest-pinned, good
  *) echo "ERROR: GATEWAY_IMAGE must be digest-pinned (repo@sha256:...). Got: $GATEWAY_IMAGE"; exit 1 ;;
esac
: "${VMM_RPC:?set VMM_RPC}" "${SRV_DOMAIN:?set SRV_DOMAIN}" "${PUBLIC_IP:?set PUBLIC_IP}" \
  "${KMS_URL:?set KMS_URL}" "${NODE_ID:?set NODE_ID}" "${MY_URL:?set MY_URL}"

KMS_HOST="$(printf '%s' "$KMS_URL" | sed -E 's#^https?://([^:/]+).*#\1#')"

echo "=== Mitigations in effect (security review C2/C3/H2/M3) ==="
echo "  NET_MODE=user (bridge would skip the --port loopback gate)"
echo "  admin RPC: host 127.0.0.1:9203 + in-CVM ADMIN_LISTEN_ADDR=127.0.0.1 (loopback only)"
echo "  guest-agent: host 127.0.0.1:9206 (loopback)"
echo "  WAN: RPC/WG 0.0.0.0:9202, TLS serving 443; --public-sysinfo DROPPED"
echo "  OS_IMAGE=$OS_IMAGE  GATEWAY_IMAGE=$GATEWAY_IMAGE"
echo "  CF token: read from $CF_TOKEN_FILE (value never printed)"
echo

# ---------------------------------------------------------------------------------------------------
# Build the gateway app-compose (NON-mutating) and compute app-id, mirroring deploy-to-vmm.sh.
# We replicate ONLY its compose-generation half here so we can print the exact app-id; the deploy
# half stays as printed live commands. WORKDIR = the upstream dstack-app dir (relative paths).
# ---------------------------------------------------------------------------------------------------
WG_PORT="$(echo "$WG_ADDR" | cut -d':' -f2)"
RPC_DOMAIN="${RPC_DOMAIN:-gateway.$SRV_DOMAIN}"
SUBNET_INDEX="${SUBNET_INDEX:-0}"
WG_THIRD_OCTET=$((SUBNET_INDEX * 64))
WG_IP="10.8.${WG_THIRD_OCTET}.1/16"
WG_RESERVED_NET="10.8.${WG_THIRD_OCTET}.1/32"
WG_CLIENT_RANGE="10.8.${WG_THIRD_OCTET}.0/18"
if [ "${GATEWAY_SERVING_NUM_PORTS:-1}" -gt 1 ]; then
  PROXY_LISTEN_PORT="443-$((443 + GATEWAY_SERVING_NUM_PORTS - 1))"
else
  PROXY_LISTEN_PORT=443
fi
# A pipeline whose reader closes early (head/cut) SIGPIPEs its producer; under `set -o pipefail`
# that aborts the script. Generate without any early-closed pipe: hex from openssl, sliced in-shell.
APP_LAUNCH_TOKEN="$(openssl rand -hex 16)"
APP_LAUNCH_TOKEN="${APP_LAUNCH_TOKEN:0:32}"
EXPECTED_TOKEN_HASH="$(printf '%s' "$APP_LAUNCH_TOKEN" | sha256sum | cut -d' ' -f1)"

RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/outlayer-gateway.XXXXXX")"
cleanup() { rm -rf "$RENDER_DIR"; }
trap cleanup EXIT

# Render the upstream docker-compose.yaml with the pinned GATEWAY_IMAGE (never mutate the committed
# upstream file — that would dirty the node git tree and block `git pull`).
COMPOSE_RENDERED="$RENDER_DIR/docker-compose.yaml"
sed "s|\${GATEWAY_IMAGE}|$GATEWAY_IMAGE|g" "$GW_APP_DIR/docker-compose.yaml" > "$COMPOSE_RENDERED"

# The CVM's runtime env (.app_env) — same fields deploy-to-vmm.sh writes. Includes the loopback
# admin bind (ADMIN_LISTEN_ADDR) so the in-CVM admin RPC never listens on 0.0.0.0.
APP_ENV="$RENDER_DIR/.app_env"
cat > "$APP_ENV" <<APPENV
WG_ENDPOINT=$PUBLIC_IP:$WG_PORT
MY_URL=$MY_URL
BOOTNODE_URL=${BOOTNODE_URL:-}
WG_IP=$WG_IP
WG_RESERVED_NET=$WG_RESERVED_NET
WG_CLIENT_RANGE=$WG_CLIENT_RANGE
APP_LAUNCH_TOKEN=$APP_LAUNCH_TOKEN
RPC_DOMAIN=$RPC_DOMAIN
NODE_ID=$NODE_ID
PROXY_LISTEN_PORT=$PROXY_LISTEN_PORT
INBOUND_PP_ENABLED=${INBOUND_PP_ENABLED:-false}
ADMIN_LISTEN_ADDR=$ADMIN_LISTEN_ADDR
ADMIN_LISTEN_PORT=$ADMIN_LISTEN_PORT
APPENV

# Prelaunch token-hash gate (verbatim from deploy-to-vmm.sh).
PRELAUNCH="$RENDER_DIR/.prelaunch.sh"
cat > "$PRELAUNCH" <<'PRE'
EXPECTED_TOKEN_HASH=$(jq -j .launch_token_hash app-compose.json)
if [ "$EXPECTED_TOKEN_HASH" == "null" ]; then
    echo "Skipped APP_LAUNCH_TOKEN check"
else
  ACTUAL_TOKEN_HASH=$(echo -n "$APP_LAUNCH_TOKEN" | sha256sum | cut -d' ' -f1)
  if [ "$EXPECTED_TOKEN_HASH" != "$ACTUAL_TOKEN_HASH" ]; then
      echo "Error: Incorrect APP_LAUNCH_TOKEN, please make sure set the correct APP_LAUNCH_TOKEN in env"
      reboot
      exit 1
  else
      echo "APP_LAUNCH_TOKEN checked OK"
  fi
fi
PRE

# vmm-cli compose. NOTE: the gateway is NOT deployed WITH --gateway (it IS the gateway, not an app
# behind it). --public-sysinfo is DROPPED (mitigation). --public-logs kept (worker-ctl.sh logs).
APP_COMPOSE="$RENDER_DIR/.app-compose.json"
echo "[compose] building gateway app-compose (name=$COMPOSE_NAME; non-mutating)..."
python3 "$VMM_CLI" --url "$VMM_RPC" compose \
  --docker-compose "$COMPOSE_RENDERED" \
  --name "$COMPOSE_NAME" \
  --kms \
  --env-file "$APP_ENV" \
  --public-logs \
  --no-instance-id \
  --secure-time \
  --prelaunch-script "$PRELAUNCH" \
  --output "$APP_COMPOSE" > /dev/null

# Inject the launch_token_hash (deploy-to-vmm.sh does this after compose).
TMP_J="$RENDER_DIR/.app-compose.tmp.json"
jq --arg th "$EXPECTED_TOKEN_HASH" '.launch_token_hash = $th' "$APP_COMPOSE" > "$TMP_J"
mv "$TMP_J" "$APP_COMPOSE"

# Persist the rendered compose AND .app_env next to this script for the operator's deploy step
# (both gitignored). The .app_env carries the matching APP_LAUNCH_TOKEN — the prelaunch gate aborts
# the boot if the deployed env's token doesn't hash to the compose's launch_token_hash, so the
# operator MUST deploy with THIS .app_env (do not regenerate the token between compose and deploy).
OUT_COMPOSE="$HERE/gateway/app-compose.json"
OUT_APP_ENV="$HERE/gateway/.app_env"
mkdir -p "$HERE/gateway"
cp "$APP_COMPOSE" "$OUT_COMPOSE"
cp "$APP_ENV" "$OUT_APP_ENV"
chmod 600 "$OUT_APP_ENV"

# app-id = sha256(.app-compose.json)[:40]  (vmm-cli calc_app_id); compose hash = full sha256.
COMPOSE_HASH="$(sha256sum "$OUT_COMPOSE" | cut -d' ' -f1)"
APP_ID="$(printf '%s' "$COMPOSE_HASH" | cut -c1-40)"

echo
echo "==================================================================================="
echo " Gateway app-compose READY (no live state changed):"
echo "   compose file : $OUT_COMPOSE"
echo "   compose hash : 0x$COMPOSE_HASH"
echo "   APP ID       : $APP_ID"
echo "   APP_LAUNCH_TOKEN (needed at deploy): $APP_LAUNCH_TOKEN"
echo "==================================================================================="
echo
echo "NEXT — the following are LIVE MUTATIONS; run them in order as the operator:"
echo
echo "  # (L1) KMS allowlist — add the gateway app to auth-simple so it can boot + get its key."
echo "  #      Edit $KMSDIR/auth-config.json: add under .apps an entry keyed by the app-id with"
echo "  #      its allowed composeHash. Example with jq (review before running):"
echo "  jq '.apps[\"$APP_ID\"] = {\"composeHashes\": [\"$COMPOSE_HASH\"]}' \\"
echo "    $KMSDIR/auth-config.json > /tmp/auth-config.next.json && \\"
echo "    diff -u $KMSDIR/auth-config.json /tmp/auth-config.next.json"
echo "  #      (then move it into place + restart outlayer-kms-auth if/when you approve)"
echo "  #      NOTE: confirm the exact apps[] schema against your live auth-config.json /"
echo "  #      auth-simple index.ts before applying — the key may be 0x-prefixed and the field"
echo "  #      name may differ. Do NOT guess: match the existing worker/keystore entries."
echo
echo "  # (L2) Deploy the gateway CVM (LIVE). The CVM pulls GATEWAY_IMAGE from a registry at boot —"
echo "  #      make sure it is PUSHED + pullable first (see GATEWAY_IMAGE note in gateway.env.template)."
echo "  #      Run inside the upstream dir so vmm-cli relative paths resolve. The host-side env"
echo "  #      encryption must reach the KMS, so wrap with the /etc/hosts dance (same as keystore):"
echo "  sudo sed -i '/outlayer-tdx-deploy-kms/d' /etc/hosts"
echo "  echo \"127.0.0.1 $KMS_HOST # outlayer-tdx-deploy-kms\" | sudo tee -a /etc/hosts >/dev/null"
echo "  python3 $VMM_CLI --url $VMM_RPC deploy \\"
echo "    --name $APP_NAME \\"
echo "    --app-id $APP_ID \\"
echo "    --compose $OUT_COMPOSE \\"
echo "    --env-file $OUT_APP_ENV \\"
echo "    --kms-url $KMS_URL \\"
echo "    --image $OS_IMAGE \\"
echo "    --vcpu $VCPU --memory $MEMORY --disk $DISK \\"
echo "    --port tcp:$GATEWAY_RPC_ADDR:8000 \\"
echo "    --port tcp:$GATEWAY_ADMIN_RPC_ADDR:8001 \\"
echo "    --port tcp:$GUEST_AGENT_ADDR:8090 \\"
echo "    --port udp:$WG_ADDR:51820 \\"
echo "    --port tcp:0.0.0.0:$GATEWAY_SERVING_PORT:443"
echo "  sudo sed -i '/outlayer-tdx-deploy-kms/d' /etc/hosts   # remove BEFORE the guest's KMS DNS query"
echo "  #      then clean-DNS reboot the CVM (stop -f <vmid>; start <vmid>) so it resolves"
echo "  #      $KMS_HOST -> 10.0.2.2 (host) cleanly — see 40-deploy-keystore.sh for the exact dance."
echo "  #      .app_env (with the matching APP_LAUNCH_TOKEN) persisted at: $OUT_APP_ENV"
echo "  #      It is regenerated on EVERY run (new token) — deploy with the .app_env from the SAME run."
echo "  #      EASIER: just run the upstream wrapper with this env, which does compose+deploy in one:"
echo "  #        (cd $GW_APP_DIR && env CF_API_TOKEN=\"\$(cat $CF_TOKEN_FILE)\" \\"
echo "  #           NET_MODE=user GATEWAY_ADMIN_RPC_ADDR=127.0.0.1:9203 ADMIN_LISTEN_ADDR=127.0.0.1 \\"
echo "  #           GUEST_AGENT_ADDR=127.0.0.1:9206 ... ./deploy-to-vmm.sh)"
echo "  #      but it does NOT do the /etc/hosts KMS dance — wrap it the same way if you go that route."
echo
echo "  # (L3) vmm.toml — point the cluster at the gateway, then restart vmm (LIVE)."
echo "  #      Set gateway_urls in /home/$NODE_USER/meta-dstack/build/vmm.toml:"
echo "  #        gateway_urls = [\"$MY_URL\"]"
echo "  #      then restart the vmm service (operator's normal restart procedure)."
echo
echo "  # (L4) bootstrap ACME/DNS/ZT-Domain via the gateway admin RPC (LIVE; once per cluster)."
echo "  #      Run AFTER the gateway CVM is up and its admin RPC is reachable on 127.0.0.1:9203:"
echo "  (cd $GW_APP_DIR && env CF_API_TOKEN=\"\$(cat $CF_TOKEN_FILE)\" SRV_DOMAIN=$SRV_DOMAIN \\"
echo "     ACME_STAGING=${ACME_STAGING:-no} GATEWAY_ADMIN_RPC_ADDR=127.0.0.1:9203 \\"
echo "     bash bootstrap-cluster.sh 127.0.0.1:9203)"
echo
echo "  # (L5) Redeploy the KEYSTORE with --gateway + port_policy/public_tcbinfo (LIVE; separate step)."
echo "  #      vmm-cli compose has NO flag for port_policy/public_tcbinfo (H2) — inject by jq into the"
echo "  #      keystore .app-compose.json AFTER 40-deploy-keystore.sh's compose step, BEFORE deploy:"
echo "  #        jq '.gateway_enabled=true"
echo "  #            | .public_tcbinfo=true"
echo "  #            | .port_policy={restrict_mode:true, ports:[{port:8081}]}' \\"
echo "  #          keystore/app-compose.json > keystore/app-compose.gw.json"
echo "  #      (do NOT modify the keystore deploy now — this is a forward-pointer for that step)."
echo
echo "Done (preparation only). No CVM deployed, no KMS/vmm/auth-config changed."
