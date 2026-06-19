#!/usr/bin/env bash
# Build dstack (vmm/kms/gateway/guest-agent) + download the guest OS image.
# Run as the node's unprivileged user (e.g. `outlayer`), NOT root.
# Usage: ./10-build-dstack.sh [version]   (default 0.5.8 — match the on-chain OS measurements you target)
set -euo pipefail

VER="${1:-0.5.8}"
ROOT="${DSTACK_ROOT:-$HOME/dstack-node}"        # where this node's dstack lives
mkdir -p "$ROOT"; cd "$ROOT"

echo "[1/4] Clone meta-dstack v$VER (with submodules)..."
[ -d meta-dstack ] || git clone -b "v$VER" --recursive https://github.com/Dstack-TEE/meta-dstack.git
cd meta-dstack && mkdir -p build && cd build

echo "[2/4] Generate build config..."
../build.sh hostcfg
# Dev TLS / no certbot for an internal-only node (set CERTBOT_ENABLED=false). For a
# public gateway (ZT-HTTPS), set the domains + CF_API_TOKEN in build-config.sh instead.
sed -i 's|^GATEWAY_PUBLIC_DOMAIN=.*|GATEWAY_PUBLIC_DOMAIN=apps.1022.dstack.org|' build-config.sh || true
../build.sh hostcfg

echo "[3/4] Download prebuilt guest OS image v$VER..."
../build.sh dl "$VER"

echo "[4/4] Build host components (vmm/kms/gateway/...). Needs Rust + Node (00-host-setup)."
../build.sh host

echo "Done. Binaries in $ROOT/meta-dstack/build/rust-target/release/, image in build/images/dstack-$VER."
echo "Next: ./20-start-vmm.sh"
