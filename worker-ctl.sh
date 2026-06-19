#!/usr/bin/env bash
# Manage a self-hosted TDX worker CVM by NAME (stable), not by host port.
#
# Why: dstack-vmm assigns the guest-agent host port (→ CVM 8090) from a pool on every
# VM start, so it CHANGES on each stop/start (e.g. 9210 → 11015). The VM uuid is stable
# but awkward to type. This wrapper resolves the CVM by name via `lsvm`, drives
# stop/start/logs by uuid, and auto-discovers the current agent port for log streaming.
#
# Run ON THE NODE (ssh root@173.237.9.76). Examples:
#   ./worker-ctl.sh status                 # lsvm
#   ./worker-ctl.sh logs                   # last 200 worker app-log lines (snapshot)
#   ./worker-ctl.sh follow                 # stream worker app logs (Ctrl-C to stop)
#   ./worker-ctl.sh restart                # stop -f + start (re-runs registration)
#   ./worker-ctl.sh remove <cvm-name>      # stop + delete the CVM (record + disk) — destructive
#   ./worker-ctl.sh port                   # print the current agent host port
#   ./worker-ctl.sh logs <cvm-name>        # target a CVM by name (positional), e.g.:
#   ./worker-ctl.sh logs outlayer-worker-testnet-0.1.35-1
#   ./worker-ctl.sh logs kms               # KMS CVM (auto-uses container dstack-kms-1)
#   NAME=outlayer-worker-mainnet ./worker-ctl.sh follow  # or target via NAME= env
#
# NOTE: for KMS *boot-authorization* decisions (allow/deny on worker boot) see the host log:
#   journalctl -u outlayer-kms-auth.service -f
set -euo pipefail

V="${VMM_CLI:-/opt/mpc/dstack/vmm/src/vmm-cli.py}"
U="${VMM_URL:-http://127.0.0.1:11000}"
NAME="${NAME:-outlayer-worker}"          # CVM name (lsvm); override via env or positional arg
CONTAINER="${CONTAINER:-}"               # app-log container; auto-picked from NAME below if empty
TAIL="${TAIL:-200}"

vmm() { python3 "$V" --url "$U" "$@"; }

# Resolve $NAME to exactly one uuid. Accept a uuid directly; otherwise match the lsvm **Name**
# column EXACTLY (not the App ID / VM ID columns — an App ID is shared by all same-version
# workers, so matching it would be ambiguous). Returns 0/1/many uuids; need_uuid enforces "one".
uuids_for_name() {
  case "$NAME" in
    [0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*-[0-9a-f]*) echo "$NAME"; return ;;  # already a uuid
  esac
  vmm lsvm 2>/dev/null | sed 's/│/|/g' | awk -F'|' -v want="$NAME" '
    { name=$4; uuid=$2; gsub(/[[:space:]]/,"",name); gsub(/[[:space:]]/,"",uuid);
      if (name==want && uuid ~ /^[0-9a-f-]{36}$/) print uuid }'
}

# Find the agent host port (→ guest 8090) of the LIVE qemu for this uuid.
agent_port() {
  local uuid="$1" pid cmd
  for pid in $(pgrep -f qemu-system-x86_64); do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    [[ "$cmd" == *"$uuid"* ]] || continue
    echo "$cmd" | grep -oE '127\.0\.0\.1:[0-9]+-:8090' | sed -E 's/.*:([0-9]+)-:8090/\1/' | head -1
    return
  done
}

need_uuid() {
  local uuids n
  uuids=$(uuids_for_name)
  n=$(printf '%s' "$uuids" | grep -c .)
  if [ "$n" -eq 0 ]; then
    echo "worker-ctl: no CVM named '$NAME' (pass an exact name or uuid; see 'worker-ctl.sh status')" >&2
    exit 1
  fi
  if [ "$n" -gt 1 ]; then
    echo "worker-ctl: '$NAME' matches multiple CVMs — target one by uuid (NAME=<uuid>):" >&2
    printf '%s' "$uuids" | sed 's/^/  /' >&2
    exit 1
  fi
  printf '%s' "$uuids"
}

cmd="${1:-status}"; shift || true
# optional positional CVM name after the subcommand: `worker-ctl.sh logs <name>`
if [ "${1:-}" ] && [[ "${1:-}" != -* ]]; then NAME="$1"; shift; fi
# pick the app-log container from the CVM name (compose project 'dstack'): kms -> dstack-kms-1
[ -n "$CONTAINER" ] || case "$NAME" in
  *kms*)      CONTAINER=dstack-kms-1 ;;
  *gateway*)  CONTAINER=dstack-gateway-1 ;;
  *keystore*) CONTAINER=dstack-keystore-1 ;;
  *)          CONTAINER=dstack-worker-1 ;;
esac
# Resolve the target uuid up front for every subcommand except status — and propagate a
# resolution failure (need_uuid's `exit` inside $() would otherwise be swallowed, leaving an
# empty uuid that agent_port matches to the first qemu). `|| exit 1` stops cleanly on error.
case "$cmd" in status|ls|'') : ;; *) u=$(need_uuid) || exit 1 ;; esac

case "$cmd" in
  status|ls)  vmm lsvm ;;
  info)       vmm info "$u" ;;
  uuid)       echo "$u" ;;
  port)       p=$(agent_port "$u"); echo "${p:-<no live qemu / not started>}" ;;
  logs)       p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -s  "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&tail=$TAIL" ;;
  follow|f)   p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -sN "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&follow=true&tail=$TAIL" ;;
  serial)     vmm logs -n "$TAIL" "$u" ;;   # qemu serial console (boot/system, not app)
  stop)       vmm stop -f "$u" ;;
  start)      vmm start "$u" ;;
  restart)    vmm stop -f "$u"; vmm start "$u"; echo "restarted $NAME ($u) — re-run '$0 follow' to watch (port changed)" ;;
  remove|rm)  vmm stop -f "$u" >/dev/null 2>&1 || true; vmm remove "$u" && echo "REMOVED $NAME ($u) — CVM + disk deleted (gone from lsvm; not recoverable)" ;;
  *) echo "usage: $0 <status|info|uuid|port|logs|follow|serial|stop|start|restart|remove> [cvm-name]" >&2; exit 1 ;;
esac
