#!/usr/bin/env bash
# Tests for apply-auth-simple.sh: the patch mechanics (bash/python) and the patched auth-simple's
# behaviour (apply-auth-simple.test.ts via `bun test`). Needs an upstream dstack auth-simple source
# tree and bun; touches only temp copies, never the live index.ts or config.
#
#   AUTH_SIMPLE_SRC=<dstack>/kms/auth-simple ./test-apply-auth-simple.sh
#
# Default AUTH_SIMPLE_SRC is the node's meta-dstack checkout. Its working-tree index.ts is PATCHED
# once step 4b has run, so the stock file is taken from git (`git show HEAD:index.ts`), falling back
# to the backups the apply script leaves; a stock file is required and verified (no `allowAnyApp`).
# On a dev machine point AUTH_SIMPLE_SRC at a clone of the dstack tag the nodes run
# (deploy/self-hosted-tdx/gateway/gateway.env.template: 0.5.11).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/apply-auth-simple.sh"
SRC="${AUTH_SIMPLE_SRC:-/home/outlayer/meta-dstack/dstack/kms/auth-simple}"
BUN="${BUN:-$(command -v bun || true)}"
[ -n "$BUN" ] || for c in "$HOME/.bun/bin/bun" /home/outlayer/.bun/bin/bun; do [ -x "$c" ] && BUN="$c" && break; done
[ -f "$SRC/index.ts" ] || { echo "AUTH_SIMPLE_SRC has no index.ts: $SRC" >&2; exit 1; }
[ -n "$BUN" ] && [ -x "$BUN" ] || { echo "bun not found (set BUN)" >&2; exit 1; }

DEV_OK=0xc84189f534d6d90747e068fe8090eafd870f5969176b42f9c43be3bb7e8162ce
DEV_2=0x4a252cf80d209d96bb06ce96e17342ea2234f721b4a158707718b18732d6e4a1
TMP="$(mktemp -d "${TMPDIR:-/tmp}/apply-auth-simple-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }
sum()  { cksum < "$1" | cut -d' ' -f1; }

# Stock (unpatched) upstream index.ts from a source dir whose working tree may already be patched.
# Prints the method used on stderr; writes the file to $2.
pristine_index() {  # $1 = source dir, $2 = output path
  local src="$1" out="$2" how=""
  if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && git -C "$src" show "HEAD:./index.ts" > "$out" 2>/dev/null && [ -s "$out" ]; then
    how="git HEAD"
  else
    for cand in "$src/index.ts.bak.pre-allowAnyApp" "$src/index.ts.bak.pre-deviceAllowlist" "$src/index.ts"; do
      [ -f "$cand" ] && ! grep -q "allowAnyApp" "$cand" && cp "$cand" "$out" && how="$cand" && break
    done
  fi
  [ -n "$how" ] && [ -s "$out" ] && ! grep -q "allowAnyApp" "$out" || {
    echo "no stock (unpatched) index.ts found under $src — need a git checkout or a pre-patch backup" >&2
    return 1
  }
  echo "$how"
}

STOCK="$TMP/index.stock.ts"
HOW="$(pristine_index "$SRC" "$STOCK")"
echo "stock index.ts: $HOW"

