# The OutLayer API on a TDX node

The coordinator, its Postgres and Redis, and an nginx in front, as one caged compose stack
per network: `outlayer-<net>-api` in `/opt/outlayer-<net>-api`. The node also carries the
keystores and the workers, so the stack is built so that nothing in it, and nobody who
breaks into it, reaches them.

## What keeps it away from the CVMs

| layer | how | where |
|---|---|---|
| users | coordinator, Redis, nginx run as `outlayer-api` (2100), Postgres as `outlayer-api-pg` (70, alpine's own postgres uid). Neither is root or `outlayer`, both are in no group, neither reads `/home/outlayer` or `/home/mpc` | `compose.yaml`, `50-api.sh` step 1 |
| container | no capabilities, `no-new-privileges`, read-only root, pids/memory/CPU limits, capped logs; never privileged, never host network, never the docker socket | `compose.yaml` |
| networks | `edge` (nginx ↔ coordinator) and `db` (`internal: true`, no way out). From a bridge, the host's `127.0.0.1` services (vmm APIs, keystores, guest agents) are not reachable | `compose.yaml` |
| host firewall | the edge subnet reaches the host on 443 only (the dstack gateway, for the keystores); the db subnet never reaches it. The API's subnets reach public addresses only: no `10/8`, `172.16/12`, `192.168/16`, `100.64/10`, link-local, and nothing out of the private interface, which also routes some public ranges. The published port admits Cloudflare only. Only root on the host opens connections into the API's subnets, so no other daemon or CVM reaches the coordinator past nginx with an `X-Real-IP` of its choosing. The default docker bridge (image builds, the deploy's `cargo update`) gets the same public-only rule and never reaches the host | `50-api.sh` step 6: managed blocks in `/etc/ufw/before.rules`, `after.rules`. `DOCKER-USER` is declared once, in the node's block, so a second network's stack never empties the first one's rules |
| host network | the two users are refused all host networking, IPv4 and IPv6, even outside a container | `46-lo-guard.sh` (`DENIED_USERS`) |
| wasm cache | `WASM_CACHE_MAX_SIZE_GB` at most a third of the data image, so the cache evicts before Postgres runs out of space (`50-api.sh` refuses more) | `coordinator.env` |
| build | `rust:alpine` for the deploy's `cargo update` is pinned by digest: it runs as root on the node | `outlayer-api` |
| origin | `testnet-api.outlayer.ai` uses per-hostname Authenticated Origin Pulls with OUR client certificate (uploaded to Cloudflare for that name only); nginx refuses a connection without it. The DOCKER-USER allowlist admits every Cloudflare IP, and Cloudflare's shared AOP certificate is presented by any customer's zone, so only our own certificate proves the request is our zone's | `nginx/certs/cloudflare-origin-pull-ca.pem` (the CA that signed it; its key was deleted) |
| disk | data on a fixed-size image (`/var/lib/outlayer-<net>-api.img`), so it cannot fill `/`, which holds the CVM disks. Not mounted → the services refuse to start (`create_host_path: false`) instead of initialising an empty database on `/` | `50-api.sh` step 2 |

Accepted risk: a kernel exploit from inside a container ends as root. The stack runs only
our code; nothing that builds strangers' repositories ever runs on a TDX node.

## Operating it

Only through `outlayer-testnet-api` (root; `outlayer-mainnet-api` for mainnet). The network is in the command's name, so neither can reach the other's stack. It always passes this stack's project, compose file and
settings. Never run a global docker command on a TDX node: no `docker stop $(docker ps -q)`,
no `docker system/volume/image prune`, no `docker compose down` elsewhere, no
`systemctl restart|stop docker containerd`. The key provider and aesmd the CVMs need are
docker containers on the same daemon.

```bash
screen -S testnet-api        # once; later: screen -r testnet-api
cd /opt/outlayer-testnet-api/src && git pull && outlayer-testnet-api deploy && outlayer-testnet-api logs
```

| command | does |
|---|---|
| `outlayer-testnet-api deploy` | re-pins `shared-tee-helpers` to its `main` (as `run_coordinator.sh` does), builds the coordinator image stamped with the commit, `up -d` |
| `outlayer-testnet-api logs [svc]` | follows logs, coordinator by default |
| `outlayer-testnet-api ps` / `restart` / `stop` / `start` / `up` | the usual, this stack only |
| `outlayer-testnet-api psql` / `outlayer-testnet-api redis` | a shell into the stack's database / Redis |
| `outlayer-testnet-api shutdown [why]` | maintenance ON: every route but `/health` and `/admin/*` answers 503, workers get no work. For an incident or a move; soft-stop the workers first when it is planned (`docs/ADMIN.md` in near-offshore) |
| `outlayer-testnet-api resume` / `maintenance` | maintenance OFF / the switch as stored |
| `outlayer-testnet-api gc` | frees the build cache older than a week and this stack's dangling images; the only cleanup allowed on the node. Run it every few weeks: each deploy adds to the cache |


The image is built from the checkout with the repository's own `docker/Dockerfile`
(`SQLX_OFFLINE`, the committed `.sqlx`). Nothing is built on the host and nothing reads the
live database at build time. A commit whose `.sqlx` is stale fails the build here.

After a reboot dockerd brings the stack back (`restart: unless-stopped`). A stack stopped
by hand stays stopped. The maintenance switch is in the database, so it comes back as it was.

## For the admin: updating the coordinator

As **root** on the node. `outlayer-testnet-api` needs root, and the repository's deploy key is
root's.

```bash
ssh root@<node>
screen -r testnet-api || screen -S testnet-api     # attach, or create the session once
cd /opt/outlayer-testnet-api/src && git pull && outlayer-testnet-api deploy && outlayer-testnet-api logs
```

Then up-arrow, as before.
- `Ctrl-C` leaves the log view only; the stack keeps running. Docker runs it, not the shell.
- `Ctrl-A D` detaches from screen.

| on the old host | here |
|---|---|
| `su outlayer-worker`, `~/coordinator` | `root`, `/opt/outlayer-testnet-api/src` |
| `./scripts/run_coordinator.sh testnet` | `outlayer-testnet-api deploy` |
| `docker compose -f docker-compose.testnet.yml logs -f` | `outlayer-testnet-api logs` |
| restart / stop | `outlayer-testnet-api restart` / `stop` / `start` |
| psql / redis-cli | `outlayer-testnet-api psql` / `outlayer-testnet-api redis` |
| `~/coordinator/.env.testnet` | `/opt/outlayer-testnet-api/coordinator.env` |

After editing `coordinator.env`, run `outlayer-testnet-api up`: it recreates the coordinator with the
new variables. A plain `restart` keeps the old ones.

## Hostnames

Only `*.outlayer.ai` is served here, through Cloudflare (an Origin Rule sends the name to
the published port). The `*.outlayer.fastnear.com` names are in a zone that is no longer
ours. Their records keep pointing to the old host, which answers every request with
`410 {"error":"api_moved", "new_base_url": …}`.

## Installing

1. From the Mac: `./sync-node.sh <host>`.
2. On the node, in `/home/outlayer/self-hosted-tdx`:
   ```bash
   ./50-api.sh testnet             # dry-run: the plan + what is missing
   ./50-api.sh testnet --apply
   ./46-lo-guard.sh --apply        # picks up the two users
   ```
   The checkout uses the read-only deploy key `/root/.ssh/coordinator_deploy_dal` through
   the ssh host alias `github-coordinator`. It is the same key on every TDX node. Copy it
   node to node through a pipe, never through the terminal.
3. Secrets. None is ever printed or put on a command line. Each one is piped from where it
   lives today (`ssh old 'cat f' | ssh node 'cat > f'`), then given its mode:

   | file | content | mode |
   |---|---|---|
   | `coordinator.env` | the coordinator's env as it runs today (from `docker inspect`, without `PATH`). `DATABASE_URL`/`REDIS_URL` name the hosts `postgres`/`redis`; `WASM_CACHE_DIR` is `/var/offchainvm/wasm` (the mount) or unset; `WASM_CACHE_MAX_SIZE_GB` ≤ a third of the image; `DB_POOL_SIZE` < `PG_MAX_CONNECTIONS`. `50-api.sh` checks the last three | `600 root:root` |
   | `secrets/pg-password` | the Postgres password (`DATABASE_URL`'s) | `640 root:outlayer-api-pg` |
   | `secrets/redis.conf` | `requirepass <REDIS_URL's password>` | `640 root:outlayer-api` |
   | `nginx/certs/outlayer.ai.pem`, `.key` | the Cloudflare Origin CA cert for `*.outlayer.ai` | `640 root:outlayer-api` |
   | `nginx/certs/cloudflare-origin-pull-ca.pem` | the CA of OUR Authenticated Origin Pulls client certificate (see below) | `640 root:outlayer-api` |
   | `src/Cargo.lock` | not secret, but untracked in the repository: copy the running host's | `644` |

   `./50-api.sh testnet` lists what is still missing and fixes modes.
4. First start on an empty database: `outlayer-testnet-api up`. Then prove the cage: `api/check-cage.sh testnet`.
5. Moving data in, Cloudflare and the cutover follow the move runbook (outside this repository).

**Never start a second coordinator against a copy of a live network's data while the first
one runs.** Maintenance closes the HTTP routes only; the background loops (webhooks,
reconcilers, wallet work) would run on both. A rehearsal restores the dump and checks it,
with the coordinator stopped.

## Authenticated Origin Pulls, per hostname

Done once per API hostname, in this order, so that no request is refused on the way:

1. Make a private CA and a client certificate it signs (`openssl`, on an operator machine).
   The CA's certificate goes to `nginx/certs/cloudflare-origin-pull-ca.pem`. Delete the CA's
   key once the client certificate is signed.
2. Upload the client certificate and key to Cloudflare:
   `POST /zones/<zone>/origin_tls_client_auth/hostnames/certificates`. Wait until it is
   `active`, then delete the local key.
3. nginx with `ssl_verify_client optional`: the log's `cf_cert=` field shows the state of each
   request, and nothing is refused yet.
4. Enable the hostname:
   `PUT /zones/<zone>/origin_tls_client_auth/hostnames {"config":[{"hostname":…,"cert_id":…,"enabled":true}]}`.
   Within a minute the log shows `cf_cert=SUCCESS`. A few `NONE` remain on connections Cloudflare
   opened before.
5. `ssl_verify_client on`, then recreate nginx. `check-cage.sh` proves that a connection without
   the certificate gets 400.

The token for steps 2 and 4 needs `Zone → SSL and Certificates → Edit` on the zone only.

The client certificate expires after 5 years (testnet: 2031-10-16). To renew: a new CA and
certificate, steps 1–5 again.

Never use Cloudflare's dashboard toggle for this: that one uses Cloudflare's shared certificate,
which any Cloudflare customer's zone presents.
