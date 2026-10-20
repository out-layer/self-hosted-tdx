#!/usr/bin/env bash
# Add a dstack guest OS image to this node: download the release tarball, check it against what
# GitHub says it published and what the release note says it measures, unpack it where the vmm
# looks, and allowlist its os_image_hash in the per-node KMS (auth-simple `osImages`), without
# which the KMS refuses keys to any CVM booted on it. Additive: nothing running is touched and no
# CVM changes image here (that is `worker-ctl.sh set-image`, driven by scripts/deploy_tdx.sh
# --os-image).
#
# Usage, as root on the node:
#   ./15-add-os-image.sh <version> <os_image_hash>
#   ./15-add-os-image.sh 0.5.12 8db40cb23008d6213668b5816702d100b37b859a8a5bfd18d938ae3a1b3715bd
# The hash is the `dstack-<version>` row of the "OS image hashes" table in the release note,
# https://github.com/Dstack-TEE/meta-dstack/releases/tag/v<version>. Copy it from there, not from
# the download: the point is that what landed here is what the release says it built. Two checks:
#   1. sha256 of the tarball = the digest GitHub records for that release asset (API field
#      `digest`); only warned about when the API returns none;
#   2. digest.txt inside the image = the hash you pass. It is the value the guest reports to the
#      KMS at boot, so a wrong one here would also mean every boot on this image is refused.
set -euo pipefail
VER="${1:?usage: $0 <version> <os_image_hash>}"
WANT="${2:?usage: $0 <version> <os_image_hash>}"
NODE_USER="${NODE_USER:-outlayer}"
META="${META_DSTACK:-/home/$NODE_USER/meta-dstack}"
IMAGES="$META/build/images"
AUTH_CONFIG="${AUTH_CONFIG:-/home/$NODE_USER/outlayer-kms/auth-config.json}"
AUTH_SERVICE="${AUTH_SERVICE:-outlayer-kms-auth.service}"
VMM_URL="${VMM_URL:-http://127.0.0.1:11000}"
VMM_CLI="$META/dstack/vmm/src/vmm-cli.py"
NAME="dstack-$VER"
URL="https://github.com/Dstack-TEE/meta-dstack/releases/download/v$VER/$NAME.tar.gz"
API="https://api.github.com/repos/Dstack-TEE/meta-dstack/releases/tags/v$VER"

