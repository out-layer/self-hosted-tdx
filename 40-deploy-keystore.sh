#!/usr/bin/env bash
# Deploy the OutLayer keystore as a dstack CVM (KMS mode, encrypted env).
# Usage: ./40-deploy-keystore.sh <version> [vmm-url]
#   <version>  : OutLayer release tag, e.g. v0.1.35 (resolves the verifiable digest)
#   vmm-url    : dstack-vmm RPC (default from VMM_URL or http://127.0.0.1:11000)
#
# Prereqs: dstack-vmm running (Step 3), per-node KMS deployed + keystore app allowlisted
# in auth-simple (Step 4), keystore/keystore.env filled (secrets), guest image present.
#
# Forked from 40-deploy-worker.sh. Differences vs the worker:
#   - resolves the `| keystore |` digest row + image outlayer/near-outlayer-keystore
#   - default ENVFILE=keystore/keystore.env, app-compose name default outlayer-keystore
#   - default resources 2 vCPU / 2G / 1G (Phala used that; resources affect RTMR0/RTMR1 —
#     keep CONSTANT so measurements are reusable / approved once per (net,version))
#   - the keystore is an INBOUND server: in addition to the loopback agent port (logs), it
#     maps a LOOPBACK host port -> guest 8081 for node-local smoke tests. Production traffic
#     reaches 8081 over the WG mesh / dstack-gateway, NOT via this loopback port.
set -euo pipefail

VERSION="${1:?usage: 40-deploy-keystore.sh <version> [vmm-url]}"
VMM_URL="${2:-${VMM_URL:-http://127.0.0.1:11000}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="$HERE/keystore/docker-compose.yaml"
# ENVFILE: per-network secrets file (gitignored). Override for testnet/mainnet, e.g.
#   ENVFILE=keystore/.env.mainnet-keystore-tdx ./40-deploy-keystore.sh v0.1.35
# Resolved as given (cwd/absolute) if it exists, else relative to this script's dir.
ENVFILE="${ENVFILE:-$HERE/keystore/keystore.env}"
[ -f "$ENVFILE" ] || ENVFILE="$HERE/$ENVFILE"
VMM_CLI="${VMM_CLI:-/opt/mpc/dstack/vmm/src/vmm-cli.py}"   # adjust to your dstack path
IMAGE_OS="${IMAGE_OS:-dstack-0.5.11}"   # must exist in vmm's image dir (vmm-cli lsimage); affects MRTD/RTMR0-2
# KMS_URL is used for BOTH (a) host-side env-encryption at deploy AND (b) baked into the CVM as
# its RUNTIME kms_urls (vmm-cli.py: params["kms_urls"]=args.kms_url). So it MUST be the URL the
# CVM uses at runtime: https://kms.1022.dstack.org:11001 -> resolves to 10.0.2.2 (the host) via
# slirp INSIDE the CVM. (Do NOT use 127.0.0.1 here — it bakes the CVM's own loopback and boot
# fails "Connection refused".) The catch: that hostname resolves to 10.0.2.2 on the HOST too,
# which the host can't reach — so for the host-side encryption we add a TEMPORARY /etc/hosts
# entry kms.1022.dstack.org->127.0.0.1, then REMOVE it before the CVM boots (else slirp hands the
# guest 127.0.0.1). See the /etc/hosts dance around the deploy below.
KMS_URL="${KMS_URL:-https://kms.1022.dstack.org:11001}"
KMS_HOST="$(printf '%s' "$KMS_URL" | sed -E 's#^https?://([^:/]+).*#\1#')"
# APP_NAME  = the CVM's VM LABEL (shown in lsvm, targeted by worker-ctl.sh). Unique per instance.
# COMPOSE_NAME = the name baked into the MEASURED app-compose (drives the compose hash -> RTMR3 ->
#   measurements). Keep it STABLE per (network, version) so all instances of a version share the
#   same measurements and you approve them ONCE. Defaults to APP_NAME if unset (single-instance).
# Neither is a keystore.env variable — both are deploy-time args.
APP_NAME="${APP_NAME:-outlayer-keystore}"
COMPOSE_NAME="${COMPOSE_NAME:-$APP_NAME}"

[ -f "$ENVFILE" ] || { echo "Missing $ENVFILE (cp from keystore/<net>-keystore.env.template + fill secrets)"; exit 1; }
echo "[env] reading secrets from: $(readlink -f "$ENVFILE" 2>/dev/null || echo "$ENVFILE")  (on $(hostname))"

