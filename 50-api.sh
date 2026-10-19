#!/usr/bin/env bash
# Install the caged OutLayer API stack (api/compose.yaml) for one network on this TDX node.
# What and why: api/README.md. It never copies a secret and never starts the stack; it
# prepares everything around them and reports what is still missing.
#
# Run as root from the synced tree (/home/outlayer/self-hosted-tdx). NON-MUTATING by default.
#   sudo ./50-api.sh testnet            # dry-run: the plan and what is missing
#   sudo ./50-api.sh testnet --apply    # do it
#
# Steps, each skipped when already done:
#   1. users outlayer-api (2100) and outlayer-api-pg (70): no login, no home, no groups
#   2. a fixed-size data image at /var/lib/outlayer-<net>-api.img, mounted on $API_HOME/data
#      (loop,nodev,nosuid,noexec,nofail in fstab)
#   3. the tree under $API_HOME, data dirs owned by the service uids
#   4. compose.yaml, compose.env (+ this node's public IPv4), nginx.conf copied in
#   5. the source checkout $API_HOME/src (needs the read-only deploy key, host github-coordinator)
#   6. firewall: the API subnets reach the host on 443 only, nothing private; 31443 from
#      Cloudflare only (managed blocks in /etc/ufw/before.rules and after.rules)
#   7. /usr/local/bin/outlayer-<net>-api
# Then 46-lo-guard.sh must be re-run: it denies loopback to the two users.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NET="${1:?usage: $0 <testnet|mainnet> [--apply]}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
SETTINGS="$HERE/api/$NET.env"
[ -f "$SETTINGS" ] || { echo "no $SETTINGS" >&2; exit 1; }
NGINX_CONF="$HERE/api/nginx-$NET.conf"
[ -f "$NGINX_CONF" ] || { echo "no $NGINX_CONF" >&2; exit 1; }
set -a; . "$SETTINGS"; set +a
. "$HERE/tools/ufw-safe.sh"
IMG="/var/lib/outlayer-$NET-api.img"
REPO="git@github-coordinator:out-layer/coordinator.git"
CF_V4="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
# The API's two subnets as one /23 (edge + db).
API_NETS="${API_SUBNET_EDGE%.*}.0/23"
PUBLIC_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
[ -n "$PUBLIC_IP" ] || { echo "cannot read this node's public IPv4" >&2; exit 1; }

missing=()
step() { echo; echo "== $*"; }

# Before anything is changed: the source checkout needs the read-only deploy key. Without it the
# clone in step 5 would fail with steps 1-4 done and the firewall (6) not yet.
if [ ! -d "$API_HOME/src/.git" ] && ! git ls-remote "$REPO" HEAD >/dev/null 2>&1; then
  echo "no read access to $REPO: put the deploy key in place first (api/README.md, Installing)" >&2; exit 1
fi
run()  { echo "  + $*"; if [ "$APPLY" -eq 1 ]; then "$@"; fi; }

step "1. users"
ensure_user() { # name uid
  if id -u "$1" >/dev/null 2>&1; then
    [ "$(id -u "$1")" = "$2" ] || { echo "  $1 exists with uid $(id -u "$1"), want $2" >&2; exit 1; }
    echo "  $1 ($2): present"
  else
    getent passwd "$2" >/dev/null && { echo "  uid $2 is taken by $(getent passwd "$2" | cut -d: -f1)" >&2; exit 1; }
    run groupadd -g "$2" "$1"
    run useradd -r -u "$2" -g "$2" -M -d /nonexistent -s /usr/sbin/nologin "$1"
  fi
}
ensure_user outlayer-api 2100
ensure_user outlayer-api-pg 70

step "2. data image $IMG ($API_DATA_SIZE) on $API_HOME/data"
if [ -f "$IMG" ]; then echo "  image: present"; else
  run fallocate -l "$API_DATA_SIZE" "$IMG"
  run chmod 600 "$IMG"
  run mkfs.ext4 -q -m 0 "$IMG"
fi
FSTAB_LINE="$IMG $API_HOME/data ext4 loop,nodev,nosuid,noexec,nofail 0 2"
if grep -qF "$IMG " /etc/fstab; then echo "  fstab: present"; else
  echo "  + echo '$FSTAB_LINE' >> /etc/fstab"; [ "$APPLY" -eq 1 ] && echo "$FSTAB_LINE" >> /etc/fstab
fi
run mkdir -p "$API_HOME/data"
if findmnt -n "$API_HOME/data" >/dev/null; then echo "  mounted"; else run mount "$API_HOME/data"; fi

step "3. tree"
run chmod 755 "$API_HOME"
run install -d -m 755 -o root -g root "$API_HOME/secrets" "$API_HOME/nginx"
run install -d -m 750 -o root -g 2100 "$API_HOME/nginx/certs"
if [ "$APPLY" -eq 1 ] && ! findmnt -n "$API_HOME/data" >/dev/null; then
  echo "  $API_HOME/data is not mounted; not creating data dirs on /" >&2; exit 1
