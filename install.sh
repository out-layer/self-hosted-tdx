#!/usr/bin/env bash
# Symlink worker-ctl.sh into /usr/local/bin so it's on PATH on the node.
# worker-ctl.sh itself stays here in the repo (single source of truth, git-synced);
# this just creates a convenience link. Run on the node after cloning:  sudo ./install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-/usr/local/bin/worker-ctl.sh}"

chmod +x "$HERE/worker-ctl.sh"
ln -sf "$HERE/worker-ctl.sh" "$TARGET"
echo "linked $TARGET -> $HERE/worker-ctl.sh"
echo "try: worker-ctl.sh status"
