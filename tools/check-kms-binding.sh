#!/usr/bin/env bash
# On a TDX node: is this node's KMS bound to this node's hardware? Exit 0 and one OK line when it
# is; exit 1 and the failed checks otherwise. Read-only, no secret printed. scripts/deploy_tdx.sh
# runs it before every deploy and refuses to go on when it fails.
#
# Why it matters. A worker's build is approved as its five registers; RTMR3 measures the KMS that
# gave the CVM its keys (the key-provider event). A CVM on another machine gets no keys from this
# KMS — its device is not in the allowlist — so it runs under another KMS, measures another RTMR3
# and is not an approved build: it cannot register. That holds only while the KMS refuses every
# device but this node's. These are the checks:
#   1. the boot webhook (outlayer-kms-auth-v2) runs;
#   2. its config allows exactly one device, the same for apps and for the KMS itself (the KMS runs
#      here, so that one device is this node), and kms.allowAnyDevice is false;
#   3. its code carries the OutLayer device check (auth-simple patched by kms/apply-auth-simple.sh);
#   4. it listens on loopback only;
#   5. the KMS asks it: the KMS CVM's config has auth_api type "webhook" at the host's port.
#
#   ./tools/check-kms-binding.sh
set -uo pipefail

SERVICE="${KMS_AUTH_SERVICE:-outlayer-kms-auth-v2.service}"
CONFIG="${KMS_AUTH_CONFIG:-/home/outlayer/outlayer-kms/auth-config-v2.json}"
KMS_COMPOSE="${KMS_COMPOSE:-/home/outlayer/outlayer-kms/kms-v2/docker-compose.yaml}"
PORT="${KMS_AUTH_PORT:-3002}"
fail=()

[ "$(systemctl is-active "$SERVICE" 2>/dev/null)" = active ] || fail+=("$SERVICE is not active")

if [ -r "$CONFIG" ]; then
  why=$(python3 -I - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
k = c.get("kms", {})
norm = lambda xs: sorted(x.lower().removeprefix("0x") for x in (xs or []))
apps, own = norm(c.get("devices")), norm(k.get("devices"))
out = []
if not apps:
    out.append("devices is empty")
if not own:
    out.append("kms.devices is empty")
if len(apps) > 1 or len(own) > 1:
    out.append(f"more than one device allowed (devices {len(apps)}, kms.devices {len(own)}): one node, one device")
elif apps and own and apps != own:
    out.append("devices differ from kms.devices: a device other than this node's is allowed")
if k.get("allowAnyDevice") is not False:
    out.append("kms.allowAnyDevice is not false")
print("; ".join(out))
PY
) || why="config does not parse"
  [ -z "$why" ] || fail+=("$CONFIG: $why")
else
  fail+=("$CONFIG is not readable")
fi

wd=$(systemctl show -p WorkingDirectory --value "$SERVICE" 2>/dev/null)
grep -qF "device not in OutLayer node allowlist" "$wd/index.ts" 2>/dev/null \
  || fail+=("${wd:-<no working directory>}/index.ts has no OutLayer device check")

listen=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":$PORT\$" || true)
[ -n "$listen" ] || fail+=("nothing listens on :$PORT")
printf '%s\n' "$listen" | grep -vE "^127\.0\.0\.1:$PORT\$" | grep -q . && fail+=("the webhook listens beyond loopback: $(printf '%s' "$listen" | tr '\n' ' ')")

# The KMS's own config (measured into the KMS CVM): auth_api is the webhook on this host's port.
if [ -r "$KMS_COMPOSE" ]; then
  why=$(python3 -I - "$KMS_COMPOSE" "$PORT" <<'PY'
import re, sys
text, port = open(sys.argv[1]).read(), sys.argv[2]
sec = re.search(r"\[core\.auth_api\](.*?)(?=\n\s*\[(?!core\.auth_api)|\Z)", text, re.S)
body = sec.group(1) if sec else ""
out = []
if not re.search(r'^\s*type\s*=\s*"webhook"\s*$', body, re.M):
    out.append('auth_api type is not "webhook"')
if not re.search(r'^\s*url\s*=\s*"http://10\.0\.2\.2:' + re.escape(port) + r'"\s*$', body, re.M):
    out.append(f"auth_api webhook url is not http://10.0.2.2:{port}")
print("; ".join(out))
PY
)
  [ -z "$why" ] || fail+=("$KMS_COMPOSE: $why")
else
  fail+=("$KMS_COMPOSE is not readable")
fi

if [ ${#fail[@]} -eq 0 ]; then
  echo "KMS binding OK: $SERVICE active, one device (the KMS's own), allowAnyDevice=false, device check present, loopback only, the KMS asks it"
  exit 0
fi
echo "KMS binding NOT OK on $(hostname):"
printf '  - %s\n' "${fail[@]}"
exit 1
