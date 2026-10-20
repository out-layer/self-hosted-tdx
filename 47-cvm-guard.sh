#!/usr/bin/env bash
# CVM guard (cvm-guard): a CVM reaches the host only where a CVM has business.
#
# Why: every CVM's network is qemu user-mode (slirp), and the guest's 10.0.2.2 is the host's
# loopback. Code inside ANY CVM therefore reaches every loopback listener of the host: the vmm
# control API (127.0.0.1:11000, no auth — stop or remove any CVM, the mainnet keystore
# included), the gateway admin RPC (127.0.0.1:9203, no auth — DNS credential, ACME, domains),
# the guest-agent of every other CVM (its /logs, and on dstack < 0.5.12 its container config,
# i.e. the env with every token and key) and the KMS guest-agent. 46-lo-guard.sh does not see
# this: qemu runs as outlayer, an allowed user.
#
# What a CVM legitimately reaches on the host's loopback — and nothing else:
#   53      the host resolver (systemd-resolved stub, 127.0.0.53): slirp forwards guest DNS
#   11001   the KMS RPC (kms.1022.dstack.org -> 10.0.2.2): every CVM, at boot and on key refresh
#   3443    the gramine key-provider: the KMS CVM seals its root key through it
#   3001    kms-auth (the boot webhook): the KMS CVM asks it whether an app may boot
#   11008   the KMS image server: the KMS CVM downloads its OS image from it
# Everything else on 127.0.0.0/8 (and ::1) is refused. The CVM control ports (CONTROL_PORTS)
# are refused on the host's other local addresses too, so a listener bound on 0.0.0.0 is not
# reachable through the public IP either. A connection to the host's public IP on any other
# port (443, 9202, the API) is left alone: that is what the WAN reaches anyway, and the
# keystores reach their gateway that way.
#
# How a CVM is told apart from the operator's own tools, both running as outlayer: by cgroup.
# qemu is a child of the vmm's systemd service, so every socket it opens carries the cgroup
# system.slice/outlayer-dstack-vmm.service; vmm-cli, worker-ctl.sh and the deploy scripts run
# from a login session and do not. The vmm itself opens no loopback connection (host API over
# vsock, supervisor over a unix socket, no kms_url in vmm.toml).
#
# Two parts, because the kernel binds a `-m cgroup --path` rule to the cgroup OBJECT alive
# when the rule is inserted: after the vmm service restarts the path names a new cgroup and
# the old rule matches nothing, and a `ufw reload` drops the rule altogether.
#   1. The chains cvm-guard / cvm-guard-deny (and the IPv6 pair) live in ufw's before.rules
#      between BEGIN/END markers. They name no cgroup, so ufw loads them whether or not the
#      vmm runs. Without the jump they are inert.
#   2. The jump into them (-o lo, NEW, the vmm's cgroup) is inserted at run time by
#      /usr/local/sbin/cvm-guard-rearm (tools/cvm-guard-rearm.sh): from the vmm unit's
#      ExecStartPre (a drop-in; it runs inside the fresh cgroup before the vmm starts, and the
#      vmm does NOT start if arming fails), from ufw_reload_checked (tools/ufw-safe.sh) after
#      every reload our scripts make, and from cvm-guard.timer every minute as the backstop
#      (re-arms when a jump is missing or the unit has started since the last arm).
#
# Two modes, like 46-lo-guard.sh:
#   CVM_GUARD_MODE=log     (default) log what would be refused, refuse nothing. Run it first,
#                           cover one boot of every CVM kind (worker, keystore, KMS, gateway),
#                           read `journalctl -k | grep cvm-guard`, then switch.
#   CVM_GUARD_MODE=reject  refuse: tcp-reset for TCP, port-unreachable otherwise; still logged.
#
# CVM_GUARD_UNITS: the vmm services to cover, space-separated (default: the outlayer vmm). On
# the node that also runs the MPC vmm, add its unit once the log shows what its CVM reaches.
# Every qemu outside a listed unit's cgroup is reported: the guard does not cover it.
#
# Nothing restarts: no vmm, no CVM. Run as root. NON-MUTATING by default.
#   sudo ./47-cvm-guard.sh                                # dry-run
#   sudo ./47-cvm-guard.sh --apply                        # log mode
#   sudo CVM_GUARD_MODE=reject ./47-cvm-guard.sh --apply  # enforce
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/ufw-safe.sh"

