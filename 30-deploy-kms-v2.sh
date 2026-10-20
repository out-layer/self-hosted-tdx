#!/usr/bin/env bash
# Deploy KMS v2: a second per-node dstack KMS, on dstack-0.5.12, with a FRESH root key, beside
# the running KMS v1 — and never touching anything of v1.
#
# Why a second KMS and not a new image under the first: the KMS CVM's own key comes from the
# local key-provider and is bound to its measurements, so the first KMS cannot change image
# without losing its sealed root key; and the first root is not carried forward on purpose (the
# 0.5.11 guest-agent exposed container files, among them the KMS root key, to every CVM for
# months and to every host uid). Every CVM is then redeployed against v2
# (scripts/deploy_tdx.sh --kms-url) and v1 is stopped once nothing boots from it any more.
#
# What v2 owns, all derived from KMS_NAME so nothing of v1 (kms, :11001, :11005, :3001,
# auth-config.json, kms-admin-token.txt, outlayer-kms-auth.service, dstack-app/.env.simple)
# is ever written:
#   CVM            kms-v2                         (lsvm Name; exact match everywhere)
#   RPC            127.0.0.1:11102 -> CVM:8000    (the URL in CVMs: https://$KMS_DOMAIN:11102)
#   guest-agent    127.0.0.1:11009 -> CVM:8090
#   boot webhook   outlayer-kms-auth-v2.service on 127.0.0.1:3002, $KMSDIR/auth-config-v2.json
#   admin token    $KMSDIR/kms-v2-admin-token.txt
#   app files      $KMSDIR/kms-v2/ (rendered compose, .app-compose.json)
#   domain         kms-v2.<site>.dstack.outlayer.ai, an A record 10.0.2.2 in OUR zone (the CVM's
#                  own host): the name the RPC certificate is issued for, so CVM boots no longer
#                  depend on dstack's *.1022.dstack.org
#   image download http://10.0.2.2:11008/{OS_IMAGE_HASH}.tar.gz — the KMS fetches the image it is
#                  asked to authorize by hash, so a new OS image needs no imgsrv renaming
# Deployed with --public-logs (worker-ctl.sh logs) but WITHOUT --public-sysinfo.
#
# Ports: 3002 must already be in 47-cvm-guard.sh LO_ALLOW_TCP (the KMS CVM asks its webhook at
# boot) and both 3002 and 11102 in 46-lo-guard.sh CONTROL_PORTS; 11102 is opened to CVMs in
# cvm-guard only AFTER this script finished — the onboarding RPC is unauthenticated until Finish.
#
# Idempotent and resumable: an existing kms-v2 CVM is kept and the run resumes at the allowlist,
# bootstrap and verify steps. Run as root. NON-MUTATING by default.
#   sudo ./30-deploy-kms-v2.sh            # preflight + the plan
#   sudo ./30-deploy-kms-v2.sh --apply
set -euo pipefail
NODE_USER="${NODE_USER:-outlayer}"
DSTACK="${DSTACK:-/home/$NODE_USER/meta-dstack/dstack}"
BUILD="${BUILD:-/home/$NODE_USER/meta-dstack/build}"
KMSDIR="${KMSDIR:-/home/$NODE_USER/outlayer-kms}"
VMM_RPC="${VMM_RPC:-http://127.0.0.1:11000}"
OS_IMAGE="${OS_IMAGE:-dstack-0.5.12}"
# The same KMS container v1 runs: 0.5.12 changed nothing under kms/, and this digest is what v1
# was deployed from (30-deploy-kms.sh). Pinned by digest.
KMS_IMAGE="${KMS_IMAGE:-dstacktee/dstack-kms@sha256:84b793feed825a5b5e70d04386e931e0e110461492793f17ab2128e39808d989}"
KMS_NAME="${KMS_NAME:-kms-v2}"
KMS_PORT="${KMS_PORT:-11102}"
GUEST_AGENT_PORT="${GUEST_AGENT_PORT:-11009}"
AUTH_PORT="${AUTH_PORT:-3002}"
IMGSRV_PORT="${IMGSRV_PORT:-11008}"
# dal → dal-01, ams → ams-01 (the gateway site names); KMS_DOMAIN overrides.
SITE="$(hostname -s | sed -E 's/^node-tdx-([a-z]+)-[0-9]+$/\1-01/')"
KMS_DOMAIN="${KMS_DOMAIN:-$KMS_NAME.$SITE.dstack.outlayer.ai}"
V1_AUTH_CONFIG="${V1_AUTH_CONFIG:-$KMSDIR/auth-config.json}"
V1_KMS_PORT="${V1_KMS_PORT:-11001}"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

