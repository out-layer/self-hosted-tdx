#!/usr/bin/env bash
# Loopback guard (lo-guard): only root, outlayer and mpc may open TCP connections to the
# host's CVM control ports on loopback.
#
# Why: the dstack-vmm control APIs (127.0.0.1:11000 outlayer, 127.0.0.1:10000 MPC) have no
# auth. Any local process of any uid can stop or remove a CVM, the mainnet keystore
# included, and a mainnet keystore restart needs a DAO vote. The real fix (vmm auth or a
# unix socket) needs a vmm restart; until then this guard closes those ports to every other
# uid. Containers on docker bridges are unaffected: their traffic never passes the host's
# OUTPUT chain.
#
# CONTROL_PORTS is what the guard covers, in both modes:
#   3001         kms-auth (decides which CVM may boot)
#   9200:9999    the vmm's per-CVM host-port pool: gateway admin, guest agents, keystores
#   10000        the MPC vmm
#   11000:11010  the outlayer vmm, the KMS RPC, its guest agent, the KMS image server
# Everything else on loopback is left alone. In particular the local PCCS (8081), which
# `qgs` (uid qgsd) calls for TDX collateral: closing all of loopback would break quote
# generation for every CVM the first time qgs's collateral cache expires.
#
# Two modes:
#   LO_GUARD_MODE=log     (default) log such connections, block nothing. Run it first, read a
#                          week of `journalctl -k | grep lo-guard`, then switch.
#   LO_GUARD_MODE=reject  refuse them with a TCP reset.
#
# DENIED_USERS (the caged API stack's users, 50-api.sh) are refused ALL host networking, any
# port, any protocol, IPv4 and IPv6, in both modes: nothing they run ever needs the host's
# network namespace, so such a connection can only come from an escape.
#
# The rules live between BEGIN/END markers above the "-o lo -j ACCEPT" line of
# /etc/ufw/before.rules (and of before6.rules for the IPv6 part). Re-running replaces the
# blocks. uids are read from the user names on THIS node: they differ between nodes
# (outlayer is 1000 on dal, 1001 on ams).
#
# Run as root. NON-MUTATING by default: prints the blocks; the kernel judges every rule.
#   sudo ./46-lo-guard.sh                               # dry-run
#   sudo ./46-lo-guard.sh --apply                       # log mode
#   sudo LO_GUARD_MODE=reject ./46-lo-guard.sh --apply  # enforce
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/ufw-safe.sh"

RULES=/etc/ufw/before.rules
RULES6=/etc/ufw/before6.rules
BEGIN="# BEGIN outlayer lo-guard (managed by 46-lo-guard.sh; edit there, not here)"
END="# END outlayer lo-guard"
ANCHOR="-A ufw-before-output -o lo -j ACCEPT"
ANCHOR6="-A ufw6-before-output -o lo -j ACCEPT"
CONTROL_PORTS="3001,9200:9999,10000,11000:11010"
MODE="${LO_GUARD_MODE:-log}"
ALLOWED_USERS=(root outlayer mpc)
DENIED_USERS=(outlayer-api outlayer-api-pg)
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

case "$MODE" in log|reject) ;; *) echo "LO_GUARD_MODE must be log or reject (got '$MODE')" >&2; exit 1 ;; esac
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
for f in "$RULES:$ANCHOR" "$RULES6:$ANCHOR6"; do
  [ -f "${f%%:*}" ] || { echo "${f%%:*} missing: is ufw installed and set up (45-firewall.sh)?" >&2; exit 1; }
  grep -qxF -- "${f#*:}" "${f%%:*}" || { echo "${f%%:*} has no line '${f#*:}'; not touching it" >&2; exit 1; }
done

denied_rules() { # chain
  local user uid
  for user in "${DENIED_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null) || continue
    echo "-A $1 -m owner --uid-owner $uid -m comment --comment $user -j REJECT"
  done
}

block() {
  echo "$BEGIN"
  echo ":lo-guard - [0:0]"
  denied_rules ufw-before-output
  echo "-A ufw-before-output -o lo -p tcp --syn -m multiport --dports $CONTROL_PORTS -j lo-guard"
  local user uid
  for user in "${ALLOWED_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null) || { echo "  (no user '$user' on this node: not allowed)" >&2; continue; }
    echo "-A lo-guard -m owner --uid-owner $uid -m comment --comment $user -j RETURN"
  done
  if [ "$MODE" = log ]; then
    echo '-A lo-guard -m limit --limit 20/min --limit-burst 50 -j LOG --log-prefix "lo-guard " --log-uid'
  else
    echo "-A lo-guard -p tcp -j REJECT --reject-with tcp-reset"
  fi
  echo "$END"
}

