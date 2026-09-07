#!/usr/bin/env bash
# Apply OutLayer's KMS auth-simple customization FROM GIT (no hand-editing, no secrets in git):
#   0) validate every input first: KMS_DEVICES format, auth-config.json parses, and the config AS IT
#      WILL BE WRITTEN has the shape auth-simple's schema accepts (a shape error makes auth-simple
#      fall back to an empty config and deny every boot while the service still reports active),
#   1) patch index.ts: `allowAnyApp` and a top-level `devices` allowlist in the config schema; in
#      checkAppBoot a device check that runs BEFORE the allowAnyApp early allow; `deviceId` added
#      to both boot-auth request log lines (stock auth-simple logs it nowhere),
#   2) install auth-config.json: allowAnyApp=true, devices, kms.allowAnyDevice=false, kms.devices,
#   3) restart the auth-simple service.
# Nothing is modified until step 0 passes, so a typo cannot leave a patched index.ts next to an
# unpatched config. Idempotent + re-runnable (skips anything already applied). Run on the node
# (uses sudo for the service restart). See kms/README.md for the fields and the security rationale.
#
#   KMS_DEVICES=0x<sha256(ppid)>[,0x<sha256(ppid)>...] ./apply-auth-simple.sh
#
# KMS_DEVICES is REQUIRED and must be non-empty: the device allowlist is what keeps the KMS from
# releasing app keys (and therefore our `key-provider` RTMR3 event) to our image booted on foreign
# hardware, even if the KMS port is ever exposed. deviceId = sha256(PPID) taken by the KMS from the
# DCAP-verified quote; see kms/README.md "Device allowlist".
#
# There is ONE mode and it is strict. A wrong id in `devices` denies the next CVM boot; a wrong id in
# `kms.devices` fails every KMS key request at once (the KMS re-asks auth-simple per request). Both
# are visible in the auth log with the real deviceId and recoverable by editing the config (re-read
# per request; a denied CVM reboot-loops until allowed). After applying, restart a NON-critical CVM
# and confirm `isAllowed: true` on both the KMS and the app boot-auth lines.
set -euo pipefail
INDEX="${AUTH_SIMPLE_INDEX:-/home/outlayer/meta-dstack/dstack/kms/auth-simple/index.ts}"
CONFIG="${AUTH_CONFIG:-/home/outlayer/outlayer-kms/auth-config.json}"
SERVICE="${AUTH_SERVICE:-outlayer-kms-auth.service}"
SYSTEMCTL="${SYSTEMCTL:-sudo systemctl}"     # tests override with a no-op
KMS_DEVICES="${KMS_DEVICES:-}"
NEXT="$CONFIG.next"

[ -f "$INDEX" ]  || { echo "auth-simple index.ts not found: $INDEX (set AUTH_SIMPLE_INDEX)" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "auth-config.json not found: $CONFIG (set AUTH_CONFIG)" >&2; exit 1; }
[ -n "$KMS_DEVICES" ] || {
  echo "KMS_DEVICES is empty. Refusing: an empty device allowlist would let any TDX machine that" >&2
  echo "reaches this KMS boot our apps with our key-provider. Pass KMS_DEVICES=0x<sha256(ppid)>,..." >&2
  exit 1
}

# --- 0) validate inputs and build the next config (written to $NEXT, installed in step 2) --------
rm -f "$NEXT"
python3 - "$CONFIG" "$KMS_DEVICES" "$NEXT" <<'PY' || { rm -f "$NEXT"; exit 1; }
import sys, json, re, copy
cfg_path, devs_raw, out_path = sys.argv[1:4]

def die(*msgs):
    for m in msgs: print("refusing:", m, file=sys.stderr)
    sys.exit(1)

devs = [d.strip().lower() for d in devs_raw.split(",") if d.strip()]
bad = [d for d in devs if not re.fullmatch(r"0x[0-9a-f]{64}", d)]
if not devs: die("KMS_DEVICES has no device id")
if bad: die("device id must be 0x + 64 hex chars (sha256(ppid)): " + ", ".join(bad))
if len(set(devs)) != len(devs): die("KMS_DEVICES has duplicates")

try:
    orig = json.load(open(cfg_path))
except Exception as e:
    die("%s is not valid JSON: %s" % (cfg_path, e))
if not isinstance(orig, dict): die("%s: top level must be an object" % cfg_path)

c = copy.deepcopy(orig)
c["allowAnyApp"] = True
c["devices"] = devs
if not isinstance(c.get("kms", {}), dict): die("kms must be an object")
kms = c.setdefault("kms", {})
kms["allowAnyDevice"] = False
kms["devices"] = devs

# Shape check mirroring auth-simple's zod schema: any violation there is silently a DENY-ALL.
def str_list(x): return isinstance(x, list) and all(isinstance(i, str) for i in x)
errors = []
if not str_list(c.get("osImages")) or not c["osImages"]:
    errors.append("osImages must be a non-empty list of strings (empty = every boot denied 'OS image is not allowed')")
if not str_list(kms.get("mrAggregated")) or not kms["mrAggregated"]:
    errors.append("kms.mrAggregated must be a non-empty list (30-deploy-kms.sh step 6 fills it; run step 4 to completion first)")
apps = c.get("apps", {})
if not isinstance(apps, dict):
    errors.append("apps must be an object")
else:
    for k, v in apps.items():
        if not isinstance(v, dict):
            errors.append("apps[%r] must be an object, got %s — a stray value here makes auth-simple fall back to an empty config and deny every boot" % (k, type(v).__name__))
            continue
        for f in ("composeHashes", "devices"):
            if f in v and not str_list(v[f]): errors.append("apps[%r].%s must be a list of strings" % (k, f))
        if "allowAnyDevice" in v and not isinstance(v["allowAnyDevice"], bool): errors.append("apps[%r].allowAnyDevice must be a boolean" % k)
