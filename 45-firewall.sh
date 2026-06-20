#!/usr/bin/env bash
# Host firewall (ufw) for the self-hosted TDX node (node-tdx-dal-2, 173.237.9.76).
# Default-deny incoming + an explicit allow-list of the ports OutLayer, the NEAR
# MPC node, and the dstack stack actually need from the WAN. Outgoing stays open.
#
# Run as root. NON-MUTATING by default: prints the exact ufw plan and exits.
# Pass --apply to actually configure + enable ufw.
#   sudo ./45-firewall.sh            # dry-run, prints the plan
#   sudo ./45-firewall.sh --apply    # configure rules, default-deny, enable ufw
#
# WHY THIS IS SAFE (verified live on the node, 2026-06-20):
#  - CVMs use qemu user-mode networking (slirp). A CVM reaching a host service
#    (e.g. the gramine key-provider at 10.0.2.2:3443) is the qemu PROCESS opening
#    an outbound connection; slirp maps 10.0.2.2 -> host loopback, so that traffic
#    arrives on `lo`, NEVER on the WAN iface `agge`. ufw's default-deny-incoming
#    does NOT touch loopback, so CVM<->host (key-provider, etc.) keeps working.
#  - All on-host CVMs fetch their root key from the EXTERNAL KMS
#    (kms.1022.dstack.org:11001, per every CVM's .sys-config.json), via OUTBOUND
#    WAN -> covered by `default allow outgoing`. They do NOT use host:11001.
#  - Workers are outbound-only (verified: worker CVM qemu has only ESTAB to the
#    coordinator on :443, no inbound). The gateway (443 + 9202) and, behind it over
#    WireGuard, the keystore are the only WAN-inbound OutLayer services.
#  - slirp does NOT use the host FORWARD chain (NAT happens inside qemu), so the
#    FORWARD policy is irrelevant to CVMs. Docker keeps its own FORWARD rules and
#    ip_forward=1; ufw does not remove those. We leave DEFAULT_FORWARD_POLICY alone.
#
# This REPLACES the current manual approach (interface-scoped iptables DROPs on
# agge for 11001/11008/3001, persisted in /etc/iptables/rules.v4) with a clean
# default-deny + allow-list. ufw appends to the same iptables; the legacy DROP
# rules remain harmless (denied ports are denied either way).
set -euo pipefail

WAN_IF="agge"                 # WAN interface (173.237.9.76/29, default route)
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# ---------------------------------------------------------------------------
# Allow-list: port/proto | comment.  KEEP OPEN (genuinely WAN-inbound).
# ---------------------------------------------------------------------------
# Format: "<port>/<proto>|<ufw comment>"
ALLOW=(
  "22/tcp|SSH (sshd) - FIRST, never lock out"
  # --- NEAR MPC node CVM (mpc vmm cid 30001) — keep ALL NEAR node ports ---
  "24567/tcp|NEAR MPC node P2P (live WAN peers observed)"
  "24567/udp|NEAR MPC node P2P (QUIC) - keep with the tcp peer port"
  "80/tcp|NEAR MPC node CVM hostfwd :80 (ACME/web) - WAN-forwarded by mpc node qemu"
  "8079/tcp|NEAR MPC node CVM hostfwd :8079 - keep (NEAR node port, purpose unconfirmed)"
  "8989/tcp|NEAR MPC node CVM hostfwd :8989->guest:8080 - keep (NEAR node port)"
  # --- dstack-gateway CVM (outlayer vmm cid 40003) — only WAN-inbound OutLayer svc ---
  "443/tcp|dstack-gateway HTTPS (TLS-in-TEE; proxies to keystore over WireGuard)"
  "9202/tcp|dstack-gateway control/RA-TLS (hostfwd :9202->guest:8000)"
  "9202/udp|dstack-gateway WireGuard (hostfwd udp :9202->guest:51820)"
)