# Everything v2 writes, derived from its name.
SUFFIX="${KMS_NAME#kms}"                       # "-v2"
AUTH_CONFIG="$KMSDIR/auth-config$SUFFIX.json"
AUTH_SERVICE="outlayer-kms-auth$SUFFIX.service"
TOKEN_FILE="$KMSDIR/kms$SUFFIX-admin-token.txt"
APPDIR="$KMSDIR/$KMS_NAME"
VMM_CLI="$DSTACK/vmm/src/vmm-cli.py"
UPSTREAM_APP="$DSTACK/kms/dstack-app"
BUN="/home/$NODE_USER/.bun/bin/bun"
AS="$DSTACK/kms/auth-simple"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
case "$KMS_NAME" in kms|"") echo "KMS_NAME must name a second KMS (kms-v2, kms-v3 …), never 'kms' (v1)" >&2; exit 1 ;; esac
[[ "$KMS_NAME" =~ ^kms-v[0-9]+$ ]] || { echo "KMS_NAME must look like kms-v2" >&2; exit 1; }
# By construction none of these is v1's; the check is here so a future edit cannot make it so.
for pair in "$AUTH_CONFIG:$KMSDIR/auth-config.json" "$TOKEN_FILE:$KMSDIR/kms-admin-token.txt" "$AUTH_SERVICE:outlayer-kms-auth.service" "$APPDIR:$UPSTREAM_APP"; do
  [ "${pair%%:*}" != "${pair#*:}" ] || { echo "refusing: '${pair%%:*}' is KMS v1's" >&2; exit 1; }
done
[ "$KMS_PORT" != "$V1_KMS_PORT" ] || { echo "refusing: KMS_PORT $KMS_PORT is v1's" >&2; exit 1; }
as_user() { sudo -u "$NODE_USER" -H "$@"; }
vmm() { as_user python3 "$VMM_CLI" --url "$VMM_RPC" "$@"; }
# the uuid of the CVM named exactly $KMS_NAME (the Name column), or empty
kms_uuid() {
  vmm lsvm 2>/dev/null | sed 's/│/|/g' | awk -F'|' -v want="$KMS_NAME" '
    { name=$4; uuid=$2; gsub(/[[:space:]]/,"",name); gsub(/[[:space:]]/,"",uuid)
      if (name==want && uuid ~ /^[0-9a-f-]{36}$/) print uuid }' | head -1
}