RULES=/etc/ufw/before.rules
RULES6=/etc/ufw/before6.rules
BEGIN="# BEGIN outlayer cvm-guard (managed by 47-cvm-guard.sh; edit there, not here)"
END="# END outlayer cvm-guard"
ANCHOR="-A ufw-before-output -o lo -j ACCEPT"
ANCHOR6="-A ufw6-before-output -o lo -j ACCEPT"
MODE="${CVM_GUARD_MODE:-log}"
UNITS="${CVM_GUARD_UNITS:-outlayer-dstack-vmm.service}"
LO_ALLOW_TCP="3001,3443,11001,11008"                 # the loopback services of the header
# 46-lo-guard.sh's set minus LO_ALLOW_TCP and minus 9202: the gateway RPC/WireGuard port, WAN-open
# (45-firewall.sh), and the keystores reach it through the host's public IP (seen in log mode).
CONTROL_PORTS="9200:9201,9203:9999,10000,11000,11002:11007,11009:11010"
REARM=/usr/local/sbin/cvm-guard-rearm
CONF=/etc/default/cvm-guard
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

case "$MODE" in log|reject) ;; *) echo "CVM_GUARD_MODE must be log or reject (got '$MODE')" >&2; exit 1 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
for f in "$RULES:$ANCHOR" "$RULES6:$ANCHOR6"; do
  [ -f "${f%%:*}" ] || { echo "${f%%:*} missing: is ufw installed and set up (45-firewall.sh)?" >&2; exit 1; }
  grep -qxF -- "${f#*:}" "${f%%:*}" || { echo "${f%%:*} has no line '${f#*:}'; not touching it" >&2; exit 1; }
done

deny_rules() { # chain
  echo "-A $1 -m limit --limit 20/min --limit-burst 50 -j LOG --log-prefix \"cvm-guard \" --log-uid"
  if [ "$MODE" = reject ]; then
    echo "-A $1 -p tcp -j REJECT --reject-with tcp-reset"
    echo "-A $1 -j REJECT"
  fi
}

block() {
  echo "$BEGIN"
  echo ":cvm-guard - [0:0]"
  echo ":cvm-guard-deny - [0:0]"
  echo "-A cvm-guard -p udp --dport 53 -j RETURN"
  echo "-A cvm-guard -p tcp --dport 53 -j RETURN"
  echo "-A cvm-guard -d 127.0.0.0/8 -p tcp -m multiport --dports $LO_ALLOW_TCP -j RETURN"
  echo "-A cvm-guard -d 127.0.0.0/8 -j cvm-guard-deny"
  echo "-A cvm-guard ! -d 127.0.0.0/8 -p tcp -m multiport --dports $CONTROL_PORTS -j cvm-guard-deny"
  deny_rules cvm-guard-deny
  echo "$END"
}

block6() {
  echo "$BEGIN"
  echo ":cvm-guard6 - [0:0]"
  echo ":cvm-guard6-deny - [0:0]"
  echo "-A cvm-guard6 -p udp --dport 53 -j RETURN"
  echo "-A cvm-guard6 -p tcp --dport 53 -j RETURN"
  echo "-A cvm-guard6 -d ::1/128 -j cvm-guard6-deny"
  echo "-A cvm-guard6 ! -d ::1/128 -p tcp -m multiport --dports $CONTROL_PORTS -j cvm-guard6-deny"
  deny_rules cvm-guard6-deny
  echo "$END"
}