fresh_copy() {  # $1 = dir name; upstream tree with a STOCK index.ts and no leftovers
  rm -rf "$TMP/$1"; cp -r "$SRC" "$TMP/$1"
  cp "$STOCK" "$TMP/$1/index.ts"
  rm -f "$TMP/$1"/index.ts.bak.* "$TMP/$1/auth-config.json" "$TMP/$1/outlayer-test-auth-config.json" "$TMP/$1/auth-config.json.next"
  echo '{"osImages":["0xaa"],"kms":{"mrAggregated":["0xbb"],"allowAnyDevice":true},"apps":{},"allowAnyApp":true}' > "$TMP/$1/auth-config.json"
}
apply() {  # $1 = dir, rest = env assignments
  local dir="$1"; shift
  env AUTH_SIMPLE_INDEX="$TMP/$dir/index.ts" AUTH_CONFIG="$TMP/$dir/auth-config.json" \
      AUTH_SERVICE=test.service SYSTEMCTL=true NODE_DEVICE_ID_CMD=false "$@" bash "$SCRIPT"
}
# Reproduce the shape the earlier allowAnyApp-only patch left on the live nodes.
old_patch() {
  python3 - "$TMP/$1/index.ts" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a1="  gatewayAppId: z.string().default(''),\n"; s=s.replace(a1,a1+"  allowAnyApp: z.boolean().default(false),\n",1)
a2="    const composeHash = normalizeHex(bootInfo.composeHash);\n"
s=s.replace(a2,a2+"\n    if (config.allowAnyApp) {\n      return { isAllowed: true, reason: 'allowAnyApp (single-tenant; register-contract gates registration)', gatewayAppId: config.gatewayAppId };\n    }\n",1)
open(p,'w').write(s)
PY
}
cfg() { python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(json.dumps({'allowAnyApp':c.get('allowAnyApp'),'devices':c.get('devices'),'kmsAny':c['kms'].get('allowAnyDevice'),'kmsDev':c['kms'].get('devices')},sort_keys=True))" "$TMP/$1/auth-config.json"; }

echo "== 0. stock source resolution"
grep -q "allowAnyApp" "$STOCK" && bad "resolved stock index.ts is already patched" || ok "stock index.ts has no allowAnyApp ($HOW)"
# A node whose checkout is patched in the working tree must still yield the stock file via git.
rm -rf "$TMP/repo"; mkdir -p "$TMP/repo"; cp "$STOCK" "$TMP/repo/index.ts"
( cd "$TMP/repo" && git init -q && git -c user.email=t@t -c user.name=t add index.ts && git -c user.email=t@t -c user.name=t commit -qm stock )
old_patch repo; cp "$TMP/repo/index.ts" "$TMP/repo/index.ts.bak.pre-deviceAllowlist"   # both patched
if h="$(pristine_index "$TMP/repo" "$TMP/repo.stock")" && ! grep -q "allowAnyApp" "$TMP/repo.stock"; then ok "patched working tree -> stock via $h"; else bad "could not recover stock from a patched git checkout"; fi
# No git, only backups: the oldest backup is the stock one.
rm -rf "$TMP/nogit"; mkdir -p "$TMP/nogit"; cp "$TMP/repo/index.ts" "$TMP/nogit/index.ts"; cp "$STOCK" "$TMP/nogit/index.ts.bak.pre-allowAnyApp"; cp "$TMP/repo/index.ts" "$TMP/nogit/index.ts.bak.pre-deviceAllowlist"
if h="$(pristine_index "$TMP/nogit" "$TMP/nogit.stock")" && ! grep -q "allowAnyApp" "$TMP/nogit.stock"; then ok "no git -> stock via backup"; else bad "could not recover stock from backups"; fi
# Nothing stock anywhere: must refuse rather than test against a patched file.
rm -rf "$TMP/none"; mkdir -p "$TMP/none"; cp "$TMP/repo/index.ts" "$TMP/none/index.ts"
if pristine_index "$TMP/none" "$TMP/none.stock" >/dev/null 2>&1; then bad "accepted a tree with no stock index.ts"; else ok "refuses a tree with no stock index.ts"; fi

echo "== 1. KMS_DEVICES unset: derived on the node, or refused when that fails"
fresh_copy a
if apply a KMS_DEVICES= >/dev/null 2>&1; then bad "ran with no id and a failing derivation"; else ok "refused when derivation fails"; fi
[ "$(sum "$STOCK")" = "$(sum "$TMP/a/index.ts")" ] && ok "index.ts untouched" || bad "index.ts modified"
if apply a KMS_DEVICES= NODE_DEVICE_ID_CMD="echo" >/dev/null 2>&1; then bad "ran with an empty derived id"; else ok "refused when derivation prints nothing"; fi
out="$(apply a KMS_DEVICES= NODE_DEVICE_ID_CMD="echo $DEV_2" 2>&1)" && grep -q "device id derived on this node: $DEV_2" <<<"$out" \
  && [ "$(cfg a)" = '{"allowAnyApp": true, "devices": ["'$DEV_2'"], "kmsAny": false, "kmsDev": ["'$DEV_2'"]}' ] \
  && ok "derived id used for the allowlist" || bad "derived id not used: $out"
out="$(apply a KMS_DEVICES="$DEV_OK" NODE_DEVICE_ID_CMD="echo $DEV_2" 2>&1)" && [ "$(cfg a)" = '{"allowAnyApp": true, "devices": ["'$DEV_OK'"], "kmsAny": false, "kmsDev": ["'$DEV_OK'"]}' ] \
  && ok "explicit KMS_DEVICES wins over derivation" || bad "explicit KMS_DEVICES ignored"

# Every refusal below must leave BOTH files untouched and no auth-config.json.next behind: a patched
# index.ts next to an unpatched config would deny every boot at the next service restart.
untouched() {  # $1 = dir, $2 = label
  [ "$(sum "$STOCK")" = "$(sum "$TMP/$1/index.ts")" ] && ok "$2: index.ts untouched" || bad "$2: index.ts modified"
  [ "$(sum "$TMP/$1/auth-config.json")" = "$3" ] && ok "$2: config untouched" || bad "$2: config modified"
  [ ! -e "$TMP/$1/auth-config.json.next" ] && ok "$2: no .next left behind" || bad "$2: auth-config.json.next left behind"
}
echo "== 2. refuses bad inputs before touching anything"
fresh_copy a; c0="$(sum "$TMP/a/auth-config.json")"
if apply a KMS_DEVICES=0x1234 >/dev/null 2>&1; then bad "accepted short id"; else ok "short id refused"; fi; untouched a "short id" "$c0"
if apply a KMS_DEVICES="$DEV_OK,$DEV_OK" >/dev/null 2>&1; then bad "accepted duplicate ids"; else ok "duplicate ids refused"; fi; untouched a "duplicates" "$c0"
if apply a KMS_DEVICES="$DEV_OK,0xZZ" >/dev/null 2>&1; then bad "accepted a non-hex id in a list"; else ok "non-hex id in list refused"; fi; untouched a "non-hex" "$c0"
printf '{ not json' > "$TMP/a/auth-config.json"; c1="$(sum "$TMP/a/auth-config.json")"
if apply a KMS_DEVICES="$DEV_OK" >/dev/null 2>&1; then bad "accepted malformed JSON config"; else ok "malformed JSON refused"; fi; untouched a "malformed JSON" "$c1"
echo '{"osImages":["0xaa"],"kms":{"mrAggregated":["0xbb"]},"apps":{"_comment":"oops"}}' > "$TMP/a/auth-config.json"; c2="$(sum "$TMP/a/auth-config.json")"
if out="$(apply a KMS_DEVICES="$DEV_OK" 2>&1)"; then bad "accepted a string inside apps"; else grep -q "apps\['_comment'\]" <<<"$out" && ok "string inside apps refused, named" || bad "string inside apps refused without naming it: $out"; fi; untouched a "apps string" "$c2"
echo '{"osImages":[],"kms":{"mrAggregated":["0xbb"]},"apps":{}}' > "$TMP/a/auth-config.json"; c3="$(sum "$TMP/a/auth-config.json")"
if apply a KMS_DEVICES="$DEV_OK" >/dev/null 2>&1; then bad "accepted empty osImages"; else ok "empty osImages refused"; fi; untouched a "empty osImages" "$c3"
echo '{"osImages":["0xaa"],"kms":{"mrAggregated":[]},"apps":{}}' > "$TMP/a/auth-config.json"; c4="$(sum "$TMP/a/auth-config.json")"
if apply a KMS_DEVICES="$DEV_OK" >/dev/null 2>&1; then bad "accepted empty kms.mrAggregated"; else ok "empty kms.mrAggregated refused"; fi; untouched a "empty mrAggregated" "$c4"
echo "== 2b. patch abort (unknown early-allow shape) leaves the config untouched too"
fresh_copy c2; old_patch c2; sed -i.orig "s/reason: 'allowAnyApp (single-tenant; register-contract gates registration)'/reason: 'x', extra: 1/" "$TMP/c2/index.ts"; rm -f "$TMP/c2/index.ts.orig"
c5="$(sum "$TMP/c2/auth-config.json")"; i5="$(sum "$TMP/c2/index.ts")"
if apply c2 KMS_DEVICES="$DEV_OK" >/dev/null 2>&1; then bad "did not abort"; else ok "aborted"; fi
[ "$(sum "$TMP/c2/index.ts")" = "$i5" ] && ok "index.ts untouched" || bad "index.ts modified"
[ "$(sum "$TMP/c2/auth-config.json")" = "$c5" ] && ok "config untouched" || bad "config modified"
[ ! -e "$TMP/c2/auth-config.json.next" ] && ok "no .next left behind" || bad ".next left behind"

echo "== 3. stock upstream: patch + config"
fresh_copy a
apply a KMS_DEVICES="$DEV_OK,$DEV_2" >/dev/null
[ -f "$TMP/a/index.ts.bak.pre-deviceAllowlist" ] && ok "backup written" || bad "no backup"
grep -q "deviceAllowlist" "$TMP/a/index.ts" && ok "device check present" || bad "device check missing"
grep -q "deviceId: bootInfo.deviceId" "$TMP/a/index.ts" && ok "deviceId logging present" || bad "deviceId logging missing"
[ "$(grep -c 'if (config.allowAnyApp)' "$TMP/a/index.ts")" = 1 ] && ok "exactly one allowAnyApp allow" || bad "allowAnyApp allow count != 1"
expect='{"allowAnyApp": true, "devices": ["'$DEV_OK'", "'$DEV_2'"], "kmsAny": false, "kmsDev": ["'$DEV_OK'", "'$DEV_2'"]}'
[ "$(cfg a)" = "$expect" ] && ok "config written" || bad "config: $(cfg a)"
python3 -c "import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c['osImages']==['0xaa'] and c['kms']['mrAggregated']==['0xbb'] else 1)" "$TMP/a/auth-config.json" && ok "untouched fields preserved" || bad "untouched fields lost"
[ ! -e "$TMP/a/auth-config.json.next" ] && ok "no .next left behind" || bad ".next left behind"

echo "== 4. idempotent re-run"
before="$(sum "$TMP/a/index.ts")"; out="$(apply a KMS_DEVICES="$DEV_OK,$DEV_2")"
[ "$(sum "$TMP/a/index.ts")" = "$before" ] && ok "index.ts unchanged" || bad "index.ts changed"
grep -q "already patched" <<<"$out" && grep -q "config already up to date" <<<"$out" && ok "reports nothing to do" || bad "unexpected output: $out"

echo "== 5. live-node shape (old allowAnyApp patch present)"
fresh_copy b; old_patch b
apply b KMS_DEVICES="$DEV_OK" >/dev/null
[ "$(grep -c 'if (config.allowAnyApp)' "$TMP/b/index.ts")" = 1 ] && ok "old allow replaced, not duplicated" || bad "duplicate allowAnyApp allow"
grep -q "deviceAllowlist" "$TMP/b/index.ts" && ok "device check present" || bad "device check missing"
[ "$(cfg b)" = '{"allowAnyApp": true, "devices": ["'$DEV_OK'"], "kmsAny": false, "kmsDev": ["'$DEV_OK'"]}' ] && ok "allowAnyDevice flipped to false" || bad "config: $(cfg b)"
# Same code either way; only the schema comment differs (the old patch carried its own wording).
code() { grep -v '^[[:space:]]*//' "$1" | cksum | cut -d' ' -f1; }
[ "$(code "$TMP/a/index.ts")" = "$(code "$TMP/b/index.ts")" ] && ok "same code as patching stock directly (comments aside)" || bad "old-patch path diverges from stock path"

echo "== 5b. hand-applied multi-line early allow (the dal-2 shape)"
fresh_copy b2
python3 - "$TMP/b2/index.ts" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a1="  gatewayAppId: z.string().default(''),\n"
s=s.replace(a1,a1+"  // OutLayer customization: when true, ANY app (passing the TCB + osImages checks) is allowed\n  allowAnyApp: z.boolean().default(false),\n",1)
a2="    const composeHash = normalizeHex(bootInfo.composeHash);\n"
s=s.replace(a2,a2+"\n    // OutLayer: single-tenant node — allow any app (TCB + osImages already checked above).\n    // Each app still gets its own per-appId key; on-chain registration is the real gate.\n    if (config.allowAnyApp) {\n      return {\n        isAllowed: true,\n        reason: 'allowAnyApp (single-tenant node; register-contract gates worker registration)',\n        gatewayAppId: config.gatewayAppId\n      };\n    }\n",1)
s=s.replace("  fetch: app.fetch,\n","  hostname: process.env.HOST || \"127.0.0.1\",\n  fetch: app.fetch,\n",1)
open(p,'w').write(s)
PY
apply b2 KMS_DEVICES="$DEV_OK" >/dev/null
[ "$(grep -c 'if (config.allowAnyApp)' "$TMP/b2/index.ts")" = 1 ] && ok "multi-line allow replaced, not duplicated" || bad "duplicate/missing allowAnyApp allow"
grep -q "single-tenant node — allow any app" "$TMP/b2/index.ts" && bad "old comment block left behind" || ok "old comment block removed with the allow"
grep -q "deviceAllowlist" "$TMP/b2/index.ts" && ok "device check present" || bad "device check missing"
grep -q "hostname: process.env.HOST" "$TMP/b2/index.ts" && ok "unrelated local edits kept" || bad "unrelated local edits lost"
python3 - "$TMP/a/index.ts" "$TMP/b2/index.ts" <<'PY' && ok "same code as the stock path (comments and the hostname line aside)" || bad "dal shape diverges from stock path"
import sys,re
def code(p): return [l for l in open(p).read().splitlines() if not l.strip().startswith("//") and "hostname: process.env.HOST" not in l]
sys.exit(0 if code(sys.argv[1]) == code(sys.argv[2]) else 1)
PY

echo "== 6. unknown early-allow shape aborts and leaves index.ts untouched"
fresh_copy c
python3 - "$TMP/c/index.ts" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
a1="  gatewayAppId: z.string().default(''),\n"; s=s.replace(a1,a1+"  allowAnyApp: z.boolean().default(false),\n",1)
a2="    const composeHash = normalizeHex(bootInfo.composeHash);\n"
s=s.replace(a2,a2+"    if (config.allowAnyApp) { return { isAllowed: true, reason: 'x', gatewayAppId: '' }; }\n",1)
open(p,'w').write(s)
PY
cp "$TMP/c/index.ts" "$TMP/c/index.before"
if apply c KMS_DEVICES="$DEV_OK" >/dev/null 2>&1; then bad "did not abort"; else ok "aborted"; fi
[ "$(sum "$TMP/c/index.before")" = "$(sum "$TMP/c/index.ts")" ] && ok "index.ts untouched" || bad "index.ts modified"

echo "== 6b. node-device-id.py extracts sha256(PPID) from the PCK certificate inside a quote"
if python3 -c "import cryptography" 2>/dev/null; then
  python3 - "$TMP" <<'PY'
import sys, os, hashlib, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
tmp = sys.argv[1]
ppid = bytes(range(16))
# SGX extensions sequence: SEQ { SEQ { OID 1.2.840.113741.1.13.1.1, OCTET STRING ppid } }
inner = bytes.fromhex("060a2a864886f84d010d0101") + b"\x04\x10" + ppid
seq1 = b"\x30" + bytes([len(inner)]) + inner
sgx = b"\x30" + bytes([len(seq1)]) + seq1
key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Intel SGX PCK Certificate (test)")])
now = datetime.datetime(2026, 1, 1)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(1).not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier("1.2.840.113741.1.13.1"), sgx), critical=False)
        .sign(key, hashes.SHA256()))