echo "=== KMS $KMS_NAME on $(hostname -s): preflight ==="
fail=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1" >&2; fail=1; fi; }
chk "bun at $BUN"                                  "[ -x '$BUN' ]"
chk "auth-simple patched (allowAnyApp, kms/apply-auth-simple.sh)" "grep -q allowAnyApp '$AS/index.ts'"
chk "image $OS_IMAGE with digest.txt"             "[ -s '$BUILD/images/$OS_IMAGE/digest.txt' ]"
OS_HASH="$(cat "$BUILD/images/$OS_IMAGE/digest.txt" 2>/dev/null | tr -d '[:space:]' || true)"
chk "imgsrv serves $OS_HASH.tar.gz (15-add-os-image.sh)" "curl -s -o /dev/null -I --max-time 5 'http://127.0.0.1:$IMGSRV_PORT/${OS_HASH:-none}.tar.gz' -w '%{http_code}' | grep -q 200"
chk "v1 auth config with a device allowlist"      "python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get(\"devices\") and c.get(\"kms\",{}).get(\"devices\") else 1)' '$V1_AUTH_CONFIG'"
if curl -sk -o /dev/null --max-time 8 -X POST "https://127.0.0.1:$V1_KMS_PORT/prpc/GetMeta?json" -H 'Content-Type: application/json' --data '{}'; then echo "  ok   KMS v1 serves https on :$V1_KMS_PORT (its root is compared with v2's at the end)"; else echo "  note KMS v1 is not serving on :$V1_KMS_PORT (stopped or removed): v2 is the only KMS of this node"; fi
chk "$KMS_DOMAIN resolves to 10.0.2.2 here"       "[ \"\$(dig +short '$KMS_DOMAIN' 2>/dev/null | tail -1)\" = 10.0.2.2 ]"
chk "3002/11102/11009 free or ours"               "! ss -ltnH | awk '{print \$4}' | grep -qE ':($AUTH_PORT|$KMS_PORT|$GUEST_AGENT_PORT)\$' || systemctl -q is-active '$AUTH_SERVICE' || [ -n \"\$(kms_uuid)\" ]"
chk "cvm-guard allows $AUTH_PORT for CVMs"        "iptables -S cvm-guard 2>/dev/null | grep -qE -- '--dports [0-9,]*\\b$AUTH_PORT\\b'"
chk "lo-guard covers $AUTH_PORT and $KMS_PORT"    "iptables -S ufw-before-output 2>/dev/null | grep -qE -- '--dports [0-9,:]*\\b$AUTH_PORT\\b[0-9,:]*\\b$KMS_PORT\\b.*-j lo-guard'"
EXISTING="$(kms_uuid || true)"
[ -z "$EXISTING" ] && echo "  no CVM named $KMS_NAME yet: a full deploy" || echo "  CVM $KMS_NAME exists ($EXISTING): resuming at allowlist/bootstrap/verify"
[ "$fail" -eq 0 ] || { echo "preflight failed" >&2; exit 1; }
echo
echo "plan: CVM $KMS_NAME on $OS_IMAGE, RPC 127.0.0.1:$KMS_PORT, agent 127.0.0.1:$GUEST_AGENT_PORT, webhook $AUTH_SERVICE :$AUTH_PORT"
echo "      config $AUTH_CONFIG (devices from v1, osImages=[$OS_HASH]), token $TOKEN_FILE, domain $KMS_DOMAIN"
echo "      image download http://10.0.2.2:$IMGSRV_PORT/{OS_IMAGE_HASH}.tar.gz, container $KMS_IMAGE"
[ "$APPLY" -eq 1 ] || { echo; echo "DRY-RUN: nothing changed. Re-run with --apply."; exit 0; }

echo "=== [1/6] boot webhook: $AUTH_CONFIG + $AUTH_SERVICE (:$AUTH_PORT) ==="
as_user mkdir -p "$KMSDIR" "$APPDIR"
if [ ! -s "$AUTH_CONFIG" ]; then
  as_user python3 - "$V1_AUTH_CONFIG" "$AUTH_CONFIG" "0x$OS_HASH" <<'PY'
import json, os, sys
v1, out, os_hash = sys.argv[1:4]
c1 = json.load(open(v1))
c = {
  "_comment": "KMS v2 boot allowlist (30-deploy-kms-v2.sh). devices/kms.devices copied from v1 (same hosts); osImages = the 0.5.12 image; kms.mrAggregated filled once the v2 CVM runs; gatewayAppId set by 40-deploy-gateway.sh (AUTH_CONFIG) when the gateway moves to v2.",
  "osImages": [os_hash],
  "kms": {"mrAggregated": [], "allowAnyDevice": False, "devices": list(c1["kms"]["devices"])},
  "apps": {},
  "allowAnyApp": True,
  "devices": list(c1["devices"]),
  "gatewayAppId": "",
}
with open(out + ".next", "w") as f: json.dump(c, f, indent=2)
os.replace(out + ".next", out)
print("  written: devices=%d kms.devices=%d osImages=%s" % (len(c["devices"]), len(c["kms"]["devices"]), c["osImages"]))
PY
else
  echo "  keeping existing $AUTH_CONFIG"
fi
cat > "/etc/systemd/system/$AUTH_SERVICE" <<UNIT
[Unit]
Description=OutLayer KMS $KMS_NAME auth-simple webhook (boot authorization)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$AS
Environment=PORT=$AUTH_PORT
Environment=HOST=127.0.0.1
Environment=AUTH_CONFIG_PATH=$AUTH_CONFIG
ExecStart=$BUN run index.ts
Restart=on-failure
RestartSec=5
User=$NODE_USER
Group=$NODE_USER
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "$AUTH_SERVICE"
sleep 2
curl -s "http://127.0.0.1:$AUTH_PORT/" -o /dev/null -w "  auth-simple $KMS_NAME GET /: %{http_code}\n"

