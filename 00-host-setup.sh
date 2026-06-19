#!/usr/bin/env bash
# Host setup for a self-hosted TDX OutLayer worker node (Ubuntu 24.04).
# Idempotent-ish: safe to re-run. Run as root.
#
# Installs: build deps, docker, qemu-system-x86 (8.2.2 +tdx), Node.js, the
# canonical/tdx host kernel, and the SGX/TDX attestation stack (QGS + local PCCS).
#
# Scope: ONLY what the OutLayer worker's dstack/TDX host needs. No nearcore/NEAR-node
# tuning here (that belongs to a NEAR node, not the worker).
#
# After this script + reboot, verify: sudo dmesg | grep -i tdx  -> "module initialized"
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/3] Base packages (build deps, docker, qemu, node)..."
apt-get update -qq
apt-get install -y -qq \
  build-essential chrpath diffstat lz4 wireguard-tools xorriso \
  git curl jq sqlite3 \
  docker.io docker-compose-v2 \
  qemu-system-x86 qemu-utils \
  nodejs npm \
  python3-pip
# vmm-cli.py deps (used by dstack deploy). eth-hash[pycryptodome] is REQUIRED: vmm-cli
# verifies the KMS env-encrypt pubkey signature with keccak — without a keccak backend
# `deploy --env-file` dies with "None of these hashing backends are installed".
pip install --break-system-packages -q eth_keys eth_utils cryptography pyyaml requests "eth-hash[pycryptodome]" || true

echo "[2/3] canonical/tdx host kernel + attestation stack (QGS + local PCCS)..."
if [ ! -d /root/tdx ]; then
  git clone -b main https://github.com/canonical/tdx.git /root/tdx
fi
# Enable the DCAP/attestation components (QGS + PCCS), then run host setup.
sed -i 's/^TDX_SETUP_ATTESTATION=0/TDX_SETUP_ATTESTATION=1/' /root/tdx/setup-tdx-config
( cd /root/tdx && ./setup-tdx-host.sh )   # installs TDX kernel + DCAP; reboot afterwards

echo "[3/3] Done. Verify services + reboot:"
echo "  systemctl is-active qgsd pccs docker"
echo "  REBOOT, then: sudo dmesg | grep -i tdx   # expect 'virt/tdx: module initialized'"
echo "Next: set the Intel PCS API key in /opt/intel/sgx-dcap-pccs/config/default.json (.ApiKey),"
echo "      restart pccs, and push the platform manifest (see README Step 2)."