if "gatewayAppId" in c and not isinstance(c["gatewayAppId"], str):
    errors.append("gatewayAppId must be a string")
if errors: die(*errors)

try:
    with open(out_path, "w") as f:
        json.dump(c, f, indent=2)
except OSError as e:
    die("cannot write %s: %s" % (out_path, e))
print("plan: config %s" % ("unchanged" if c == orig else "will be updated (devices=%s) once index.ts is patched" % devs))
PY

# --- 1) index.ts ------------------------------------------------------------------------------
if grep -q "allowAnyApp" "$INDEX" && grep -q "deviceAllowlist" "$INDEX" && grep -q "deviceId: bootInfo.deviceId" "$INDEX"; then
  echo "index.ts already patched (allowAnyApp + deviceAllowlist + deviceId logging) — skipping"
else
  cp "$INDEX" "$INDEX.bak.pre-deviceAllowlist"
  python3 - "$INDEX" <<'PY' || { rm -f "$NEXT"; exit 1; }
import sys, re
p = sys.argv[1]; s = open(p).read()

# Schema: allowAnyApp (may already be there) + top-level devices.
a1 = "  gatewayAppId: z.string().default(''),\n"
assert a1 in s, "schema anchor (gatewayAppId default) not found — dstack version drift?"
if "allowAnyApp: z.boolean()" not in s:
    s = s.replace(a1, a1 +
        "  // OutLayer: allow any app to boot (TCB + osImages + the device allowlist below are still\n"
        "  // enforced; the KMS still derives a distinct per-appId key, so apps can't read each\n"
        "  // other's secrets; on-chain registration gates the worker/keystore itself).\n"
        "  allowAnyApp: z.boolean().default(false),\n", 1)
if "// OutLayer top-level device allowlist" not in s:
    s = s.replace("  allowAnyApp: z.boolean().default(false),\n",
        "  allowAnyApp: z.boolean().default(false),\n"
        "  // OutLayer top-level device allowlist (sha256(PPID) of OUR TDX hosts). Checked for every\n"
        "  // app boot, including the allowAnyApp path. Empty list = deny all app boots (fail-closed).\n"
        "  devices: z.array(z.string()).default([]),\n", 1)

# checkAppBoot: the device check goes where the old plain early allow was (or right after the
# composeHash line on a stock file). An early allow in an unknown shape stops the script: a second,
# unguarded allow left below the device check would silently bypass it.
old_allow = re.compile(
    r"\n    if \(config\.allowAnyApp\) \{\n"
    r"      return \{ isAllowed: true, reason: '[^']*', gatewayAppId: config\.gatewayAppId \};\n"
    r"    \}\n")
new_allow = (
    "\n    // OutLayer deviceAllowlist: hardware binding first, app identity second.\n"
    "    const allowedNodeDevices = config.devices.map(normalizeHex);\n"
    "    if (allowedNodeDevices.length === 0 || !allowedNodeDevices.includes(deviceId)) {\n"
    "      return { isAllowed: false, reason: 'device not in OutLayer node allowlist', gatewayAppId: config.gatewayAppId };\n"
    "    }\n"
    "    if (config.allowAnyApp) {\n"
    "      return { isAllowed: true, reason: 'allowAnyApp on an allowlisted device (single-tenant; on-chain registration gates the app)', gatewayAppId: config.gatewayAppId };\n"
    "    }\n")
if "deviceAllowlist" not in s:
    n_old = len(old_allow.findall(s))
    n_any = s.count("if (config.allowAnyApp)")
    assert n_old == n_any, "index.ts has an allowAnyApp early allow in an unknown shape — inspect it by hand, do not re-run"
    if n_old == 1:
        s = old_allow.sub(new_allow, s, count=1)
    else:
        a2 = "    const composeHash = normalizeHex(bootInfo.composeHash);\n"
        assert a2 in s, "checkAppBoot anchor (composeHash) not found — dstack version drift?"
        s = s.replace(a2, a2 + new_allow, 1)

# Log deviceId in both boot-auth request lines, so a denied boot tells the operator the real id.
if "deviceId: bootInfo.deviceId" not in s:
    app_log = "      console.log('app boot auth request:', {\n        appId: bootInfo.appId,\n"
    kms_log = "      console.log('KMS boot auth request:', {\n"
    assert app_log in s and kms_log in s, "boot-auth log anchors not found — dstack version drift?"
    s = s.replace(app_log, app_log + "        deviceId: bootInfo.deviceId,\n", 1)
    s = s.replace(kms_log, kms_log + "        deviceId: bootInfo.deviceId,\n", 1)
open(p, "w").write(s)
print("patched", p, "(backup: %s.bak.pre-deviceAllowlist)" % p)
PY
fi

# --- 2) install the validated config (cp keeps the file's owner/mode; the service reads it per request)
if cmp -s "$NEXT" "$CONFIG"; then
  echo "config already up to date"
else
  cp "$NEXT" "$CONFIG"
  echo "config updated: $CONFIG"
fi
rm -f "$NEXT"

$SYSTEMCTL restart "$SERVICE"
sleep 2
echo "service: $($SYSTEMCTL is-active "$SERVICE" || true)"
echo "NEXT: restart a NON-critical CVM and confirm in  journalctl -u $SERVICE -n 50  that both the KMS and the"
echo "      app boot-auth lines show a deviceId from KMS_DEVICES and isAllowed: true. A denial there prints"
echo "      the real deviceId: put it into KMS_DEVICES and re-run; the CVM boots on its next retry."