echo "=== [2/6] admin token + rendered compose ==="
[ -f "$TOKEN_FILE" ] || { openssl rand -hex 16 > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; chown "$NODE_USER:$NODE_USER" "$TOKEN_FILE"; }
ADMIN_TOKEN_HASH="$(tr -d '\n' < "$TOKEN_FILE" | sha256sum | cut -d' ' -f1)"
grep -q 'network_mode: host' "$UPSTREAM_APP/compose-simple.yaml" || { echo "compose-simple.yaml is not the host-network variant v1 runs (30-deploy-kms.sh step 5)" >&2; exit 1; }
COMPOSE="$APPDIR/docker-compose.yaml"
as_user python3 - "$UPSTREAM_APP/compose-simple.yaml" "$COMPOSE" \
  "http://10.0.2.2:$AUTH_PORT" "http://10.0.2.2:$IMGSRV_PORT/{OS_IMAGE_HASH}.tar.gz" "$ADMIN_TOKEN_HASH" "true" "$KMS_IMAGE" <<'PY'
import sys
src, dst, webhook, dl, token_hash, verify, image = sys.argv[1:8]
s = open(src).read()
# VERIFY_IMAGE is optional: the host-network variant of compose-simple.yaml v1 runs has
# `verify = true` written out instead of the placeholder.
for var, val, required in (("AUTH_WEBHOOK_URL", webhook, True), ("IMAGE_DOWNLOAD_URL", dl, True),
                           ("ADMIN_TOKEN_HASH", token_hash, True), ("VERIFY_IMAGE", verify, False),
                           ("KMS_IMAGE", image, True)):
    needle = "${%s}" % var
    if needle not in s:
        assert not required, "compose-simple.yaml: %s not found" % needle
        continue
    s = s.replace(needle, val)
assert 'verify = true' in s, "compose-simple.yaml: image verification is not on"
assert "${" not in s, "compose-simple.yaml: an unsubstituted ${…} remains"
open(dst, "w").write(s)
print("  rendered", dst)
PY
chmod 600 "$COMPOSE"

echo "=== [3/6] CVM $KMS_NAME ==="
if [ -n "$EXISTING" ]; then
  echo "  exists ($EXISTING): not redeployed"
else
  as_user python3 "$VMM_CLI" --url "$VMM_RPC" compose \
    --docker-compose "$COMPOSE" \
    --name "$KMS_NAME" \
    --local-key-provider \
    --public-logs \
    --secure-time \
    --no-instance-id \
    --output "$APPDIR/.app-compose.json" > /dev/null
  as_user python3 "$VMM_CLI" --url "$VMM_RPC" deploy \
    --name "$KMS_NAME" \
    --compose "$APPDIR/.app-compose.json" \
    --image "$OS_IMAGE" \
    --port "tcp:127.0.0.1:$KMS_PORT:8000" \
    --port "tcp:127.0.0.1:$GUEST_AGENT_PORT:8090" \
    --vcpu 8 --memory 8G --disk 50G
  EXISTING="$(kms_uuid || true)"
  [ -n "$EXISTING" ] || { echo "deploy returned but no CVM named $KMS_NAME is listed" >&2; exit 1; }
  echo "  deployed: $EXISTING"
fi

