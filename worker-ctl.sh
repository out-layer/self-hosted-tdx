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
#   ./worker-ctl.sh port                   # print the current agent host port
#   NAME=outlayer-worker-mainnet ./worker-ctl.sh logs   # target a different CVM
set -euo pipefail

V="${VMM_CLI:-/opt/mpc/dstack/vmm/src/vmm-cli.py}"
U="${VMM_URL:-http://127.0.0.1:11000}"
NAME="${NAME:-outlayer-worker}"          # CVM name as shown in `lsvm`
CONTAINER="${CONTAINER:-dstack-worker-1}" # docker container for app logs (compose: project dstack, service worker)
TAIL="${TAIL:-200}"

vmm() { python3 "$V" --url "$U" "$@"; }

uuid_of() {
  vmm lsvm 2>/dev/null | grep -w "$NAME" \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
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
  local u; u=$(uuid_of)
  [ -n "$u" ] || { echo "No CVM named '$NAME' in lsvm (set NAME=...)" >&2; exit 1; }
  echo "$u"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  status|ls)  vmm lsvm ;;
  info)       vmm info "$(need_uuid)" ;;
  uuid)       need_uuid ;;
  port)       p=$(agent_port "$(need_uuid)"); echo "${p:-<no live qemu / not started>}" ;;
  logs)       u=$(need_uuid); p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -s  "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&tail=$TAIL" ;;
  follow|f)   u=$(need_uuid); p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -sN "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&follow=true&tail=$TAIL" ;;
  serial)     vmm logs -n "$TAIL" "$(need_uuid)" ;;   # qemu serial console (boot/system, not app)
  stop)       vmm stop -f "$(need_uuid)" ;;
  start)      vmm start "$(need_uuid)" ;;
  restart)    u=$(need_uuid); vmm stop -f "$u"; vmm start "$u"; echo "restarted $NAME ($u) — re-run '$0 follow' to watch (port changed)" ;;
  *) echo "usage: $0 <status|info|uuid|port|logs|follow|serial|stop|start|restart>" >&2; exit 1 ;;
esac