WANT=$(printf '%s' "$WANT" | tr '[:upper:]' '[:lower:]' | sed 's/^0x//')
[[ "$WANT" =~ ^[0-9a-f]{64}$ ]] || { echo "os_image_hash must be 64 hex characters" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$IMAGES" ] || { echo "$IMAGES missing: build dstack first (10-build-dstack.sh)" >&2; exit 1; }
[ -f "$AUTH_CONFIG" ] || { echo "$AUTH_CONFIG missing: deploy the per-node KMS first (30-deploy-kms.sh)" >&2; exit 1; }

as_user() { sudo -u "$NODE_USER" -H "$@"; }

echo "[1/4] image $NAME"
if [ -d "$IMAGES/$NAME" ]; then
  echo "  already unpacked at $IMAGES/$NAME"
else
  tmp="$IMAGES/$NAME.tmp"; rm -rf "$tmp"; as_user mkdir -p "$tmp"
  echo "  downloading $URL"
  as_user curl -fsSL --retry 3 "$URL" -o "$tmp/$NAME.tar.gz"
  got=$(sha256sum "$tmp/$NAME.tar.gz" | cut -d' ' -f1)
  pub=$(curl -fsSL "$API" 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin).get("assets", []):
    if a["name"] == sys.argv[1]:
        print((a.get("digest") or "").removeprefix("sha256:"))
' "$NAME.tar.gz" 2>/dev/null || true)
  if [ -z "$pub" ]; then
    echo "  WARN: GitHub returned no digest for $NAME.tar.gz; only the in-image digest.txt is checked" >&2
  elif [ "$got" != "$pub" ]; then
    echo "  !! tarball sha256 $got, GitHub records $pub: not unpacking" >&2; rm -rf "$tmp"; exit 1
  else
    echo "  tarball sha256 = the GitHub asset digest"
  fi
  as_user tar -xzf "$tmp/$NAME.tar.gz" -C "$tmp"
  rm -f "$tmp/$NAME.tar.gz"
  # the release tarball may carry a top-level $NAME/ directory or the files directly
  if [ -d "$tmp/$NAME" ]; then as_user mv "$tmp/$NAME" "$IMAGES/$NAME"; rm -rf "$tmp"; else as_user mv "$tmp" "$IMAGES/$NAME"; fi
fi
[ -f "$IMAGES/$NAME/digest.txt" ] || { echo "  !! $IMAGES/$NAME has no digest.txt: not a dstack image" >&2; exit 1; }
have=$(tr -d '[:space:]' < "$IMAGES/$NAME/digest.txt" | tr '[:upper:]' '[:lower:]')
[ "$have" = "$WANT" ] || { echo "  !! digest.txt is $have, the release note says $WANT: not allowlisting. Remove $IMAGES/$NAME and look at the download" >&2; exit 1; }
echo "  os_image_hash $have = the release note"
as_user python3 "$VMM_CLI" --url "$VMM_URL" lsimage 2>/dev/null | grep -q "$NAME" \
  && echo "  the vmm lists $NAME" || { echo "  !! the vmm does not list $NAME (vmm-cli lsimage)" >&2; exit 1; }

echo "[2/4] KMS allowlist (osImages in $AUTH_CONFIG)"
# Written next to the file and renamed: auth-simple re-reads the config per request, and a
# half-written file reads as an empty config, which denies every boot.
changed=$(as_user python3 - "$AUTH_CONFIG" "0x$WANT" <<'PY'
import json, os, sys
p, h = sys.argv[1], sys.argv[2]
c = json.load(open(p))
lst = c.setdefault("osImages", [])
norm = lambda x: x.lower().removeprefix("0x")
if norm(h) in [norm(x) for x in lst]:
    print("present")
else:
    lst.append(h)
    with open(p + ".next", "w") as f:
        json.dump(c, f, indent=2)
    os.replace(p + ".next", p)
    print("added")
PY
)
if [ "$changed" = added ]; then
  systemctl restart "$AUTH_SERVICE"; sleep 1
  systemctl -q is-active "$AUTH_SERVICE" || { echo "  !! $AUTH_SERVICE is not active after the restart: journalctl -u $AUTH_SERVICE" >&2; exit 1; }
  echo "  added 0x$WANT; $AUTH_SERVICE restarted"
else
  echo "  already allowlisted"
fi

echo "[3/4] osImages now:"
python3 -c 'import json,sys; [print("  "+x) for x in json.load(open(sys.argv[1]))["osImages"]]' "$AUTH_CONFIG"

# The KMS verifies an image it has not cached by downloading IMAGE_DOWNLOAD_URL with
# {OS_IMAGE_HASH} substituted and checking sha256(sha256sum.txt) == the hash. Keep one
# <hash>.tar.gz per image in the image server's directory for that URL. A KMS whose URL names a
# fixed file (dstack-0.5.11.tar.gz) needs that name pointed at this tarball for the first boot
# on the new image — docs/cvm-operations.md, "Changing the guest OS image".
IMGSRV="${IMGSRV_DIR:-/home/$NODE_USER/outlayer-kms/imgsrv}"
echo "[4/4] KMS image server tarball"
if [ ! -d "$IMGSRV" ]; then
  echo "  no $IMGSRV on this node: skipped"
elif [ -f "$IMGSRV/$WANT.tar.gz" ]; then
  echo "  $IMGSRV/$WANT.tar.gz present"
else
  as_user tar -czf "$IMGSRV/$WANT.tar.gz.tmp" -C "$IMAGES/$NAME" . && as_user mv "$IMGSRV/$WANT.tar.gz.tmp" "$IMGSRV/$WANT.tar.gz"
  echo "  wrote $IMGSRV/$WANT.tar.gz ($(du -h "$IMGSRV/$WANT.tar.gz" | cut -f1))"
fi
echo "Next, from the Mac: scripts/deploy_tdx.sh <worker|keystore> <net> <cvm-name> --version <ver> --node root@<host> --os-image $NAME"