echo "=== [4/6] allowlist $KMS_NAME's own mr_aggregated (gates its bootstrap) + devices ==="
echo "  waiting for the guest agent on :$GUEST_AGENT_PORT ..."
MR_AGG=""
for i in $(seq 1 40); do
  MR_AGG=$(curl -s --max-time 5 "http://127.0.0.1:$GUEST_AGENT_PORT/prpc/Info?json" \
    | python3 -c 'import sys,json
try: print(json.loads(json.load(sys.stdin)["tcb_info"])["mr_aggregated"])
except Exception: pass' 2>/dev/null || true)
  [ -n "$MR_AGG" ] && break
  sleep 6
done
[ -n "$MR_AGG" ] || { echo "no mr_aggregated from the $KMS_NAME guest agent after ~4 min: NAME=$KMS_NAME ./worker-ctl.sh serial" >&2; exit 1; }
echo "  mr_aggregated: $MR_AGG"
as_user python3 - "$AUTH_CONFIG" "0x$MR_AGG" <<'PY'
import json, os, sys
p, mr = sys.argv[1], sys.argv[2]
c = json.load(open(p)); lst = c.setdefault("kms", {}).setdefault("mrAggregated", [])
norm = lambda h: h.lower().removeprefix("0x")
if norm(mr) not in [norm(x) for x in lst]:
    lst.append(mr)
    with open(p + ".next", "w") as f: json.dump(c, f, indent=2)
    os.replace(p + ".next", p); print("  added to kms.mrAggregated")
else:
    print("  already allowlisted")
PY
# kms.devices / devices for v2, through the same validated path v1 used (shape check, idempotent
# index.ts patch, service restart). The device id is v1's (same host), so nothing is derived.
V1_DEVICES="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["kms"]["devices"]))' "$V1_AUTH_CONFIG")"
as_user env AUTH_CONFIG="$AUTH_CONFIG" AUTH_SERVICE="$AUTH_SERVICE" KMS_DEVICES="$V1_DEVICES" SYSTEMCTL="true" \
  "$HERE/kms/apply-auth-simple.sh"
systemctl restart "$AUTH_SERVICE"; sleep 2
systemctl -q is-active "$AUTH_SERVICE" || { echo "$AUTH_SERVICE not active: journalctl -u $AUTH_SERVICE" >&2; exit 1; }

echo "=== [5/6] bootstrap $KMS_NAME: a fresh root, domain $KMS_DOMAIN ==="
echo "  waiting for the onboard server (http on :$KMS_PORT) ..."
for i in $(seq 1 30); do
  curl -s "http://127.0.0.1:$KMS_PORT/" -o /dev/null --max-time 4 2>/dev/null && break || sleep 6
done
if curl -sk -o /dev/null --max-time 8 -X POST "https://127.0.0.1:$KMS_PORT/prpc/GetMeta?json" -H "Content-Type: application/json" --data '{}'; then
  echo "  already serves https — not re-bootstrapped (that would re-key a KMS that may have issued app keys)"
else
  BOOT_RESP="$(curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Bootstrap?json" \
    -H "Content-Type: application/json" --data "{\"domain\":\"$KMS_DOMAIN\"}" --max-time 60 || true)"
  echo "  Bootstrap: ${BOOT_RESP:0:200}"
  printf '%s' "$BOOT_RESP" | grep -q '"ca_pubkey"\|"ca_cert"\|"k256_pubkey"' || { echo "bootstrap did not answer with keys" >&2; exit 1; }
  FINISH_RESP="$(curl -s -X POST "http://127.0.0.1:$KMS_PORT/prpc/Onboard.Finish?json" \
    -H "Content-Type: application/json" --data '{}' --max-time 30 || true)"
  echo "  Finish: ${FINISH_RESP:0:120}"
  sleep 7
fi

echo "=== [6/6] verify ==="
meta() { curl -sk -X POST "https://127.0.0.1:$1/prpc/GetMeta?json" -H "Content-Type: application/json" --data '{}' --max-time 10; }
V2_META="$(meta "$KMS_PORT" || true)"; V1_META="$(meta "$V1_KMS_PORT" || true)"
[ -n "$V2_META" ] || { echo "$KMS_NAME does not serve https on :$KMS_PORT" >&2; exit 1; }
python3 - "$V2_META" "$V1_META" <<'PY'
import hashlib, json, sys
v2, v1 = json.loads(sys.argv[1]), (json.loads(sys.argv[2]) if sys.argv[2] else {})
fp = lambda m: hashlib.sha256((m.get("ca_cert") or "").encode()).hexdigest()[:16]
print("  v2 root CA fingerprint:", fp(v2), "| v1:", fp(v1) if v1 else "n/a")
assert v2.get("ca_cert"), "v2 GetMeta has no ca_cert"
if v1 and fp(v1) == fp(v2):
    raise SystemExit("  !! v2 has the SAME root CA as v1 — that is not a fresh root; stop")
print("  fresh root: yes (differs from v1)")
PY
SAN="$(echo | openssl s_client -connect "127.0.0.1:$KMS_PORT" -servername "$KMS_DOMAIN" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -oE 'DNS:[^, ]+' | tr '\n' ' ')"
echo "  RPC cert SAN: ${SAN:-<none>}"
printf '%s' "$SAN" | grep -q "DNS:$KMS_DOMAIN" || { echo "  !! the RPC certificate is not for $KMS_DOMAIN" >&2; exit 1; }
echo "Done. $KMS_NAME serves https://$KMS_DOMAIN:$KMS_PORT (inside CVMs) with a fresh root."
echo "Next: allow :$KMS_PORT for CVMs — add it to LO_ALLOW_TCP in 47-cvm-guard.sh and re-apply (reject),"
echo "      then deploy a testnet worker with --kms-url https://$KMS_DOMAIN:$KMS_PORT (scripts/deploy_tdx.sh)."
