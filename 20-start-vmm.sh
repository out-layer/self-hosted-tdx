#!/usr/bin/env bash
# Install vmm.toml + start this node's dstack-vmm as a systemd service.
# Run as root (writes the unit); the service runs as $NODE_USER.
# Usage: sudo NODE_USER=outlayer DSTACK_ROOT=/home/outlayer/dstack-node ./20-start-vmm.sh
set -euo pipefail

NODE_USER="${NODE_USER:-outlayer}"
DSTACK_ROOT="${DSTACK_ROOT:-/home/$NODE_USER/dstack-node}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DSTACK_ROOT/meta-dstack/build"
VMMDATA="$BUILD"   # vmm runs from the build dir (has rust-target, images, run)

[ -x "$BUILD/rust-target/release/dstack-vmm" ] || { echo "Build dstack first (10-build-dstack.sh)"; exit 1; }

echo "[1/3] Install vmm.toml (separate ports/CID, isolated from other vmms)..."
install -m 644 -o "$NODE_USER" -g "$NODE_USER" "$HERE/vmm.toml.template" "$VMMDATA/vmm.toml"
# place binaries where the vmm expects them (alongside vmm.toml + images + run)
for b in dstack-vmm supervisor; do
  cp -f "$BUILD/rust-target/release/$b" "$VMMDATA/$b"
done
chown -R "$NODE_USER:$NODE_USER" "$VMMDATA"

echo "[2/3] systemd unit..."
cat > /etc/systemd/system/outlayer-dstack-vmm.service <<UNIT
[Unit]
Description=OutLayer dstack-vmm (self-hosted TDX node)
After=network-online.target docker.service
[Service]
Type=simple
WorkingDirectory=$VMMDATA
ExecStart=$VMMDATA/dstack-vmm -c vmm.toml
Restart=on-failure
RestartSec=5
User=$NODE_USER
Group=$NODE_USER
[Install]
WantedBy=multi-user.target
UNIT
# dstack-vmm v0.5.x registers an instance-discovery dir under /run/user/<uid>.
# A systemd *system* service with User= has no login session, so /run/user/<uid>
# doesn't exist and the vmm dies on start:
#   "failed to create directory `/run/user/<uid>/dstack-vmm`: Permission denied".
# Enable lingering so systemd creates and owns /run/user/<uid> for $NODE_USER.
# (VERIFIED on the live node: the vmm only stayed up after this.)
loginctl enable-linger "$NODE_USER"

systemctl daemon-reload
systemctl enable --now outlayer-dstack-vmm

echo "[3/3] Status:"
sleep 3
systemctl is-active outlayer-dstack-vmm
ss -ltnp 2>/dev/null | grep ':11000' && echo "vmm up on :11000" || echo "check: journalctl -u outlayer-dstack-vmm"
echo "Next: ./30-deploy-kms.sh"
