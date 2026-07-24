#!/usr/bin/env bash
#
# Mac-side orchestrator: install the attestation-agent on a TDX node, from your laptop.
#
# The agent is a read-only collector: it reads the node's dstack-vmm over loopback and PUSHES a
# fleet snapshot to the portal's /ingest (the portal never reaches into a node). One agent per node,
# each with a distinct NODE_ID. It surfaces the node on workers.outlayer.ai.
#
# The agent SOURCE lives in the separate `out-layer/attestation-portal` repo (it shares a crate with
# the portal server). This script does NOT vendor that source — it points at a checkout of it.
#
# IMPORTANT — do not build the agent on a Mac and copy it over: the node is Linux/x86-64, a Mac
# build is arm64 Mach-O, and systemd fails it with `Exec format error` (203/EXEC). So the binary is
# produced ON THE NODE (default), or copied from a healthy sibling node (same arch) — never from here.
#
# Usage (build on the target node from a portal checkout):
#   PUSH_TOKEN=<ingest-token> ./install-agent.sh --node root@<ip> --node-id node-tdx-<name> \
#       --portal-repo ~/projects/attestation-portal --portal root@<portal-server>
#
# Add a node to an existing fleet by cloning a healthy node's binary (fast, no build):
#   ./install-agent.sh --node root@23.109.254.164 --node-id node-tdx-ams-1 \
#       --from-node root@173.237.9.76 --token-from root@173.237.9.76 --portal root@138.201.58.122
#
# Options:
#   --node <ssh>          REQUIRED. SSH target of the TDX node (lands as root).
#   --node-id <id>        REQUIRED. Stable label for this node (portal groups pushes by it).
#   --portal-repo <path>  attestation-portal checkout to build from (default ~/projects/attestation-portal).
#   --from-node <ssh>     Skip building: copy /usr/local/bin/attestation-agent from this node instead.
#   --bin <path>          Skip building: install this prebuilt Linux/x86-64 binary.
#   --token-from <ssh>    Read PUSH_TOKEN from that node's /etc/attestation-agent/agent.env.
#   --portal <ssh>        Also allow this node's egress IP on the portal's /ingest + reload nginx.
#   --ingest-url <url>    Portal ingest endpoint (default https://workers.outlayer.ai/ingest).
#   --vmm-rpc <url>       Node dstack-vmm RPC (default http://127.0.0.1:11000 — the OutLayer vmm).
#   --build-user <name>   Node user whose Rust builds the agent (default outlayer; has ~/.cargo from dstack).
#   --run-user <name>     Node user the agent runs as (default outlayer).
# Env:
#   PUSH_TOKEN            The portal INGEST_TOKEN. Required unless --token-from is given.
set -euo pipefail

NODE=""; NODE_ID=""; PORTAL_REPO="$HOME/projects/attestation-portal"; FROM_NODE=""; BIN=""
TOKEN_FROM=""; PORTAL=""; INGEST_URL="https://workers.outlayer.ai/ingest"
VMM_RPC="http://127.0.0.1:11000"; BUILD_USER="outlayer"; RUN_USER="outlayer"
while [[ $# -gt 0 ]]; do case "$1" in
  --node)        NODE="${2:?}"; shift 2;;
  --node-id)     NODE_ID="${2:?}"; shift 2;;
  --portal-repo) PORTAL_REPO="${2:?}"; shift 2;;
  --from-node)   FROM_NODE="${2:?}"; shift 2;;
  --bin)         BIN="${2:?}"; shift 2;;
  --token-from)  TOKEN_FROM="${2:?}"; shift 2;;
  --portal)      PORTAL="${2:?}"; shift 2;;
  --ingest-url)  INGEST_URL="${2:?}"; shift 2;;
  --vmm-rpc)     VMM_RPC="${2:?}"; shift 2;;
  --build-user)  BUILD_USER="${2:?}"; shift 2;;
  --run-user)    RUN_USER="${2:?}"; shift 2;;
  *) echo "unknown arg: $1" >&2; exit 1;;
esac; done

[ -n "$NODE" ]    || { echo "--node <ssh> required" >&2; exit 1; }
[ -n "$NODE_ID" ] || { echo "--node-id <id> required" >&2; exit 1; }

if [ -n "$TOKEN_FROM" ]; then
  echo "[token] reading PUSH_TOKEN from $TOKEN_FROM ..."
  PUSH_TOKEN="$(ssh "$TOKEN_FROM" 'grep -E "^PUSH_TOKEN=" /etc/attestation-agent/agent.env | cut -d= -f2-')"
fi
[ -n "${PUSH_TOKEN:-}" ] || { echo "PUSH_TOKEN required (set it, or pass --token-from <ssh>)" >&2; exit 1; }

# [1/4] get a Linux/x86-64 binary onto the node as /usr/local/bin/attestation-agent.
if [ -n "$FROM_NODE" ]; then
  echo "[1/4] Copy the working binary from $FROM_NODE (same arch, no build) ..."
  ssh "$FROM_NODE" 'base64 /usr/local/bin/attestation-agent' \
    | ssh "$NODE" 'base64 -d > /usr/local/bin/attestation-agent.new'
