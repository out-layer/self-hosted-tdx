# Sourced by 46-lo-guard.sh and 50-api.sh: put iptables rules into ufw's rules files without
# ever leaving the host half-loaded.
#
# `iptables-restore --test` parses a file without asking the kernel, so a rule the kernel
# refuses (REJECT --reject-with tcp-reset without -p tcp) passes it. `ufw reload` then fails
# halfway: ufw has already flushed its chains, and the host is left with INPUT DROP and no
# loopback or established accept. Every CVM's outbound traffic goes through the host, so that
# cuts them off.

# Load every rule of a managed block into a throwaway network namespace. The kernel judges each
# one as it would on the host; the host is untouched. Non-zero on the first rule it refuses.
ufw_rules_kernel_check() { # block-text [iptables|ip6tables]
  IPT="${2:-iptables}" unshare -n bash -c '
    set -e
    builtin_target() { case "$1" in ACCEPT|DROP|REJECT|RETURN|LOG) return 0;; *) return 1;; esac; }
    while IFS= read -r l; do
      case "$l" in
        :*) c=${l#:}; $IPT -N "${c%% *}" 2>/dev/null || true ;;
        "-A "*)
          set -- $l; $IPT -N "$2" 2>/dev/null || true
          t=$(printf "%s\n" "$l" | grep -oE -- "-j [^ ]+" | cut -c4-)
          builtin_target "$t" || $IPT -N "$t" 2>/dev/null || true
          eval "$IPT $l" || { echo "  the kernel refuses: $l" >&2; exit 1; } ;;
      esac
    done' <<<"$1"
}

# `ufw reload`, then prove the host still accepts loopback and established traffic and that
# `check` (a shell command) holds. On any failure: every file back from its backup, ufw's own
# loader, and a loud message. Usage: ufw_reload_checked "<check>" file:backup [file:backup...]
ufw_reload_checked() {
  local check=$1; shift
  local pair
  if ufw reload \
     && iptables -S ufw-before-input | grep -q -- '-i lo -j ACCEPT' \
     && iptables -S ufw-before-input | grep -q 'RELATED,ESTABLISHED -j ACCEPT' \
     && eval "$check"; then
    return 0
  fi
  echo "!! the reload did not take: restoring the previous rules" >&2
  for pair in "$@"; do cp -p "${pair#*:}" "${pair%%:*}"; done
  /lib/ufw/ufw-init force-reload
  if iptables -S ufw-before-input | grep -q -- '-i lo -j ACCEPT'; then
    echo "!! restored: nothing of this run is live" >&2
  else
    echo "!! STILL BROKEN: run /lib/ufw/ufw-init force-reload and check iptables -S ufw-before-input" >&2
  fi
  return 1
}