# file anchor block → the file without our block, with a fresh one above the anchor
render() {
  awk -v begin="$BEGIN" -v end="$END" -v anchor="$2" -v blk="$3" '
    $0 == begin { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    skip { next }
    $0 == anchor && !done { print blk; done = 1 }
    { print }
  ' "$1"
}

for f in "$RULES" "$RULES6"; do
  stray=$(awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { inb = 1; next }  $0 == end { inb = 0; next }
    !inb && $0 !~ /^#/ && /cvm-guard/ { print NR": "$0 }' "$f")
  [ -z "$stray" ] || { echo "$f has cvm-guard lines outside the managed block; remove them first:" >&2; echo "$stray" >&2; exit 1; }
done

echo "=== cvm-guard, mode: $MODE, units: $UNITS ==="
echo "--- the vmm services and their qemus:"
covered=0
for unit in $UNITS; do
  state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo inactive)
  cg=/sys/fs/cgroup/system.slice/$unit
  n=0; [ -f "$cg/cgroup.procs" ] && n=$(while read -r p; do cat "/proc/$p/comm" 2>/dev/null; done < "$cg/cgroup.procs" | grep -c '^qemu' || true)
  echo "  $unit: $state, $n qemu in its cgroup"
  [ "$state" = active ] && covered=1
done
foreign=0
for pid in $(pgrep -x qemu-system-x86 || true); do   # comm is 15 chars: qemu-system-x86_64 truncates to this
  cgp=$(sed -n 's/^0::\(.*\)$/\1/p' "/proc/$pid/cgroup" 2>/dev/null || true)
  ok=0; for unit in $UNITS; do [ "$cgp" = "/system.slice/$unit" ] && ok=1; done
  [ "$ok" -eq 1 ] || { echo "  !! qemu pid $pid runs in '$cgp': NOT covered. Its unit belongs in CVM_GUARD_UNITS." >&2; foreign=1; }
done
[ "$foreign" -eq 0 ] && echo "  every qemu on this host is in a listed unit's cgroup"
echo

candidate=$(mktemp); candidate6=$(mktemp); trap 'rm -f "$candidate" "$candidate6"' EXIT
new_block=$(block); new_block6=$(block6)
render "$RULES" "$ANCHOR" "$new_block" > "$candidate"
render "$RULES6" "$ANCHOR6" "$new_block6" > "$candidate6"

echo "$new_block"; echo "--- IPv6:"; echo "$new_block6"; echo
iptables-restore --test -n < "$candidate" && ip6tables-restore --test -n < "$candidate6" && echo "iptables accepts both files"
ufw_rules_kernel_check "$new_block" iptables && ufw_rules_kernel_check "$new_block6" ip6tables \
  && echo "the kernel accepts every rule of both blocks"
# The run-time jump, judged by the kernel in a throwaway namespace (the cgroup path is the
# host's; only an existing cgroup can be named).
for unit in $UNITS; do
  [ -d "/sys/fs/cgroup/system.slice/$unit" ] || continue
  unshare -n iptables -A OUTPUT -o lo -m cgroup --path "system.slice/$unit" -m conntrack --ctstate NEW -j RETURN \
    && unshare -n ip6tables -A OUTPUT -o lo -m cgroup --path "system.slice/$unit" -m conntrack --ctstate NEW -j RETURN \
    && echo "the kernel accepts the cgroup jump for $unit" \
    || { echo "the kernel refuses a cgroup jump for $unit (xt_cgroup with cgroup2 paths is needed)" >&2; exit 1; }
done

want_rules=$(grep -c '^-A cvm-guard ' <<<"$new_block" || true)
want_rules6=$(grep -c '^-A cvm-guard6 ' <<<"$new_block6" || true)
live_check='[ "$(iptables -S cvm-guard 2>/dev/null | grep -c "^-A")" = "'"$want_rules"'" ] && [ "$(ip6tables -S cvm-guard6 2>/dev/null | grep -c "^-A")" = "'"$want_rules6"'" ]'
armed_check='for u in '"$UNITS"'; do systemctl -q is-active "$u" || continue; iptables -S ufw-before-output | grep -q -- "--path .\?system.slice/$u.\? .*-j cvm-guard$" || exit 1; done'
if diff -q "$RULES" "$candidate" >/dev/null && diff -q "$RULES6" "$candidate6" >/dev/null; then
  if eval "$live_check" && bash -c "$armed_check" && [ -x "$REARM" ] && cmp -s "$HERE/tools/cvm-guard-rearm.sh" "$REARM"; then
    echo "no change: both files carry these blocks, the kernel has them, and the jump is armed"; exit 0
  fi
  echo "the files carry these blocks but the live state differs (chains, jump or helper): an apply is due"
else
  echo "--- change:"; diff -u "$RULES" "$candidate" || true; diff -u "$RULES6" "$candidate6" || true
fi

if [ "$APPLY" -eq 0 ]; then
  echo; echo "DRY-RUN: nothing changed. Re-run with --apply."
  exit 0
fi
[ "$covered" -eq 1 ] || { echo "no listed unit is active: nothing to arm, not applying" >&2; exit 1; }

echo "=== install the re-arm helper, its config, the vmm drop-ins and the backstop timer ==="
install -m 755 "$HERE/tools/cvm-guard-rearm.sh" "$REARM"
printf '# Managed by 47-cvm-guard.sh: the vmm services whose cgroups the CVM guard covers.\nUNITS="%s"\n' "$UNITS" > "$CONF"
for unit in $UNITS; do
  mkdir -p "/etc/systemd/system/$unit.d"
  cat > "/etc/systemd/system/$unit.d/cvm-guard.conf" <<UNIT
# Managed by 47-cvm-guard.sh: arm the CVM guard inside this unit's fresh cgroup before the vmm
# starts. '+' runs it as root. No '-' on purpose: the vmm does not start unarmed.
[Unit]
After=ufw.service
[Service]
ExecStartPre=+$REARM
UNIT
done
cat > /etc/systemd/system/cvm-guard.service <<UNIT
[Unit]
Description=CVM guard: re-arm the cgroup jump when it is missing or stale (47-cvm-guard.sh)
[Service]
Type=oneshot
ExecStart=$REARM --check
UNIT
cat > /etc/systemd/system/cvm-guard.timer <<UNIT
[Unit]
Description=CVM guard backstop, every minute (47-cvm-guard.sh)
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload

stamp=$(date +%Y%m%d-%H%M%S)
cp -p "$RULES" "$RULES.bak-$stamp"; cp -p "$RULES6" "$RULES6.bak-$stamp"
cat "$candidate" > "$RULES"; cat "$candidate6" > "$RULES6"
ufw_reload_checked "$live_check" "$RULES:$RULES.bak-$stamp" "$RULES6:$RULES6.bak-$stamp" || exit 1
"$REARM" || { echo "!! the chains are loaded but the jump is not armed: read the message above" >&2; exit 1; }
systemctl enable --now cvm-guard.timer >/dev/null
echo "applied; backups: $RULES.bak-$stamp, $RULES6.bak-$stamp"
echo "=== live ==="; iptables -S ufw-before-output | grep -- '-j cvm-guard$'; iptables -S cvm-guard; iptables -S cvm-guard-deny

# Self-check, on real connections: a shell moved into the vmm's cgroup is, to the kernel, a
# CVM; the same shell outside it is the operator.
unit=$(for u in $UNITS; do systemctl -q is-active "$u" && { echo "$u"; break; }; done)
cgprocs=/sys/fs/cgroup/system.slice/$unit/cgroup.procs
as_cvm() { ( echo $BASHPID > "$cgprocs" && exec 3<>"/dev/tcp/$1/$2" ) 2>/dev/null && echo connected || echo refused; }
as_op()  { ( exec 3<>"/dev/tcp/$1/$2" ) 2>/dev/null && echo connected || echo refused; }
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1: $2"; else echo "  FAIL $1: $2, want $3"; fails=$((fails+1)); fi; }
listens() { ss -tlnH "sport = :$1" | grep -q .; }
deny_want=$([ "$MODE" = log ] && echo connected || echo refused)
echo "=== self-check (as $unit's cgroup = a CVM; outside it = the operator) ==="
if listens 11000; then
  check "CVM → vmm 127.0.0.1:11000" "$(as_cvm 127.0.0.1 11000)" "$deny_want"
  check "operator → vmm 127.0.0.1:11000" "$(as_op 127.0.0.1 11000)" connected
fi
listens 11001 && check "CVM → KMS 127.0.0.1:11001 (allowed)" "$(as_cvm 127.0.0.1 11001)" connected
listens 3443  && check "CVM → key-provider 127.0.0.1:3443 (allowed)" "$(as_cvm 127.0.0.1 3443)" connected
ss -tlnH 'src 127.0.0.53' | grep -q ':53 ' && check "CVM → resolver 127.0.0.53:53 (allowed)" "$(as_cvm 127.0.0.53 53)" connected
agent=$(ss -tlnH 'src 127.0.0.1' | awk '{split($4,a,":"); p=a[2]} p>=9200&&p<=9999 {print p; exit}')
[ -n "$agent" ] && check "CVM → a guest-agent/admin port 127.0.0.1:$agent" "$(as_cvm 127.0.0.1 "$agent")" "$deny_want"
sleep 1; echo "  last kernel log line:"; journalctl -k --since "-1min" -q -o cat | grep "cvm-guard " | tail -1 | sed 's/^/    /'
[ "$fails" -eq 0 ] || { echo "SELF-CHECK FAILED: restore the backups above, run /lib/ufw/ufw-init force-reload, then $REARM" >&2; exit 1; }
[ "$MODE" = log ] && echo "log mode: nothing is refused. Watch: journalctl -k -f | grep cvm-guard  (a CVM boot shows 11001; the KMS CVM's boot shows 3001 and 11008)"
echo "re-arm status any time: $REARM --check; systemctl list-timers cvm-guard.timer"
