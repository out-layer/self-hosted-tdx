#!/usr/bin/env bash
# Ship this runbook tree to a TDX node, straight into the outlayer user's copy. The nodes carry no
# git checkout of this repo (no repo key on the node, no .git/.idea/secrets on the wire), so this
# rsync IS the update path; run it from the Mac after every change here.
#
#   ./sync-node.sh <host>            # e.g. ./sync-node.sh 23.109.254.164   (ssh as root)
#   ./sync-node.sh <host> --dry-run  # show what would change, touch nothing
#
# Never deletes on the node (the node-only files — worker/.env.*, keystore/.env.*, the auth config
# under ~outlayer/outlayer-kms — must survive), and never copies the mainnet worker env, any
# keystore env, or the Mac-side .env (Cloudflare token): those are placed by hand where needed, see
# docs/setup-new-node.md.
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
  --exclude 'keystore/.env.*' --exclude 'worker/.env.mainnet-worker-tdx' \
  --rsync-path="mkdir -p '$DEST' && rsync" \
  "$HERE/" "root@$HOST:$DEST/"
if $DRY; then echo "dry-run: nothing changed on $HOST"; exit 0; fi
ssh "root@$HOST" "chown -R '$NODE_USER:$NODE_USER' '$DEST'"
echo "synced -> root@$HOST:$DEST (owner $NODE_USER)"
