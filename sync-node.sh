#!/usr/bin/env bash
# Ship this runbook tree to a TDX node, straight into the outlayer user's copy. The nodes carry no
# git checkout of this repo (no repo key on the node, no .git/.idea/secrets on the wire), so this
# rsync IS the update path; run it from the Mac after every change here.
#
#   ./sync-node.sh <host>            # e.g. ./sync-node.sh 23.109.254.164   (ssh as root)
#   ./sync-node.sh <host> --dry-run  # show what would change, touch nothing
#
# Never deletes on the node (the node-only files — worker/.env.*, keystore/.env.*, the auth config
# under ~outlayer/outlayer-kms — must survive), and never copies a worker env, a keystore env,
# any *.bak-* file, a gateway env, or the Mac-side .env (Cloudflare token). Env files are each node's own: they
# differ between nodes (EXECUTE_EXCLUDES, written by scripts/deploy_tdx.sh per node), are placed
# by hand on a new node (docs/setup-new-node.md), and the one value every node shares,
# KEYSTORE_BASE_URLS, is written on all of them by scripts/keystore_urls.sh.
# rsync -a carries the Mac's file modes over, so afterwards every env file in the tree is set to
# 0600 on the node, whatever mode it had on the Mac. The deploy scripts refuse an env file that
# is not 0600.
# Works with macOS's openrsync (no --chown/--info there): the destination dir is created through
# --rsync-path and ownership is fixed with a separate ssh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${1:?usage: $0 <host> [--dry-run]}"; shift || true
DRY=false; for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=true; done
NODE_USER="${NODE_USER:-outlayer}"
DEST="/home/$NODE_USER/self-hosted-tdx"
rsync -a -v "$@" \
  --exclude '.git' --exclude '.idea' --exclude '.DS_Store' --exclude '.env' \
  --exclude 'keystore/.env.*' --exclude 'worker/.env.*' --exclude 'gateway/*.env' --exclude '*.bak-*' \
  --exclude 'worker/app-compose.json' --exclude '__pycache__' \
  --rsync-path="mkdir -p '$DEST' && rsync" \
  "$HERE/" "root@$HOST:$DEST/"
if $DRY; then echo "dry-run: nothing changed on $HOST"; exit 0; fi
ssh "root@$HOST" "chown -R '$NODE_USER:$NODE_USER' '$DEST' && find '$DEST' -type f \\( -name '.env*' -o -name '*.env' \\) ! -name '*.template' ! -name '*.example' -exec chmod 600 {} +"
echo "synced -> root@$HOST:$DEST (owner $NODE_USER)"