echo "[1/3] Resolve verifiable keystore digest for $VERSION..."
if [ -n "${WORKER_DIGEST:-}" ]; then
  # Operator-supplied, pre-verified digest. Use this on nodes WITHOUT gh (e.g. the TDX node):
  # resolve + attest the digest once on a trusted machine that has gh, then pass it here.
  # (Var is named WORKER_DIGEST for parity with 40-deploy-worker.sh + the node-side wrapper —
  # it carries WHICHEVER component's digest this script needs; here, the keystore's.)
  case "$WORKER_DIGEST" in sha256:*) DIGEST="$WORKER_DIGEST" ;; *) DIGEST="sha256:$WORKER_DIGEST" ;; esac
  echo "  using WORKER_DIGEST override: $DIGEST"
elif command -v gh >/dev/null 2>&1; then
  # `|| true`: don't let set -e kill us inside the command substitution — the guard below
  # prints a useful message instead of dying silently.
  DIGEST=$(gh release view "$VERSION" --repo fastnear/near-outlayer --json body -q '.body' 2>/dev/null \
    | grep -iE '\| *keystore *\|' | grep -oE 'sha256:[a-f0-9]{64}' | head -1) || true
  echo "  keystore digest (GitHub release, Sigstore-attested): ${DIGEST:-<none found>}"
else
  echo "ERROR: gh is not installed and WORKER_DIGEST is not set." >&2
  echo "  On a machine WITH gh (e.g. your laptop), resolve + verify the digest:" >&2
  echo "    gh release view $VERSION --repo fastnear/near-outlayer --json body -q .body | grep -iE '\\| *keystore *\\|'" >&2
  echo "    gh attestation verify oci://docker.io/outlayer/near-outlayer-keystore@<digest> -R fastnear/near-outlayer" >&2
  echo "  then re-run here with:  WORKER_DIGEST=sha256:<digest> $0 $VERSION" >&2
  exit 1
fi
[ -n "$DIGEST" ] || { echo "Could not resolve keystore digest for $VERSION — pass WORKER_DIGEST=sha256:..." >&2; exit 1; }
echo "  keystore digest: $DIGEST"
echo "  verify (on a trusted machine): gh attestation verify oci://docker.io/outlayer/near-outlayer-keystore@$DIGEST -R fastnear/near-outlayer"
# Render the compose with the pinned digest into a TEMP file — never mutate the committed
# docker-compose.yaml (that would dirty the git tree and block `git pull` on the node).
RENDERED="$(mktemp "${TMPDIR:-/tmp}/outlayer-keystore-compose.XXXXXX")"
sed "s|image: docker.io/outlayer/near-outlayer-keystore@sha256:.*|image: docker.io/outlayer/near-outlayer-keystore@$DIGEST|" "$COMPOSE" > "$RENDERED"

# --- temporary /etc/hosts so the HOST-side KMS encryption can reach $KMS_HOST (see KMS_URL note).
#     Removed before the CVM boots so the guest resolves $KMS_HOST -> 10.0.2.2 (host), not 127.0.0.1.
HOSTS_MARK="outlayer-tdx-deploy-kms"
hosts_cleanup() { sudo sed -i "\|${HOSTS_MARK}|d" /etc/hosts 2>/dev/null || true; }
cleanup() { hosts_cleanup; rm -f "$RENDERED"; }
trap cleanup EXIT
if ! grep -qF "$HOSTS_MARK" /etc/hosts; then
  echo "127.0.0.1 $KMS_HOST # $HOSTS_MARK" | sudo tee -a /etc/hosts >/dev/null
  echo "  (temporary) /etc/hosts: $KMS_HOST -> 127.0.0.1 (host-side KMS encryption only)"
fi

echo "[2/3] Build app-compose (measured name=$COMPOSE_NAME; KMS env NOT baked into it)..."
python3 "$VMM_CLI" --url "$VMM_URL" compose \
  --name "$COMPOSE_NAME" \
  --docker-compose "$RENDERED" \
  --kms \
  --public-logs --no-instance-id \
  --env-file "$ENVFILE" \
  --output "$HERE/keystore/app-compose.json"