block6() {
  echo "$BEGIN"
  denied_rules ufw6-before-output
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
    !inb && $0 !~ /^#/ && /lo-guard/ { print NR": "$0 }' "$f")
  [ -z "$stray" ] || { echo "$f has lo-guard lines outside the managed block; remove them first:" >&2; echo "$stray" >&2; exit 1; }
done

candidate=$(mktemp); candidate6=$(mktemp); trap 'rm -f "$candidate" "$candidate6"' EXIT
new_block=$(block); new_block6=$(block6)
render "$RULES" "$ANCHOR" "$new_block" > "$candidate"
render "$RULES6" "$ANCHOR6" "$new_block6" > "$candidate6"

echo "=== lo-guard, mode: $MODE ==="
echo "$new_block"; echo "--- IPv6:"; echo "$new_block6"; echo
iptables-restore --test -n < "$candidate" && ip6tables-restore --test -n < "$candidate6" && echo "iptables accepts both files"
ufw_rules_kernel_check "$new_block" iptables && ufw_rules_kernel_check "$new_block6" ip6tables \
  && echo "the kernel accepts every rule of both blocks"
# What the kernel must show once the blocks are loaded.
want_rules=$(grep -c '^-A lo-guard' <<<"$new_block" || true)
want_denied6=$(grep -c '^-A ufw6-before-output' <<<"$new_block6" || true)
live_check='[ "$(iptables -S lo-guard 2>/dev/null | grep -c "^-A")" = "'"$want_rules"'" ] && [ "$(ip6tables -S ufw6-before-output 2>/dev/null | grep -c "uid-owner")" = "'"$want_denied6"'" ] && iptables -S ufw-before-output | grep -qF -- "--dports '"$CONTROL_PORTS"' -j lo-guard"'
if diff -q "$RULES" "$candidate" >/dev/null && diff -q "$RULES6" "$candidate6" >/dev/null; then
  if eval "$live_check"; then echo "no change: both files carry these blocks and the kernel has them"; exit 0; fi
  echo "the files carry these blocks but the kernel does not: a reload is due"
else
  echo "--- change:"; diff -u "$RULES" "$candidate" || true; diff -u "$RULES6" "$candidate6" || true
fi

if [ "$APPLY" -eq 0 ]; then
  echo; echo "DRY-RUN: nothing changed. Re-run with --apply."
  exit 0
fi

stamp=$(date +%Y%m%d-%H%M%S)
cp -p "$RULES" "$RULES.bak-$stamp"; cp -p "$RULES6" "$RULES6.bak-$stamp"
cat "$candidate" > "$RULES"; cat "$candidate6" > "$RULES6"
ufw_reload_checked "$live_check" "$RULES:$RULES.bak-$stamp" "$RULES6:$RULES6.bak-$stamp" || exit 1
echo "applied; backups: $RULES.bak-$stamp, $RULES6.bak-$stamp"
echo "=== live ==="; iptables -S lo-guard

# Self-check, on real connections.
tcp() { # uid port → connected|refused
  setpriv --reuid "$1" --regid "$1" --clear-groups bash -c "exec 3<>/dev/tcp/127.0.0.1/$2" 2>/dev/null && echo connected || echo refused
}
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1: $2"; else echo "  FAIL $1: $2, want $3"; fails=$((fails+1)); fi; }
ctl=$(ss -tlnH 'src 127.0.0.1' | awk '{split($4,a,":"); p=a[2]} p==3001||p==10000||(p>=9200&&p<=9999)||(p>=11000&&p<=11010) {print p; exit}')
if [ -n "$ctl" ]; then
  check "nobody → control port $ctl" "$(tcp 65534 "$ctl")" "$([ "$MODE" = log ] && echo connected || echo refused)"
  check "root → control port $ctl" "$(tcp 0 "$ctl")" connected
fi
if ss -tlnH 'src 127.0.0.1' | grep -q '127.0.0.1:8081 '; then
  check "nobody → PCCS 8081 (qgsd's path stays open)" "$(tcp 65534 8081)" connected
  for user in "${DENIED_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null) || continue
    check "$user → PCCS 8081" "$(tcp "$uid" 8081)" refused
  done
fi
[ "$MODE" = log ] && { sleep 1; journalctl -k --since "-1min" -q -o cat | grep "lo-guard " | tail -1; }
[ "$fails" -eq 0 ] || { echo "SELF-CHECK FAILED: restore the backups above and run /lib/ufw/ufw-init force-reload" >&2; exit 1; }
echo "then: open a NEW ssh session before closing this one; outlayer status shows every CVM as before."
