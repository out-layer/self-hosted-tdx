#!/usr/bin/env bash
# Apply OutLayer's KMS auth-simple customization FROM GIT (no hand-editing, no secrets in git):
#   1) add `allowAnyApp` to the config schema + an early allow in checkAppBoot,
#   2) set allowAnyApp=true in auth-config.json,
#   3) restart the auth-simple service.
# Idempotent + re-runnable (skips anything already applied). Run on the node (uses sudo for the
# service restart). See kms/README.md for what allowAnyApp does and the security rationale.
#
#   ./apply-auth-simple.sh
set -euo pipefail
INDEX="${AUTH_SIMPLE_INDEX:-/home/outlayer/meta-dstack/dstack/kms/auth-simple/index.ts}"
CONFIG="${AUTH_CONFIG:-/home/outlayer/outlayer-kms/auth-config.json}"
SERVICE="${AUTH_SERVICE:-outlayer-kms-auth.service}"

[ -f "$INDEX" ]  || { echo "auth-simple index.ts not found: $INDEX (set AUTH_SIMPLE_INDEX)" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "auth-config.json not found: $CONFIG (set AUTH_CONFIG)" >&2; exit 1; }

if grep -q "allowAnyApp" "$INDEX"; then
  echo "index.ts already has allowAnyApp — skipping code patch"
else
  cp "$INDEX" "$INDEX.bak.pre-allowAnyApp"
  python3 - "$INDEX" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a1 = "  gatewayAppId: z.string().default(''),\n"
add1 = a1 + ("  // OutLayer: allow any app to boot (TCB + osImages still enforced; the KMS still derives a\n"
            "  // distinct per-appId key, so apps can't read each other's secrets; on-chain worker\n"
            "  // registration is gated by the register-contract). Avoids per-worker KMS re-allowlisting.\n"
            "  allowAnyApp: z.boolean().default(false),\n")
a2 = "    const composeHash = normalizeHex(bootInfo.composeHash);\n"
add2 = a2 + ("\n    if (config.allowAnyApp) {\n"
            "      return { isAllowed: true, reason: 'allowAnyApp (single-tenant; register-contract gates registration)', gatewayAppId: config.gatewayAppId };\n"
            "    }\n")
assert a1 in s, "schema anchor (gatewayAppId default) not found — dstack version drift?"
assert a2 in s, "checkAppBoot anchor (composeHash) not found — dstack version drift?"
s = s.replace(a1, add1, 1).replace(a2, add2, 1)
open(p, "w").write(s)
print("patched", p, "(backup: %s.bak.pre-allowAnyApp)" % p)
PY
fi

python3 - "$CONFIG" <<'PY'
import sys, json
p = sys.argv[1]; d = json.load(open(p))
if d.get("allowAnyApp") is True:
    print("config already allowAnyApp=true")
else:
    d["allowAnyApp"] = True
    json.dump(d, open(p, "w"), indent=2)
    print("set allowAnyApp=true in", p)
PY

sudo systemctl restart "$SERVICE"
sleep 2
echo "service: $(systemctl is-active "$SERVICE")"
echo "verify boot decisions:  journalctl -u $SERVICE -f"
