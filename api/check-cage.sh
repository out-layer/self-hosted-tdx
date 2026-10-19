#!/usr/bin/env bash
# Prove the API stack's cage on this node: read-only, changes nothing. Run as root after
# `outlayer-<net>-api up`: `check-cage.sh testnet`. Every row prints PASS or FAIL; the exit code is the number of FAILs.
# The one check that must run from outside (31443 admits Cloudflare only) is printed last
# as a command for another machine.
set -uo pipefail
NET="${1:?usage: $0 <testnet|mainnet>}"
API_HOME="/opt/outlayer-$NET-api"
set -a; . "$API_HOME/compose.env"; set +a
P="outlayer-$NET-api"
fails=0
row() { if [ "$2" = "$3" ]; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s: got %s, want %s\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
cid() { docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=$1"; }
# A TCP connect from inside a container (busybox nc): open | closed
reach() { docker exec "$(cid "$1")" sh -c "nc -z -w 3 $2 $3 >/dev/null 2>&1" && echo open || echo closed; }

echo "== the containers"
for s in postgres redis coordinator nginx; do
  c=$(cid "$s"); [ -n "$c" ] || { row "$s running" no yes; continue; }
  want_user=$([ "$s" = postgres ] && echo 70:70 || echo 2100:2100)
  row "$s user" "$(docker inspect -f '{{.Config.User}}' "$c")" "$want_user"
  row "$s cap_drop" "$(docker inspect -f '{{.HostConfig.CapDrop}}' "$c")" "[ALL]"
  row "$s read-only root" "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c")" true
  row "$s no-new-privileges" "$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$c" | grep -c no-new-privileges)" 1
  row "$s not privileged" "$(docker inspect -f '{{.HostConfig.Privileged}}' "$c")" false
  row "$s network mode" "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" | grep -c '^host$')" 0
  row "$s no docker socket" "$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$c" | grep -c docker.sock)" 0
  row "$s host uids" "$(docker top "$c" -o pid,uid | tail -n +2 | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')" "${want_user%%:*}"
done

echo "== from inside"
row "coordinator → its own 127.0.0.1:11000 (the host's vmm is not there)" "$(reach coordinator 127.0.0.1 11000)" closed
gw="${API_SUBNET_EDGE%.*}.1"
for port in 11001 3001 11008 9202 22 24567 8081 3443; do
  row "coordinator → host $gw:$port" "$(reach coordinator "$gw" "$port")" closed
  row "coordinator → host $API_PUBLIC_IP:$port" "$(reach coordinator "$API_PUBLIC_IP" "$port")" closed
done
row "coordinator → host $API_PUBLIC_IP:443 (the gateway, for the keystores)" "$(reach coordinator "$API_PUBLIC_IP" 443)" open
# The private network's gateway, as the routing table names it (a real neighbour, not a guess).
priv=$(ip -4 route | awk '$1 ~ /^10\./ && / via / {for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}')
[ -n "$priv" ] && row "coordinator → private neighbour $priv:22" "$(reach coordinator "$priv" 22)" closed
row "coordinator → 169.254.169.254:80" "$(reach coordinator 169.254.169.254 80)" closed
row "coordinator → the internet (1.1.1.1:443)" "$(reach coordinator 1.1.1.1 443)" open
row "postgres → the internet (db network is internal)" "$(reach postgres 1.1.1.1 443)" closed
db_gw="${API_SUBNET_DB%.*}.1"
row "redis without its password" "$(docker exec "$(cid redis)" redis-cli ping 2>&1 | grep -c NOAUTH)" 1

row "postgres → the host ($db_gw:443; the db network never reaches it)" "$(reach postgres "$db_gw" 443)" closed

echo "== the host's own processes (only root opens connections into the API's networks)"
asu() { setpriv --reuid "$1" --regid "$1" --clear-groups timeout 4 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null && echo open || echo closed; }
row "nobody → coordinator $API_COORDINATOR_IP:8080 past nginx" "$(asu 65534 "$API_COORDINATOR_IP" 8080)" closed
row "outlayer (the CVMs' qemu) → coordinator past nginx" "$(asu "$(id -u outlayer)" "$API_COORDINATOR_IP" 8080)" closed
row "root → coordinator (operations)" "$(asu 0 "$API_COORDINATOR_IP" 8080)" open