elif [ -n "$BIN" ]; then
  echo "[1/4] Install prebuilt binary $BIN ..."
  file "$BIN" | grep -q "ELF .*x86-64" || { echo "  $BIN is not a Linux/x86-64 ELF — refusing (would 203/EXEC)" >&2; exit 1; }
  scp -q "$BIN" "$NODE:/usr/local/bin/attestation-agent.new"
else
  # Default: build ON THE NODE from a portal checkout. The agent needs the sibling `shared` crate,
  # so ship the whole workspace (minus target/.git); `-p attestation-agent` builds only what's needed.
  [ -f "$PORTAL_REPO/agent/Cargo.toml" ] || { echo "no attestation-portal checkout at $PORTAL_REPO (use --portal-repo)" >&2; exit 1; }
  echo "[1/4] Build on $NODE from $PORTAL_REPO (as $BUILD_USER) ..."
  ssh "$NODE" "install -d -o '$BUILD_USER' -g '$BUILD_USER' /tmp/attestation-portal-src"
  rsync -a --delete --rsync-path="sudo -u '$BUILD_USER' rsync" \
    --exclude target --exclude .git \
    "$PORTAL_REPO/" "$NODE:/tmp/attestation-portal-src/"
  ssh "$NODE" "su - '$BUILD_USER' -c 'source ~/.cargo/env 2>/dev/null; cd /tmp/attestation-portal-src && cargo build --release -p attestation-agent'"
  ssh "$NODE" "cp /tmp/attestation-portal-src/target/release/attestation-agent /usr/local/bin/attestation-agent.new"
fi

# Sanity: refuse a non-Linux-x86-64 binary before it becomes a crash loop.
ssh "$NODE" 'file /usr/local/bin/attestation-agent.new | grep -q "ELF .*x86-64"' \
  || { echo "  built/copied binary is not Linux/x86-64 — aborting" >&2; ssh "$NODE" 'rm -f /usr/local/bin/attestation-agent.new'; exit 1; }
ssh "$NODE" 'chmod 755 /usr/local/bin/attestation-agent.new && mv /usr/local/bin/attestation-agent.new /usr/local/bin/attestation-agent'

# [2/4] env (0600) + unit.
echo "[2/4] Write env + systemd unit (NODE_ID=$NODE_ID, run-user=$RUN_USER) ..."
ENV_B64="$(printf 'VMM_RPC=%s\nNODE_ID=%s\nPORTAL_INGEST_URL=%s\nPUSH_TOKEN=%s\nPUSH_INTERVAL_SECS=300\nAGENT_BIND=127.0.0.1:9300\n' \
  "$VMM_RPC" "$NODE_ID" "$INGEST_URL" "$PUSH_TOKEN" | base64 | tr -d '\n')"
ssh "$NODE" "RUN_USER='$RUN_USER' ENV_B64='$ENV_B64' bash -s" <<'REMOTE'
set -euo pipefail
install -d -m 755 /etc/attestation-agent
umask 077
echo "$ENV_B64" | base64 -d > /etc/attestation-agent/agent.env
chmod 600 /etc/attestation-agent/agent.env
cat > /etc/systemd/system/attestation-agent.service <<UNIT
[Unit]
Description=OutLayer Attestation Agent (read-only fleet collector -> portal push)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
ExecStart=/usr/local/bin/attestation-agent
EnvironmentFile=/etc/attestation-agent/agent.env
Restart=on-failure
RestartSec=10
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now attestation-agent
REMOTE

# [3/4] portal-side allow (optional). The portal pins /ingest to each node's egress IP; behind
# Cloudflare it is the CF-Connecting-IP the agent's host presents, i.e. the node's WAN egress.
NODE_EGRESS="$(ssh "$NODE" 'curl -s --max-time 8 https://ifconfig.me' || true)"
if [ -n "$PORTAL" ] && [ -n "$NODE_EGRESS" ]; then
  echo "[3/4] Allow $NODE_EGRESS on the portal /ingest ..."
  ssh "$PORTAL" "NODE_EGRESS='$NODE_EGRESS' bash -s" <<'REMOTE'
set -euo pipefail
VHOST=/etc/nginx/sites-available/workers.outlayer.ai
if grep -q "allow $NODE_EGRESS;" "$VHOST"; then
  echo "  already allowed"
else
  sed -i "/deny all;/i\\        allow $NODE_EGRESS;" "$VHOST"
  nginx -t && systemctl reload nginx && echo "  allowed + reloaded"
fi
REMOTE
else
  echo "[3/4] No --portal: the push 403s until the portal's /ingest allows this node's egress IP"
  echo "      (${NODE_EGRESS:-<run 'curl ifconfig.me' on the node>}). On the portal server:"
  echo "        sed -i '/deny all;/i\\        allow ${NODE_EGRESS:-<egress-ip>};' \\"
  echo "          /etc/nginx/sites-available/workers.outlayer.ai && nginx -t && systemctl reload nginx"
fi

# [4/4] verify the agent starts and pushes.
echo "[4/4] Verify ..."
sleep 3
ssh "$NODE" 'systemctl is-active attestation-agent; journalctl -u attestation-agent --no-pager -n 4 | grep -iE "pushed|push failed|error" | tail -3' || true
echo "Done. Watch: ssh $NODE 'journalctl -u attestation-agent -f'"
