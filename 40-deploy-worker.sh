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
# APP_NAME  = the CVM's VM LABEL (shown in lsvm, targeted by worker-ctl.sh). Unique per instance.
# COMPOSE_NAME = the name baked into the MEASURED app-compose (drives the compose hash -> RTMR3 ->
#   measurements). Keep it STABLE per (network, version) so all instances of a version share the
#   same measurements and you approve them ONCE. Defaults to APP_NAME if unset (single-instance).
# Neither is a worker.env variable — both are deploy-time args.
APP_NAME="${APP_NAME:-outlayer-worker}"
COMPOSE_NAME="${COMPOSE_NAME:-$APP_NAME}"

[ -f "$ENVFILE" ] || { echo "Missing $ENVFILE (cp worker/worker.env.template worker.env + fill secrets)"; exit 1; }

echo "[1/3] Resolve verifiable worker digest for $VERSION..."
if [ -n "${WORKER_DIGEST:-}" ]; then
  # Operator-supplied, pre-verified digest. Use this on nodes WITHOUT gh (e.g. the TDX node):
  # resolve + attest the digest once on a trusted machine that has gh, then pass it here.
  case "$WORKER_DIGEST" in sha256:*) DIGEST="$WORKER_DIGEST" ;; *) DIGEST="sha256:$WORKER_DIGEST" ;; esac
  echo "  using WORKER_DIGEST override: $DIGEST"
elif command -v gh >/dev/null 2>&1; then
  # `|| true`: don't let set -e kill us inside the command substitution — the guard below
  # prints a useful message instead of dying silently.
  DIGEST=$(gh release view "$VERSION" --repo fastnear/near-outlayer --json body -q '.body' 2>/dev/null \
    | grep -iE '\| *worker *\|' | grep -oE 'sha256:[a-f0-9]{64}' | head -1) || true
  echo "  worker digest (GitHub release, Sigstore-attested): ${DIGEST:-<none found>}"
else
  echo "ERROR: gh is not installed and WORKER_DIGEST is not set." >&2
  echo "  On a machine WITH gh (e.g. your laptop), resolve + verify the digest:" >&2
  echo "    gh release view $VERSION --repo fastnear/near-outlayer --json body -q .body | grep -iE '\\| *worker *\\|'" >&2
  echo "    gh attestation verify oci://docker.io/outlayer/near-outlayer-worker@<digest> -R fastnear/near-outlayer" >&2
  echo "  then re-run here with:  WORKER_DIGEST=sha256:<digest> $0 $VERSION" >&2
  exit 1
fi
[ -n "$DIGEST" ] || { echo "Could not resolve worker digest for $VERSION — pass WORKER_DIGEST=sha256:..." >&2; exit 1; }
echo "  worker digest: $DIGEST"
echo "  verify (on a trusted machine): gh attestation verify oci://docker.io/outlayer/near-outlayer-worker@$DIGEST -R fastnear/near-outlayer"
sed -i.bak "s|image: docker.io/outlayer/near-outlayer-worker@sha256:.*|image: docker.io/outlayer/near-outlayer-worker@$DIGEST|" "$COMPOSE"

echo "[2/3] Build app-compose (measured name=$COMPOSE_NAME; KMS env NOT baked into it)..."
python3 "$VMM_CLI" --url "$VMM_URL" compose \
  --name "$COMPOSE_NAME" \
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