fi
run install -d -m 700 -o 70 -g 70 "$API_HOME/data/postgres"
run install -d -m 700 -o 2100 -g 2100 "$API_HOME/data/redis" "$API_HOME/data/wasm"

step "4. compose files"
put() { # src dst mode owner:group
  if [ -f "$2" ] && cmp -s "$1" "$2"; then echo "  $2: up to date"; return; fi
  if [ -f "$2" ]; then diff -u "$2" "$1" | sed 's/^/    /' | head -40 || true; fi
  run install -m "$3" -o "${4%:*}" -g "${4#*:}" "$1" "$2"
}
compose_env=$(mktemp); trap 'rm -f "$compose_env"' EXIT
{ cat "$SETTINGS"; echo "API_PUBLIC_IP=$PUBLIC_IP"; } > "$compose_env"
put "$HERE/api/compose.yaml" "$API_HOME/compose.yaml" 644 root:root
put "$compose_env" "$API_HOME/compose.env" 644 root:root
put "$NGINX_CONF" "$API_HOME/nginx/nginx.conf" 640 root:2100

step "5. source checkout $API_HOME/src"
if [ -d "$API_HOME/src/.git" ]; then
  echo "  present at $(git -C "$API_HOME/src" log --oneline -1 | cut -c1-80)"
else
  run git clone --recurse-submodules "$REPO" "$API_HOME/src"
fi
[ -f "$API_HOME/src/Cargo.lock" ] || missing+=("$API_HOME/src/Cargo.lock (the docker build needs it; copy the old host's, see api/README.md)")

step "6. firewall (managed blocks)"
managed() { # file begin-marker end-marker anchor-line insert(before|after) block
  local file=$1 begin=$2 end=$3 anchor=$4 where=$5 block=$6 out cur
  grep -qxF -- "$anchor" "$file" || { echo "  $file has no line '$anchor'" >&2; exit 1; }
  # An identical block stays where it is. Two blocks share an anchor, and re-inserting each at it
  # would swap them on every run: the file rewritten and ufw reloaded for nothing. Their order
  # does not matter, the addresses they name do not overlap.
  cur=$(awk -v b="$begin" -v e="$end" '$0 == b { p = 1 } p { print } p && $0 == e { exit }' "$file")
  if [ "$cur" = "$block" ]; then echo "  $file: up to date"; return 1; fi
  out=$(mktemp)
  awk -v b="$begin" -v e="$end" -v a="$anchor" -v w="$where" -v blk="$block" '
    $0 == b { skip = 1; next }  skip && $0 == e { skip = 0; next }  skip { next }
    $0 == a && !done && w == "before" { print blk; print; done = 1; next }
    $0 == a && !done && w == "after"  { print; print blk; done = 1; next }
    { print }' "$file" > "$out"
  if cmp -s "$file" "$out"; then echo "  $file: up to date"; rm -f "$out"; return 1; fi
  diff -u "$file" "$out" | sed 's/^/    /' || true
  if [ "$APPLY" -eq 1 ]; then
    local bak; bak="$file.bak-$(date +%Y%m%d-%H%M%S)-$$-${#BACKUPS[@]}"   # unique: one run may edit a file twice
    cp -p "$file" "$bak"; cat "$out" > "$file"; BACKUPS+=("$file:$bak")
  fi
  rm -f "$out"; return 0
}
# The edge and db subnets must be the two halves of $API_NETS.
edge3=$(echo "$API_SUBNET_EDGE" | cut -d. -f3); db3=$(echo "$API_SUBNET_DB" | cut -d. -f3)
[ "${API_SUBNET_EDGE%.*.*}" = "${API_SUBNET_DB%.*.*}" ] && [ $((edge3 % 2)) -eq 0 ] && [ "$db3" -eq $((edge3 + 1)) ] \
  || { echo "  API_SUBNET_EDGE/API_SUBNET_DB must be x.y.<even>.0/24 and x.y.<even+1>.0/24 (one /23)" >&2; exit 1; }