echo "== the default bridge (image builds, the deploy's cargo update)"
pg_image=$(docker inspect -f '{{.Config.Image}}' "$(cid postgres)")
onbridge() { docker run --rm --network bridge --entrypoint sh "$pg_image" -c "nc -z -w 3 $1 $2 >/dev/null 2>&1 && echo open || echo closed" 2>/dev/null; }
[ -n "$priv" ] && row "default bridge → private neighbour $priv:22" "$(onbridge "$priv" 22)" closed
row "default bridge → host 172.17.0.1:22" "$(onbridge 172.17.0.1 22)" closed
row "default bridge → the internet (1.1.1.1:443)" "$(onbridge 1.1.1.1 443)" open

echo "== the firewall as loaded"
priv_if=$(ip -4 -o addr | awk '$4 ~ /^10\./ {print $2; exit}')
api_nets="${API_SUBNET_EDGE%.*}.0/23"
[ -n "$priv_if" ] && row "API networks dropped on the private interface ($priv_if)" "$(iptables -S DOCKER-USER | grep -c -- "-s $api_nets -o $priv_if -j DROP")" 1
[ -n "$priv_if" ] && row "default bridge dropped on the private interface" "$(iptables -S DOCKER-USER | grep -c -- "-s 172.17.0.0/16 -o $priv_if -j DROP")" 1
for n in $(sed -n 's/^# BEGIN \(outlayer-[a-z]*-api\) docker-user .*/\1/p' /etc/ufw/after.rules); do
  row "$n: Cloudflare-only rule live" "$(iptables -S DOCKER-USER | grep -c -- "-j $n-cf")" 1
done
row "DOCKER-USER declared once in after.rules" "$(grep -c '^:DOCKER-USER' /etc/ufw/after.rules)" 1

echo "== the origin (Authenticated Origin Pulls with our certificate)"
host=$(sed -n 's/^ *server_name \([a-z0-9.-]*\);.*/\1/p' "$API_HOME/nginx/nginx.conf" | head -1)
code=$(curl -sk -m 8 --resolve "$host:$API_PORT:$API_PUBLIC_IP" "https://$host:$API_PORT/health" -o /dev/null -w '%{http_code}')
row "$host straight to the origin without the client certificate" "$code" 400

echo "== the users on the host"
try2() { setpriv --reuid "$1" --regid "$1" --clear-groups timeout 4 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null && echo open || echo refused; }
try() { setpriv --reuid "$1" --regid "$1" --clear-groups bash -c "exec 3<>/dev/tcp/127.0.0.1/11000" 2>/dev/null && echo open || echo refused; }
row "uid 2100 → host 127.0.0.1:11000 (vmm)" "$(try 2100)" refused
row "uid 70 → host 127.0.0.1:11000 (vmm)" "$(try 70)" refused
kp=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gramine-sealing-key-provider 2>/dev/null)
[ -n "$kp" ] && row "uid 2100 → the key provider $kp:3443 (not on loopback)" "$(try2 2100 "$kp" 3443)" refused
row "uid 2100 → [::1]:22 (IPv6)" "$(setpriv --reuid 2100 --regid 2100 --clear-groups timeout 4 bash -c "exec 3<>/dev/tcp/::1/22" 2>/dev/null && echo open || echo refused)" refused
for d in /home/outlayer /home/mpc; do
  row "uid 2100 reads $d" "$(setpriv --reuid 2100 --regid 2100 --clear-groups ls "$d" >/dev/null 2>&1 && echo yes || echo no)" no
done

echo "== the data image"
row "data mounted (nodev,nosuid,noexec)" "$(findmnt -no OPTIONS "$API_HOME/data" | tr ',' '\n' | grep -cxE 'nodev|nosuid|noexec')" 3

echo
echo "From a machine outside Cloudflare (e.g. the Mac), expect a timeout:"
echo "  curl -m 8 -sk https://$API_PUBLIC_IP:$API_PORT/health; echo rc=\$?   # rc=28"
echo
[ "$fails" -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit "$fails"
