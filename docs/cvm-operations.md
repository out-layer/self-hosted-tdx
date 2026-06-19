# CVM operations (self-hosted TDX worker)

Day-2 ops for the dstack CVMs running on the self-hosted TDX node. All commands run
**on the node** (`ssh root@173.237.9.76`) — the control-plane ports are bound to
loopback (`127.0.0.1`), not exposed to the WAN.

| What | Address (loopback on the node) |
|------|--------------------------------|
| dstack-vmm RPC | `http://127.0.0.1:11000` |
| worker guest-agent (logs) | `http://127.0.0.1:<AGENT>` → CVM `8090` — **`<AGENT>` is reassigned on every stop/start** (don't hardcode it; discover it below) |

`vmm-cli.py` is the control plane. Handy shell vars:

```bash
V=/opt/mpc/dstack/vmm/src/vmm-cli.py
U=http://127.0.0.1:11000
WORKER=cd009b5b-0102-442c-bb18-16b2097c5159   # outlayer-worker CVM (see `lsvm` for current id)
```

## Quick reference: `worker-ctl.sh` (use this)

`deploy/self-hosted-tdx/worker-ctl.sh` (installed on the node at `/usr/local/bin/worker-ctl.sh`)
wraps all of the below. It resolves the CVM by **name** (stable), drives it by uuid, and
auto-discovers the reassigned agent port for logs — so you never deal with the port yourself:

```bash
worker-ctl.sh status            # lsvm
worker-ctl.sh logs              # last 200 worker app-log lines (snapshot)
worker-ctl.sh follow            # stream worker app logs
worker-ctl.sh restart           # stop -f + start  (re-runs registration)
worker-ctl.sh stop | start
worker-ctl.sh port              # current agent host port (for ad-hoc curl)
worker-ctl.sh serial            # qemu serial console (boot/system, not app logs)
NAME=outlayer-worker-mainnet worker-ctl.sh follow   # target a different CVM by name
```

The rest of this doc explains what the wrapper does under the hood (and is the fallback
if the script isn't present).

### Naming & running multiple workers

The CVM name is set at deploy via `APP_NAME` (a deploy-time arg, **not** a `worker.env`
variable — the worker process never reads it). Encode network + worker version + index so
several workers coexist unambiguously and `worker-ctl.sh` can target each by name:

```
outlayer-worker-<net>-<version>-<index>
  e.g.  outlayer-worker-testnet-0.1.35-1
        outlayer-worker-mainnet-0.1.35-1
```

Each network uses its own secrets file (gitignored, node-only), copied from the committed
templates in `worker/`:

```bash
# testnet
APP_NAME=outlayer-worker-testnet-0.1.35-1 ENVFILE=worker/.env.testnet-worker-tdx \
  ./40-deploy-worker.sh v0.1.35
# mainnet
APP_NAME=outlayer-worker-mainnet-0.1.35-1 ENVFILE=worker/.env.mainnet-worker-tdx \
  ./40-deploy-worker.sh v0.1.35
# then manage each by its name:
NAME=outlayer-worker-mainnet-0.1.35-1 worker-ctl.sh follow
```

(The first CVM deployed in this project is just `outlayer-worker` — `worker-ctl.sh`'s default
NAME. New deploys should use the scheme above.)

### Discover the guest-agent host port (`<AGENT>`)

vmm assigns the agent host port (→ guest `8090`) at VM start and **reassigns it on each
stop/start** — it is NOT fixed at the deploy-time value. `vmm-cli info` does not print it,
so read it from the live qemu process, matched by the CVM uuid:

```bash
for pid in $(pgrep -f qemu-system-x86_64); do
  cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
  uuid=$(echo "$cmd" | grep -oE '[0-9a-f-]{36}' | head -1)
  fwd=$(echo "$cmd" | grep -oE '127.0.0.1:[0-9]+-:8090')
  [ "$uuid" = "$WORKER" ] && echo "AGENT=${fwd#127.0.0.1:}" | sed 's/-:8090//'
done
# e.g. AGENT=11015  ->  use http://127.0.0.1:11015 below
```

## List CVMs / status

```bash
python3 $V --url $U lsvm
```

Shows VM ID, App ID, Name, Status, Uptime. The two CVMs are `kms` and `outlayer-worker`.
`python3 $V --url $U info $WORKER` prints full detail for one CVM.

## Worker logs

**Worker application logs** — what you almost always want. The container is named
`dstack-worker-1` (compose project `dstack`, service `worker`), **not** `worker`:

```bash
# live follow, last 200 lines (AGENT from the discovery snippet above, e.g. 11015):
curl -sN "http://127.0.0.1:$AGENT/logs/dstack-worker-1?text=true&bare=true&follow=true&tail=200"
# snapshot (no follow):
curl -s  "http://127.0.0.1:$AGENT/logs/dstack-worker-1?text=true&bare=true&tail=200"
```

> `404: No such container` means you used the wrong name (`worker` → use `dstack-worker-1`)
> or you hit a **stale qemu's** agent port (see Gotchas). Empty output means the container
> has exited (e.g. it printed "Worker stopped" after a failed registration and gave up per
> the compose `restart: on-failure:5` policy) — restart the CVM to re-run it.
>
> Successful registration logs end with `✅ Worker key registered successfully!` and a tx
> hash, then the worker enters its event-monitor loop (`📥 Block N: Fetched from neardata`).

**VM / system logs** (qemu serial console, guest boot, container network) — for boot or
attestation problems, not worker app logic:

```bash
python3 $V --url $U logs -f -n 200 $WORKER
```

## Restart the worker CVM

There is no `restart` verb — stop, then start. A full stop/start reboots the guest, which
re-runs attestation, re-derives the KMS-encrypted env, and re-attempts `register_worker_key`.

```bash
python3 $V --url $U stop  $WORKER     # add -f to force
python3 $V --url $U start $WORKER
# re-discover AGENT (the port changed!), then watch registration:
curl -sN "http://127.0.0.1:$AGENT/logs/dstack-worker-1?text=true&bare=true&follow=true&tail=100"
```

A successful registration ends with the worker adding its function-call key to the operator
account and entering its task-poll loop (no more "Worker stopped"). On failure it prints the
reason (missing/mismatched collateral, measurements not approved, or — historically — gas).

## Gotchas

- **Agent host port changes on stop/start.** vmm reassigns the `8090` host-forward each start
  (deploy-time `9210` → e.g. `11015` after a restart). Always re-run the discovery snippet;
  never hardcode the port.
- **Stop/start can leak a stale qemu.** A `stop`/`start` may leave the previous instance's
  qemu process running even though `lsvm` shows only the live VM. The stale process still
  binds an old agent port (e.g. `9208`) but has **no running container** (its `/logs/...`
  returns `404`), and it wastes a CVM's worth of RAM/CPU. Detect and kill leaked instances —
  any qemu whose uuid is **not** in `lsvm`:
  ```bash
  live=$(python3 $V --url $U lsvm 2>/dev/null | grep -oE '[0-9a-f-]{36}')
  for pid in $(pgrep -f qemu-system-x86_64); do
    uuid=$(tr '\0' ' ' < /proc/$pid/cmdline | grep -oE '[0-9a-f-]{36}' | head -1)
    echo "$live" | grep -q "$uuid" || echo "STALE qemu pid=$pid uuid=$uuid (kill $pid)"
  done
  ```

## Redeploy the worker (new image / new env)

Use `40-deploy-worker.sh <version>` (rebuilds app-compose + re-encrypts env via KMS, then
`deploy`). A new worker image changes MRTD/RTMR, so its measurements must be re-approved on
the register-contract (`add_approved_measurements`, owner-signed) before it can register.
Stop/start does **not** change measurements — only a redeploy with a new image does.
