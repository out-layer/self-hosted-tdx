#!/usr/bin/env bash
# Deploy an OutLayer component to the SELF-HOSTED TDX node — same UX as scripts/deploy_phala.sh,
# but targets our dstack-vmm (CVM) instead of Phala Cloud.
#
# Usage:
#   ./deploy_tdx.sh worker   [testnet|mainnet] [name] --version <ver>
#   ./deploy_tdx.sh keystore [testnet|mainnet] [name] --version <ver>
#
# Examples:
#   ./deploy_tdx.sh worker testnet  worker0135-1 --version 0.1.35
#   ./deploy_tdx.sh worker mainnet  outlayer-worker-mainnet-0.1.35-1 --version 0.1.35
#   ./deploy_tdx.sh worker testnet  --version 0.1.35           # name defaults to outlayer-worker-testnet-0.1.35-1
#   ./deploy_tdx.sh keystore testnet --version 0.1.35          # name defaults to outlayer-keystore-testnet-0.1.35-1
#
# This node has no `gh`, so the image digest can't be auto-resolved here. Resolve + attest it
# ONCE on a machine with gh, then pass it (it propagates to 40-deploy-{worker,keystore}.sh):
#   WORKER_DIGEST=sha256:<digest> ./deploy_tdx.sh worker testnet worker0135-1 --version 0.1.35
# (WORKER_DIGEST carries whichever component's digest you're deploying — worker OR keystore.)
#
# The env comes from <component>/.env.<network>-<component>-tdx (gitignored; copy from
# <component>/<network>-<component>.env.template and fill secrets). The name (3rd arg) becomes
# the CVM name (APP_NAME) — worker-ctl.sh then targets it by that name.
# NOTE: the keystore deploy only puts the CVM up + self-submits its DAO registration. The DAO
# governance (owner-approve measurements + zavodil vote) is driven from the Mac by
# scripts/deploy_tdx.sh keystore, which keeps the owner/voter keys local.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DEPLOY_VERSION=""
DRY_RUN=false
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) DEPLOY_VERSION="${2:?--version needs a value}"; shift 2 ;;
    --dry-run|--info) DRY_RUN=true; shift ;;
    *) POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done

[ "${#POSITIONAL_ARGS[@]}" -ge 1 ] || { echo "Usage: $0 <worker|keystore> [testnet|mainnet] [name] --version <ver>" >&2; exit 1; }
COMPONENT="${POSITIONAL_ARGS[0]}"
NETWORK="${POSITIONAL_ARGS[1]:-testnet}"
NAME="${POSITIONAL_ARGS[2]:-}"

case "$NETWORK" in testnet|mainnet) ;; *) echo "network must be testnet|mainnet (got '$NETWORK')" >&2; exit 1 ;; esac
[ -n "$DEPLOY_VERSION" ] || { echo "--version <ver> is required (e.g. --version 0.1.35)" >&2; exit 1; }
VER="v${DEPLOY_VERSION#v}"   # normalize 0.1.35 / v0.1.35 -> v0.1.35

case "$COMPONENT" in
  worker)
    ENVREL="worker/.env.${NETWORK}-worker-tdx"
    [ -f "$HERE/$ENVREL" ] || {
      echo "Missing $ENVREL" >&2
      echo "  cp $HERE/worker/${NETWORK}-worker.env.template $HERE/$ENVREL  and fill the secrets" >&2
      exit 1
    }
    # COMPOSE_NAME is STABLE per (net, version) -> shared measurements -> approve ONCE per (net,ver).
    # NAME is the per-instance VM label (lsvm / worker-ctl.sh). Add an index for extra instances.
    COMPOSE_NAME="outlayer-worker-${NETWORK}-${DEPLOY_VERSION#v}"
    : "${NAME:=${COMPOSE_NAME}-1}"
    echo "Deploy WORKER  net=$NETWORK  vm-label=$NAME  measured-name=$COMPOSE_NAME  version=$VER  env=$ENVREL"
    if $DRY_RUN; then
      echo "(dry-run) APP_NAME=$NAME COMPOSE_NAME=$COMPOSE_NAME ENVFILE=$ENVREL $HERE/40-deploy-worker.sh $VER"
      exit 0
    fi
    APP_NAME="$NAME" COMPOSE_NAME="$COMPOSE_NAME" ENVFILE="$ENVREL" "$HERE/40-deploy-worker.sh" "$VER"
    echo "Deployed '$NAME'. First boot needs measurement approval (see docs/cvm-operations.md)."
    echo "Manage:  NAME=$NAME worker-ctl.sh follow | restart | stop"
    ;;
  keystore)
    ENVREL="keystore/.env.${NETWORK}-keystore-tdx"
    [ -f "$HERE/$ENVREL" ] || {
      echo "Missing $ENVREL" >&2
      echo "  cp $HERE/keystore/${NETWORK}-keystore.env.template $HERE/$ENVREL  and fill the secrets" >&2
      exit 1
    }
    # COMPOSE_NAME is STABLE per (net, version) -> shared measurements -> approve ONCE per (net,ver).
    # NAME is the per-instance VM label (lsvm / worker-ctl.sh). Add an index for extra instances.
    COMPOSE_NAME="outlayer-keystore-${NETWORK}-${DEPLOY_VERSION#v}"
    : "${NAME:=${COMPOSE_NAME}-1}"
    echo "Deploy KEYSTORE  net=$NETWORK  vm-label=$NAME  measured-name=$COMPOSE_NAME  version=$VER  env=$ENVREL"
    if $DRY_RUN; then
      echo "(dry-run) APP_NAME=$NAME COMPOSE_NAME=$COMPOSE_NAME ENVFILE=$ENVREL $HERE/40-deploy-keystore.sh $VER"
      exit 0
    fi
    APP_NAME="$NAME" COMPOSE_NAME="$COMPOSE_NAME" ENVFILE="$ENVREL" "$HERE/40-deploy-keystore.sh" "$VER"
    echo "Deployed '$NAME'. First boot self-submits its DAO registration; needs measurement"
    echo "approval + a DAO vote (see docs). The Mac orchestrator scripts/deploy_tdx.sh handles both."
    echo "Manage:  NAME=$NAME CONTAINER=dstack-keystore-1 worker-ctl.sh follow | restart | stop"
    ;;
  *)
    echo "unknown component '$COMPONENT' (use: worker | keystore)" >&2; exit 1 ;;
esac
