#!/usr/bin/env bash
# Deploy the OutLayer worker as a dstack CVM (KMS mode, encrypted env).
# Usage: ./40-deploy-worker.sh <version> [vmm-url]
#   <version>  : OutLayer release tag, e.g. v0.1.35 (resolves the verifiable digest)
#   vmm-url    : dstack-vmm RPC (default from VMM_URL or http://127.0.0.1:11000)
#
# Prereqs: dstack-vmm running (Step 3), per-node KMS deployed + worker app allowlisted
# in auth-simple (Step 4), worker/worker.env filled (secrets), guest image present.
set -euo pipefail

VERSION="${1:?usage: 40-deploy-worker.sh <version> [vmm-url]}"
VMM_URL="${2:-${VMM_URL:-http://127.0.0.1:11000}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="$HERE/worker/docker-compose.yaml"
# ENVFILE: per-network secrets file (gitignored). Override for testnet/mainnet, e.g.
#   ENVFILE=worker/.env.mainnet-worker-tdx ./40-deploy-worker.sh v0.1.35
# Resolved as given (cwd/absolute) if it exists, else relative to this script's dir.
ENVFILE="${ENVFILE:-$HERE/worker/worker.env}"
[ -f "$ENVFILE" ] || ENVFILE="$HERE/$ENVFILE"
VMM_CLI="${VMM_CLI:-/opt/mpc/dstack/vmm/src/vmm-cli.py}"   # adjust to your dstack path
IMAGE_OS="${IMAGE_OS:-dstack-0.5.8}"
# APP_NAME = CVM name (NOT a worker.env var). Encode net+version+index, e.g.
#   APP_NAME=outlayer-worker-mainnet-0.1.35-1   (worker-ctl.sh targets this name)
APP_NAME="${APP_NAME:-outlayer-worker}"

[ -f "$ENVFILE" ] || { echo "Missing $ENVFILE (cp worker/worker.env.template worker.env + fill secrets)"; exit 1; }

echo "[1/3] Resolve verifiable worker digest for $VERSION (from GitHub release, Sigstore-attested)..."
DIGEST=$(gh release view "$VERSION" --repo fastnear/near-outlayer --json body -q '.body' 2>/dev/null \
  | grep -iE '\| *worker *\|' | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
[ -n "$DIGEST" ] || { echo "Could not find worker digest for $VERSION"; exit 1; }
echo "  worker digest: $DIGEST"
echo "  verify: gh attestation verify oci://docker.io/outlayer/near-outlayer-worker@$DIGEST -R fastnear/near-outlayer"
sed -i.bak "s|image: docker.io/outlayer/near-outlayer-worker@sha256:.*|image: docker.io/outlayer/near-outlayer-worker@$DIGEST|" "$COMPOSE"

echo "[2/3] Build app-compose (KMS mode, env encrypted — NOT baked into measured compose)..."
python3 "$VMM_CLI" --url "$VMM_URL" compose \
  --name "$APP_NAME" \
  --docker-compose "$COMPOSE" \
  --kms \
  --public-logs --no-instance-id \
  --env-file "$ENVFILE" \
  --output "$HERE/worker/app-compose.json"

echo "[3/3] Deploy worker CVM (outbound-only; one host port for the dstack agent/logs)..."
python3 "$VMM_CLI" --url "$VMM_URL" deploy \
  --name "$APP_NAME" \
  --compose "$HERE/worker/app-compose.json" \
  --image "$IMAGE_OS" \
  --env-file "$ENVFILE" \
  --vcpu 2 --memory 4G --disk 60G \
  --port "tcp:127.0.0.1:9210:8090"

echo "Done. Worker will boot, get a TDX quote via /var/run/dstack.sock, and attempt"
echo "registration. First boot fails (measurements not approved) — read the worker's"
echo "5 measurements from its logs, then owner-approve on the register-contract (Step 6)."
echo "Logs: curl -sN 'http://127.0.0.1:9210/logs/worker?text=true&bare=true&follow=true&tail=100'"