# ---------------------------------------------------------------------------
# Deny-list (NOT opened): documented here as evidence; default-deny covers them.
# These are slirp/loopback-only or internal — confirmed not WAN-needed:
#   11001/tcp  local KMS CVM RA-TLS. On-host CVMs use EXTERNAL kms.1022.dstack.org,
#              not host:11001. Already DROP'd on agge today; node ran 2d22h fine.
#   11008/tcp  python http.server (KMS image-download imgsrv). Already DROP'd on agge.
#   3001/tcp   KMS auth-simple (bun, kms/auth-simple). Already DROP'd on agge.
#   3030/tcp   NEAR-style RPC, bound 127.0.0.1 (loopback hostfwd) — not WAN-reachable.
#   10000/11000 dstack-vmm RPC, bound 127.0.0.1 — loopback only.
#   8081/tcp   host PCCS (pccs_server.js), bound 127.0.0.1 — loopback only.
#   3443/tcp   gramine key-provider, bound 127.0.0.1 (docker-proxy) — CVMs reach via
#              slirp 10.0.2.2:3443 -> host lo; never WAN.
#   9203/9206/9208/9209/9210/9211/9213/11005 guest-agent/admin hostfwds, bound
#              127.0.0.1 — loopback only.
#   9210-9999  per-CVM host-port pool that 40-deploy-worker.sh / 40-deploy-keystore.sh allocate
#              (guest-agent :8090 + keystore :8081 smoke-test) — ALL bound 127.0.0.1, loopback,
#              never WAN. NOT opened (ufw always allows lo). Keep the range free of other HOST
#              listeners (a port-allocation concern, not a firewall one).
# ---------------------------------------------------------------------------

run() {  # echo every command; only execute under --apply
  echo "  + $*"
  [ "$APPLY" -eq 1 ] && "$@"
}

echo "=== TDX host firewall plan (ufw) — WAN iface: $WAN_IF ==="
if [ "$APPLY" -eq 0 ]; then
  echo "    DRY-RUN (no changes). Re-run with --apply to enable."
else
  command -v ufw >/dev/null || { echo "ufw not installed: apt-get install -y ufw"; exit 1; }
fi
echo

echo "[1/4] Allow SSH FIRST (so --apply can never lock you out):"
run ufw allow 22/tcp comment "SSH (sshd) - FIRST, never lock out"
echo

echo "[2/4] Allow-list (WAN-inbound services):"
for entry in "${ALLOW[@]}"; do
  rule="${entry%%|*}"
  comment="${entry##*|}"
  [ "$rule" = "22/tcp" ] && continue   # already added in step 1
  run ufw allow "$rule" comment "$comment"
done
echo

echo "[3/4] Default policies (incoming deny, outgoing allow; FORWARD untouched):"
run ufw default deny incoming
run ufw default allow outgoing
# NOTE: we deliberately do NOT set 'ufw default <x> routed' / DEFAULT_FORWARD_POLICY.
# Docker manages its own FORWARD rules and ip_forward=1; slirp doesn't use FORWARD.
echo

echo "[4/4] Enable ufw:"
if [ "$APPLY" -eq 1 ]; then
  ufw --force enable
  echo
  echo "=== ufw status ==="
  ufw status verbose
else
  echo "  + ufw --force enable"
  echo
  echo "DRY-RUN complete. Nothing changed. Run: sudo $0 --apply"
fi

cat <<'EOF'

--- POST-ENABLE VERIFICATION (run after --apply) -------------------------------
From OFF-HOST (your laptop):
  1. SSH still works:                ssh root@173.237.9.76 'echo ok'
  2. Gateway HTTPS reachable:        curl -sk https://173.237.9.76:443/ -o /dev/null -w '%{http_code}\n'
  3. Keystore served via gateway:    curl -sk https://<app-id>-8081.dstack.outlayer.ai/ -o /dev/null -w '%{http_code}\n'
  4. NEAR P2P open:                  nc -vz 173.237.9.76 24567
  5. Denied ports CLOSED (expect timeout/refused, NOT a banner):
        for p in 11001 11008 3001 3030; do nc -vz -w3 173.237.9.76 $p; done

On the HOST:
  6. CVMs still running:             cd /home/outlayer/meta-dstack/build && curl -s 127.0.0.1:11000/ | head -c1
  7. A CVM still reaches its KMS (outbound) — restart one CVM and confirm it boots:
        check serial.log of a CVM under build/run/vm/<uuid>/serial.log for 'kms' bootstrap OK
  8. ufw allow-list correct:         ufw status verbose

--- ROLLBACK ------------------------------------------------------------------
  sudo ufw disable          # drops ufw rules immediately; host returns to prior state
  # (the legacy /etc/iptables/rules.v4 agge-DROPs for 11001/11008/3001 remain in place)
EOF
