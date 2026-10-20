#!/usr/bin/env bash
# cvm-guard-rearm: insert the jump from ufw's output chain into the cvm-guard chains for the
# cgroup of every vmm service. Installed to /usr/local/sbin/cvm-guard-rearm by 47-cvm-guard.sh
# (its header has the why). The kernel binds a `-m cgroup --path` rule to the cgroup object
# alive when the rule is inserted, and `ufw reload` flushes the chain the jump sits in, so this
# runs at every start of a vmm unit (ExecStartPre drop-in, inside the fresh cgroup), after every
# ufw reload our scripts make (tools/ufw-safe.sh) and from cvm-guard.timer as the backstop.
#
#   cvm-guard-rearm            arm: replace the jumps for every unit in /etc/default/cvm-guard.
#                              Non-zero when a unit that runs could not be armed.
#   cvm-guard-rearm --check    arm only when a jump is missing or stale (the unit has started
#                              since the last arm); silent when nothing is due. For the timer.
set -euo pipefail
CONF=/etc/default/cvm-guard
STATE=/run/cvm-guard.state
UNITS="outlayer-dstack-vmm.service"
[ -f "$CONF" ] && . "$CONF"

chain_of() { [ "$1" = ip6tables ] && echo cvm-guard6 || echo cvm-guard; }
out_of() { [ "$1" = ip6tables ] && echo ufw6-before-output || echo ufw-before-output; }   # ufw's output chain
unit_state() { systemctl show -p ActiveState --value "$1" 2>/dev/null || echo inactive; }
unit_up() { case "$(unit_state "$1")" in active|activating|reloading) return 0 ;; *) return 1 ;; esac; }
invocation() { systemctl show -p InvocationID --value "$1" 2>/dev/null || true; }
jump() { # ipt unit → the jump rule's spec
  echo "-o lo -m cgroup --path system.slice/$2 -m conntrack --ctstate NEW -j $(chain_of "$1")"
}

# `-S` prints `-N chain` first, then the rules in order: rule number = line number - 1.
drop_jumps() { # ipt
  local chain n
  chain=$(chain_of "$1")
  for n in $($1 -S "$(out_of "$1")" | grep -n -- " -j $chain\$" | cut -d: -f1 | sort -rn); do
    $1 -D "$(out_of "$1")" $((n - 1))
  done
}

arm_all() {
  local ipt unit rc=0
  for ipt in iptables ip6tables; do
    $ipt -S "$(chain_of "$ipt")" >/dev/null 2>&1 \
      || { echo "cvm-guard-rearm: $ipt has no chain $(chain_of "$ipt"): ufw is not loaded, or 47-cvm-guard.sh was not applied" >&2; return 1; }
    drop_jumps "$ipt"
  done
  : > "$STATE.new"
  for unit in $UNITS; do
    if ! unit_up "$unit"; then
      echo "cvm-guard-rearm: $unit is $(unit_state "$unit"): nothing to arm"
      continue
    fi
    if [ ! -d "/sys/fs/cgroup/system.slice/$unit" ]; then
      echo "cvm-guard-rearm: $unit is up but has no cgroup system.slice/$unit: NOT armed" >&2
      rc=1; continue
    fi
    for ipt in iptables ip6tables; do
      # shellcheck disable=SC2046
      $ipt -I "$(out_of "$ipt")" 1 $(jump "$ipt" "$unit")
    done
    echo "$unit $(invocation "$unit")" >> "$STATE.new"
    echo "cvm-guard-rearm: armed for system.slice/$unit"
  done
  mv "$STATE.new" "$STATE"
  return $rc
}

check() {
  local unit ipt due=0
  for unit in $UNITS; do
    unit_up "$unit" || continue
    grep -qxF "$unit $(invocation "$unit")" "$STATE" 2>/dev/null || due=1
    for ipt in iptables ip6tables; do
      # shellcheck disable=SC2046
      $ipt -C "$(out_of "$ipt")" $(jump "$ipt" "$unit") 2>/dev/null || due=1
    done
  done
  [ "$due" -eq 0 ] || arm_all
}

[ "$(id -u)" -eq 0 ] || { echo "cvm-guard-rearm: run as root" >&2; exit 1; }
case "${1:-}" in
  "") arm_all ;;
  --check) check ;;
  *) echo "usage: cvm-guard-rearm [--check]" >&2; exit 2 ;;
esac