# This node's private interface (the one with a 10/8 address): the provider's network. It also
# routes public ranges (188.42.208.0/21 on servers.com), so it is dropped by interface too.
PRIV_IF=$(ip -4 -o addr | awk '$4 ~ /^10\./ {print $2; exit}')
private_drops() { # source
  if [ -n "$PRIV_IF" ]; then echo "-A DOCKER-USER -s $1 -o $PRIV_IF -j DROP"; fi
  local d
  for d in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
    echo "-A DOCKER-USER -s $1 -d $d -j DROP"
  done
}
node_docker_block="# BEGIN outlayer api-node docker-user (managed by 50-api.sh)
# DOCKER-USER is declared, and so emptied before every load, here and only here: a network's
# block must not redeclare it, or loading that block would empty the rules loaded before it.
:DOCKER-USER - [0:0]
# The default bridge (image builds, the cargo update of outlayer-<net>-api deploy) reaches
# public addresses only.
-A DOCKER-USER -s 172.17.0.0/16 -d 172.17.0.0/16 -j RETURN
$(private_drops 172.17.0.0/16)
# END outlayer api-node docker-user"
node_input_block="# BEGIN outlayer api-node input (managed by 50-api.sh)
# The default bridge never needs this host.
-A ufw-before-input -s 172.17.0.0/16 -j DROP
# END outlayer api-node input"
input_block="# BEGIN outlayer-$NET-api input (managed by 50-api.sh)
# The db network never reaches this host; the edge network reaches it on 443 only (the dstack
# gateway, for the keystores).
-A ufw-before-input -s $API_SUBNET_DB -j DROP
-A ufw-before-input -s $API_SUBNET_EDGE -p tcp --dport 443 -j ACCEPT
-A ufw-before-input -s $API_SUBNET_EDGE -j DROP
# END outlayer-$NET-api input"
output_block="# BEGIN outlayer-$NET-api output (managed by 50-api.sh)
# Only root on this host opens connections into the API's networks. Anyone else (another
# daemon, a CVM through qemu) could reach the coordinator past nginx and name its own
# X-Real-IP, which WORKER_ALLOWED_IPS and the per-IP limits rely on.
-A ufw-before-output -d $API_NETS -m conntrack --ctstate NEW -m owner ! --uid-owner 0 -j REJECT
# END outlayer-$NET-api output"
cf_rules=""; for r in $CF_V4; do cf_rules+="-A outlayer-$NET-api-cf -s $r -j RETURN"$'\n'; done
docker_block="# BEGIN outlayer-$NET-api docker-user (managed by 50-api.sh)
:outlayer-$NET-api-cf - [0:0]
# $API_PORT (published by nginx) admits Cloudflare only.
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $API_PORT --ctdir ORIGINAL -j outlayer-$NET-api-cf
${cf_rules}-A outlayer-$NET-api-cf -j DROP
# The API's containers reach public addresses only.
-A DOCKER-USER -s $API_NETS -d $API_NETS -j RETURN
$(private_drops "$API_NETS")
# END outlayer-$NET-api docker-user"
for b in "$node_docker_block" "$node_input_block" "$input_block" "$output_block" "$docker_block"; do
  ufw_rules_kernel_check "$b" || exit 1
done
echo "  the kernel accepts every rule of every block"

# Live after a reload: the node's rules, and those of EVERY network installed on this node.
fw_live_ok() {
  iptables -S DOCKER-USER | grep -q -- '-s 172.17.0.0/16 -d 10.0.0.0/8 -j DROP' || return 1
  iptables -S ufw-before-input | grep -q -- '-s 172.17.0.0/16 -j DROP' || return 1
  local n
  for n in $(sed -n 's/^# BEGIN \(outlayer-[a-z]*-api\) docker-user .*/\1/p' /etc/ufw/after.rules); do
    iptables -S DOCKER-USER | grep -q -- "-j $n-cf" || { echo "  $n: its Cloudflare rule is not live" >&2; return 1; }
  done
  iptables -S ufw-before-input | grep -q -- "-s $API_SUBNET_DB -j DROP" || return 1
  iptables -S ufw-before-output | grep -q -- "-d $API_NETS .*--uid-owner 0 -j REJECT" || return 1
}
BACKUPS=()
changed=0
ESTABLISHED_IN="-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
ESTABLISHED_OUT="-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
managed /etc/ufw/before.rules "# BEGIN outlayer api-node input (managed by 50-api.sh)" "# END outlayer api-node input" \
  "$ESTABLISHED_IN" after "$node_input_block" && changed=1
managed /etc/ufw/before.rules "# BEGIN outlayer-$NET-api input (managed by 50-api.sh)" "# END outlayer-$NET-api input" \
  "$ESTABLISHED_IN" after "$input_block" && changed=1
managed /etc/ufw/before.rules "# BEGIN outlayer-$NET-api output (managed by 50-api.sh)" "# END outlayer-$NET-api output" \
  "$ESTABLISHED_OUT" after "$output_block" && changed=1
managed /etc/ufw/after.rules "# BEGIN outlayer api-node docker-user (managed by 50-api.sh)" "# END outlayer api-node docker-user" \
  "*filter" after "$node_docker_block" && changed=1
managed /etc/ufw/after.rules "# BEGIN outlayer-$NET-api docker-user (managed by 50-api.sh)" "# END outlayer-$NET-api docker-user" \
  "# don't delete the 'COMMIT' line or these rules won't be processed" before "$docker_block" && changed=1