# Replace-on-redeploy: vmm ALLOWS duplicate VM names, so re-running with the same name would
# create a SECOND CVM and the reboot/lookup below could target the wrong one. Remove any existing
# CVM with this exact VM label first. (For multiple concurrent instances, use distinct names.)
for old in $(python3 "$VMM_CLI" --url "$VMM_URL" lsvm 2>/dev/null | grep -Fw "$APP_NAME" \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'); do
  echo "Replacing existing CVM '$APP_NAME' ($old) — stop + remove..."
  python3 "$VMM_CLI" --url "$VMM_URL" stop -f "$old" >/dev/null 2>&1 || true
  python3 "$VMM_CLI" --url "$VMM_URL" remove "$old" >/dev/null 2>&1 || true
done

echo "[3/3] Deploy keystore CVM (inbound :8081 on a loopback host port)..."
# Two host port mappings, BOTH loopback-only (the keystore is reached over the WG mesh /
# dstack-gateway in prod, NOT via these host ports):
#   1) guest 8090 (dstack guest-agent) -> a free host port: logs/measurements via worker-ctl.sh.
#   2) guest 8081 (the keystore HTTP server) -> a free host port: node-local /health smoke test.
# A FIXED port collides as soon as a 2nd CVM is deployed ("Could not set up host forwarding
# rule" -> qemu crash-loops), so pick FREE host ports. worker-ctl.sh discovers the live agent
# port afterwards (vmm may reassign on restart); for the keystore port the orchestrator reads
# the live qemu cmdline (`...:8081`) the same way.
pick_free_port() {  # $1 = first port to try; echoes a free loopback port
  local p
  for p in $(seq "$1" 9999); do
    ss -ltn 2>/dev/null | grep -q "127.0.0.1:$p " || { echo "$p"; return 0; }
  done
  return 1
}
AGENT_HOST_PORT="$(pick_free_port 9210)" || { echo "No free host port for the agent" >&2; exit 1; }
KS_HOST_PORT="$(pick_free_port "$((AGENT_HOST_PORT + 1))")" || { echo "No free host port for 8081" >&2; exit 1; }
echo "  agent host port: $AGENT_HOST_PORT (initial; worker-ctl.sh discovers the live port)"
echo "  keystore host port: 127.0.0.1:$KS_HOST_PORT -> 8081 (loopback smoke test only)"
DEPLOY_OUT="$(python3 "$VMM_CLI" --url "$VMM_URL" deploy \
  --name "$APP_NAME" \
  --compose "$HERE/keystore/app-compose.json" \
  --image "$IMAGE_OS" \
  --env-file "$ENVFILE" \
  --kms-url "$KMS_URL" \
  --vcpu 2 --memory 2G --disk 1G \
  --port "tcp:127.0.0.1:$AGENT_HOST_PORT:8090" \
  --port "tcp:127.0.0.1:$KS_HOST_PORT:8081" 2>&1)"
echo "$DEPLOY_OUT"

# Remove the temp /etc/hosts NOW (before the guest's KMS DNS query), then reboot the CVM so its
# boot resolves $KMS_HOST -> 10.0.2.2 cleanly (the first boot may race the entry and fail KMS).
# (The EXIT trap still runs cleanup() to remove $RENDERED + re-assert the /etc/hosts removal.)
hosts_cleanup
# Capture the JUST-CREATED VM id from the deploy output — NOT a name lookup (names can collide).
VM_ID="$(printf '%s' "$DEPLOY_OUT" | grep -oE 'Created VM with ID: [0-9a-f-]+' \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
if [ -n "$VM_ID" ]; then
  echo "Clean-DNS reboot of $APP_NAME ($VM_ID) so the guest reaches the KMS at 10.0.2.2..."
  python3 "$VMM_CLI" --url "$VMM_URL" stop -f "$VM_ID" >/dev/null 2>&1 || true
  python3 "$VMM_CLI" --url "$VMM_URL" start "$VM_ID" >/dev/null 2>&1 || true
fi

echo "Done. Keystore boots, gets its KMS app key + a TDX quote, and self-submits its DAO"
echo "registration (submit_keystore_registration -> logs 'Proposal ID: N'). First boot stalls on"
echo "measurements-not-approved (expected) but the CVM stays up — the orchestrator"
echo "(scripts/deploy_tdx.sh keystore) reads the 5 measurements + owner-approves on the DAO +"
echo "votes (zavodil) so the proposal passes, then the keystore pulls its MPC-CKD master."
echo "Logs:  NAME=$APP_NAME CONTAINER=dstack-keystore-1 ./worker-ctl.sh follow"