from cryptography.hazmat.primitives import serialization
pem = cert.public_bytes(serialization.Encoding.PEM)
quote = b"\x04\x00\x02\x00\x81\x00\x00\x00" + os.urandom(600) + pem + b"\x00"   # header + junk + chain
open(os.path.join(tmp, "fake-quote.hex"), "w").write(quote.hex())
open(os.path.join(tmp, "fake-quote.expected"), "w").write("0x" + hashlib.sha256(ppid).hexdigest())
PY
  got="$(python3 "$HERE/node-device-id.py" --quote-hex "$TMP/fake-quote.hex" 2>&1)"
  [ "$got" = "$(cat "$TMP/fake-quote.expected")" ] && ok "sha256(PPID) from a synthetic PCK certificate" || bad "node-device-id.py: $got"
  printf '0400020081000000deadbeef' > "$TMP/no-chain.hex"
  if python3 "$HERE/node-device-id.py" --quote-hex "$TMP/no-chain.hex" >/dev/null 2>&1; then bad "accepted a quote without a certificate chain"; else ok "refuses a quote without a certificate chain"; fi
else
  echo "  SKIP node-device-id.py test: python 'cryptography' module not installed here (00-host-setup.sh installs it on nodes)"
fi

echo "== 7. behaviour of the patched server (bun test)"
cp "$HERE/apply-auth-simple.test.ts" "$TMP/a/"
( cd "$TMP/a" && "$BUN" install --silent >/dev/null 2>&1 && "$BUN" test apply-auth-simple.test.ts 2>&1 | tail -4 ) | tee "$TMP/bun.out"
grep -qE "^ *0 fail" "$TMP/bun.out" && ok "bun test: 0 fail" || bad "bun test reported failures"

echo "== 8. stock upstream suite on the stock file (baseline sanity)"
fresh_copy d; ( cd "$TMP/d" && "$BUN" install --silent >/dev/null 2>&1 && "$BUN" test 2>&1 | tail -3 ) | grep -qE "^ *0 fail" && ok "upstream suite green on stock index.ts" || bad "upstream suite red on stock index.ts — wrong AUTH_SIMPLE_SRC?"

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }
