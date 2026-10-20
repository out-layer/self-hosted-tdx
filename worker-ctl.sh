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
#   ./worker-ctl.sh stop <cvm-name>        # SOFT: SIGTERM inside the CVM; a worker finishes the task in
#                                          # hand, takes no new one, exits; waits until the VM is down
#   ./worker-ctl.sh stop -f <cvm-name>     # FORCED: power off now — a running task is cut
#   ./worker-ctl.sh restart [-f]           # stop (soft unless -f) + start (re-runs registration)
#   ./worker-ctl.sh remove [-f] <cvm-name> # stop (soft unless -f) + delete the CVM (record + disk) — destructive
#   ./worker-ctl.sh set-image <cvm-name> <image>  # boot the CVM on another guest OS image (15-add-os-image.sh
#                                          # adds one): soft stop, `vmm-cli resize --image`, start. App-id, disk,
#                                          # env and ports stay; the measurements change, so they must be
#                                          # approved again (scripts/deploy_tdx.sh --os-image does it)
#   ./worker-ctl.sh port                   # print the current agent host port
#   ./worker-ctl.sh keystore-keys testnet  # `export KEEP_<SITE>="<key> <key>"` (KEEP_DAL / KEEP_AMS) = the
#                                          # registration keys of every running <net>-keystore-* CVM here;
#                                          # paste it on the Mac before scripts/revoke_old_keystore_keys.sh
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
# How long a soft stop waits for the guest to power off. The worker's compose gives it 85 s
# (stop_grace_period) before the guest kills it, so a guest still up after this is stuck.
SOFT_STOP_TIMEOUT="${SOFT_STOP_TIMEOUT:-180}"

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
# -f / --force anywhere after the subcommand: stop, restart and remove power the VM off at once.
FORCE=0
ARGS=()
for a in "$@"; do case "$a" in -f|--force) FORCE=1 ;; *) ARGS+=("$a") ;; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}
# optional positional CVM name after the subcommand: `worker-ctl.sh logs <name>`
# (for keystore-keys the positional is the network, kept apart from NAME)
NAME_ARG=""
if [ "${1:-}" ] && [[ "${1:-}" != -* ]]; then NAME_ARG="$1"; NAME="$1"; shift; fi
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
case "$cmd" in status|ls|keystore-keys|'') : ;; *) u=$(need_uuid) || exit 1 ;; esac

# Whether a qemu process for this uuid is alive.
vm_alive() { pgrep -f "qemu-system-x86_64.*$1" >/dev/null; }

# Stop the VM: forced (power off now) with -f, otherwise soft. A soft stop asks the guest to
# power off (`vmm stop` without -f → systemctl poweroff → docker compose stop → SIGTERM): a worker
# takes no new task, finishes the one in hand and exits, and the guest kills it after its
# stop_grace_period anyway. Waits until the VM is down; `follow` in another shell shows the log.
# Returns non-zero, having cut nothing, when the guest does not take the request or does not
# power off in time — the operator then decides on -f.
stop_vm() {
  local uuid="$1" start elapsed
  if [ "$FORCE" = 1 ]; then
    echo "forced stop of $NAME: a running task is cut"
    # An error from a VM that is already down is not a failure (remove -f of a stopped CVM).
    vmm stop -f "$uuid" || ! vm_alive "$uuid"
    return
  fi
  if ! vm_alive "$uuid"; then
    # Nothing to cut, but its `started` flag may still be set (a VM that exited on its own), and
    # the vmm restarts such a VM within 20 s: the forced stop clears the flag.
    vmm stop -f "$uuid" >/dev/null 2>&1 || true
    echo "$NAME is not running"
    return 0
  fi
  start=$(date +%s)
  if ! vmm stop "$uuid"; then
    echo "worker-ctl: the guest did not take the shutdown request (guest-agent not answering — frozen?)." >&2
    echo "            Nothing was stopped. To power it off anyway: $0 stop -f $NAME" >&2
    return 1
  fi
  while vm_alive "$uuid"; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$SOFT_STOP_TIMEOUT" ]; then
      echo "worker-ctl: $NAME still running ${elapsed}s after the shutdown request; nothing was forced." >&2
      echo "            To power it off anyway (a running task is cut): $0 stop -f $NAME" >&2
      return 1
    fi
    sleep 2
  done
  echo "stopped $NAME after $(( $(date +%s) - start ))s (soft)"
}

# The DAO registration key of every RUNNING keystore CVM on this node, as one
# `export KEEP_<SITE>="<key> <key>"` line for scripts/revoke_old_keystore_keys.sh, which requires
# one such variable per node (KEEP_DAL and KEEP_AMS) and retires every key not in them. SITE is
# the site label of the hostname (node-tdx-dal-2 -> DAL). Only the CVMs of the given network
# (`<net>-keystore-*`) count: each network has its own DAO, and a key of the other network would
# make the script refuse the run. The key is the last "Using keystore public key" line of the
# instance's log: a CVM restarted by the deploy orchestrator logs one key per boot, and only the
# last one is the key the instance registered and serves with.
keystore_keys() {
  local net="$1" rows name status uuid p key keys="" notes="" var unreadable=0
  case "$net" in testnet|mainnet) : ;; *) echo "usage: $0 keystore-keys <testnet|mainnet>" >&2; return 1 ;; esac
  var="KEEP_$(hostname -s | sed -E 's/^node-tdx-([a-z]+)-[0-9]+$/\1/' | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')"
  rows=$(vmm lsvm 2>/dev/null | sed 's/│/|/g' | awk -F'|' -v pfx="$net-keystore-" '
    { uuid=$2; name=$4; status=$5; gsub(/[[:space:]]/,"",uuid); gsub(/[[:space:]]/,"",name); gsub(/[[:space:]]/,"",status);
      if (index(name, pfx) == 1 && uuid ~ /^[0-9a-f-]{36}$/) print uuid "|" name "|" status }')
  [ -n "$rows" ] || { echo "export $var=\"\""; echo "# no $net keystore CVM on this node"; return 0; }
  while IFS='|' read -r uuid name status; do
    if [ "$status" != running ]; then notes+="# $name: $status — not live, no key"$'\n'; continue; fi
    p=$(agent_port "$uuid")
    [ -n "${p:-}" ] || { notes+="# $name: RUNNING but no agent port — its key could not be read"$'\n'; unreadable=1; continue; }
    # `|| true`: under set -e / pipefail a log without the line (grep exit 1) must not end the loop.
    key=$(curl -s "http://127.0.0.1:$p/logs/dstack-keystore-1?text=true&bare=true&tail=20000" \
      | grep -oE 'Using keystore public key: [a-z0-9-]+:[A-Za-z0-9]+' | tail -1 | sed 's/.*: //' || true)
    if [ -n "$key" ]; then notes+="# $name: $key"$'\n'; keys="${keys:+$keys }$key"; else notes+="# $name: RUNNING but no 'Using keystore public key' line in its log (older keystore, or the line scrolled out) — its key could not be read"$'\n'; unreadable=1; fi
  done <<< "$rows"
  # A running keystore whose key could not be read gets NO export line: the revoke script keeps
  # exactly the keys in KEEP_*, so an export line missing a live key is a line that revokes it.
  # Fail closed — the operator sees which CVM, and takes its key from the DAO proposal or from
  # `worker-ctl.sh follow` before running the revoke.
  if [ "$unreadable" = 1 ]; then
    printf '%s' "$notes" >&2
    echo "# refusing to print export $var: a running $net keystore has no readable key (see above)" >&2
    return 1
  fi
  # The export line first, then the per-CVM notes as shell comments: the whole output can be
  # pasted (or eval'd) as-is.
  echo "export $var=\"$keys\""
  printf '%s' "$notes"
}

case "$cmd" in
  status|ls)  vmm lsvm ;;
  info)       vmm info "$u" ;;
  uuid)       echo "$u" ;;
  port)       p=$(agent_port "$u"); echo "${p:-<no live qemu / not started>}" ;;
  keystore-keys) keystore_keys "${NAME_ARG:-}" ;;
  logs)       p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -s  "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&tail=$TAIL" ;;
  follow|f)   p=$(agent_port "$u"); [ -n "${p:-}" ] || { echo "no agent port (VM not running?)" >&2; exit 1; }
              curl -sN "http://127.0.0.1:$p/logs/$CONTAINER?text=true&bare=true&follow=true&tail=$TAIL" ;;
  serial)     vmm logs -n "$TAIL" "$u" ;;   # qemu serial console (boot/system, not app)
  stop)       stop_vm "$u" ;;
  start)      vmm start "$u" ;;
  restart)    stop_vm "$u" || exit 1; vmm start "$u"; echo "restarted $NAME ($u) — re-run '$0 follow' to watch (port changed)" ;;
  set-image)  img="${1:?usage: $0 set-image <cvm-name> <image>}"
              # The KMS CVM's own key comes from the local key-provider and is bound to its
              # measurements: on another image it cannot open its sealed root key, and every key
              # on the node goes with it (docs/cvm-operations.md). A KMS gets a new image only as
              # a new KMS.
              case "$NAME" in kms|kms-*) echo "worker-ctl: refusing set-image on '$NAME': a KMS CVM must never change image (it would lose its root key); deploy a new KMS instead" >&2; exit 1 ;; esac
              vmm lsimage 2>/dev/null | grep -q "│ $img " \
                || { echo "worker-ctl: image '$img' is not in the vmm's image dir (vmm-cli lsimage; 15-add-os-image.sh adds one)" >&2; exit 1; }
              stop_vm "$u" || exit 1
              vmm resize "$u" --image "$img"
              vmm start "$u"
              echo "$NAME ($u) now boots $img — its measurements changed: approve them before it can register (scripts/deploy_tdx.sh --os-image)" ;;
  remove|rm)  stop_vm "$u" || { echo "worker-ctl: $NAME not removed" >&2; exit 1; }
              vmm remove "$u" && echo "REMOVED $NAME ($u) — CVM + disk deleted (gone from lsvm; not recoverable)" ;;
  *) echo "usage: $0 <status|info|uuid|port|logs|follow|serial|stop|start|restart|remove> [-f] [cvm-name] | set-image <cvm-name> <image> | keystore-keys <testnet|mainnet>" >&2; exit 1 ;;
esac