if [ "$APPLY" -eq 1 ]; then
  if [ "$changed" -eq 1 ] || ! fw_live_ok 2>/dev/null; then
    iptables-restore --test -n < /etc/ufw/before.rules && iptables-restore --test -n < /etc/ufw/after.rules
    if [ "${#BACKUPS[@]}" -eq 0 ]; then   # files already right, rules not live: keep a copy anyway
      for f in /etc/ufw/before.rules /etc/ufw/after.rules; do
        b="$f.bak-$(date +%Y%m%d-%H%M%S)-$$"; cp -p "$f" "$b"; BACKUPS+=("$f:$b")
      done
    fi
    # One backup per file: the first one this run made, i.e. the state before it.
    first=(); seen=""
    for pb in "${BACKUPS[@]}"; do case " $seen " in *" ${pb%%:*} "*) ;; *) first+=("$pb"); seen+=" ${pb%%:*}";; esac; done
    ufw_reload_checked "fw_live_ok" "${first[@]}" || exit 1
    echo "  reloaded; open a NEW ssh session before closing this one"
  fi
fi

step "7. outlayer-$NET-api"
put "$HERE/api/outlayer-api" "/usr/local/bin/outlayer-$NET-api" 755 root:root
# The generic name it once had picked the network from an environment variable.
if grep -qs "the only way to operate the API stack" /usr/local/bin/outlayer-api; then run rm /usr/local/bin/outlayer-api; fi

step "secrets (placed by hand, never by this script; see api/README.md)"
need() { # path mode owner:group
  if [ ! -f "$1" ]; then missing+=("$1 ($2 $3)"); return; fi
  [ "$(stat -c '%a %U:%G' "$1")" = "$2 $(getent passwd "${3%:*}" | cut -d: -f1):$(getent group "${3#*:}" | cut -d: -f1)" ] \
    && echo "  $1: ok" || { echo "  $1: mode/owner $(stat -c '%a %U:%G' "$1"), want $2 $3"; run chown "$3" "$1"; run chmod "$2" "$1"; }
}
need "$API_HOME/coordinator.env" 600 0:0
need "$API_HOME/secrets/pg-password" 640 0:70
need "$API_HOME/secrets/redis.conf" 640 0:2100
# The coordinator writes its wasm cache where the compose file mounts it; anywhere else is the
# read-only root, and the coordinator exits at start.
if [ -f "$API_HOME/coordinator.env" ]; then
  wdir=$(sed -n 's/^WASM_CACHE_DIR=//p' "$API_HOME/coordinator.env" | tail -1 | sed -E 's/^["'"'"']//; s/["'"'"']$//')
  [ -z "$wdir" ] || [ "$wdir" = /var/offchainvm/wasm ] \
    || missing+=("coordinator.env: WASM_CACHE_DIR=$wdir — set it to /var/offchainvm/wasm (the mount) or remove it")
  pool=$(sed -n 's/^DB_POOL_SIZE=//p' "$API_HOME/coordinator.env" | tail -1 | tr -dc '0-9')
  [ -z "$pool" ] || [ "$pool" -lt "$PG_MAX_CONNECTIONS" ] \
    || missing+=("coordinator.env: DB_POOL_SIZE=$pool is not below PG_MAX_CONNECTIONS=$PG_MAX_CONNECTIONS ($NET.env)")
fi
# The wasm cache evicts only above WASM_CACHE_MAX_SIZE_GB, and it shares the data image with
# Postgres: a limit near the image size fills the image first, and Postgres stops on ENOSPC.
if [ -f "$API_HOME/coordinator.env" ]; then
  cache_gb=$(sed -n 's/^WASM_CACHE_MAX_SIZE_GB=//p' "$API_HOME/coordinator.env" | tail -1)
  image_gb=${API_DATA_SIZE%G}
  if [ -z "$cache_gb" ] || [ "$cache_gb" -gt $(( image_gb / 3 )) ]; then
    missing+=("coordinator.env: WASM_CACHE_MAX_SIZE_GB=${cache_gb:-unset} — set it to at most $(( image_gb / 3 )) (a third of the ${API_DATA_SIZE} data image)")
  fi
fi
for c in $(sed -n 's#^ *ssl_\(client_\)\?certificate\(_key\)\? */etc/nginx/certs/\([^;]*\);#\3#p' "$NGINX_CONF" | sort -u); do
  need "$API_HOME/nginx/certs/$c" 640 0:2100
done

echo
if [ "${#missing[@]}" -gt 0 ]; then echo "STILL MISSING:"; printf '  - %s\n' "${missing[@]}"; fi
[ "$APPLY" -eq 1 ] || echo "DRY-RUN: nothing changed. Re-run with --apply."
echo "then: ./46-lo-guard.sh --apply (denies loopback to outlayer-api and outlayer-api-pg)"
