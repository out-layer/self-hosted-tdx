# Per-node KMS — run & watch

The self-hosted node runs its own dstack KMS so worker CVMs can decrypt their
KMS-encrypted env and derive per-app keys. Two pieces:

| Piece | What | Where |
|-------|------|-------|
| KMS CVM | the dstack KMS itself (a CVM named `kms`) | vmm, `lsvm` shows it |
| auth-simple | boot-authorization webhook the KMS calls to allow/deny a booting CVM | host systemd `outlayer-kms-auth.service` (`bun run index.ts`) |

- auth-simple source (live): `/home/outlayer/meta-dstack/dstack/kms/auth-simple/index.ts`
- allowlist config: `/home/outlayer/outlayer-kms/auth-config.json` (`AUTH_CONFIG_PATH`)
- KMS API on the host: `https://127.0.0.1:11001` (TLS not verified by vmm-cli; cert SAN is `kms.1022.dstack.org`)

## Watch logs

```bash
# Boot-authorization decisions (WHY a worker was allowed/denied at boot) — most useful:
journalctl -u outlayer-kms-auth.service -f          # add --no-pager -n 50 for a snapshot

# KMS CVM application logs (the kms container):
worker-ctl.sh logs kms                              # snapshot (auto-uses container dstack-kms-1)
worker-ctl.sh follow kms                            # stream

# KMS CVM boot/system (serial console):
worker-ctl.sh serial kms
```

## Manage the KMS CVM

```bash
worker-ctl.sh status                 # lsvm (kms + workers)
worker-ctl.sh stop kms | start kms | restart kms
systemctl restart outlayer-kms-auth.service   # restart just the auth webhook (does NOT touch running CVMs)
```

## The allowlist (`auth-config.json`)

auth-simple allows a booting CVM only if: TCB is `UpToDate`, its OS image is in `osImages`,
and — for the KMS itself — its `mrAggregated` is in `kms.mrAggregated`; for **apps** (workers),
its `appId`+`composeHash` is listed under `apps` (unless `allowAnyApp`, below).

```jsonc
{
  "osImages": ["0x…"],                 // allowed dstack OS image(s)
  "kms":  { "mrAggregated": ["0x…"], "allowAnyDevice": true },
  "apps": { "0x<appId>": { "composeHashes": ["0x<appId+...>"], "allowAnyDevice": true } },
  "allowAnyApp": true                  // OutLayer customization — see below
}
```

A worker's `appId` = `sha256(app-compose.json)[:40]`, and the app-compose includes the CVM
**name**, the worker image digest, and the env KEYS — so it changes whenever the name, the
worker version, or the env-var set changes. Without `allowAnyApp`, each such change needs a
new `apps` entry here + an auth-simple restart, or the worker can't get its key and the CVM
fails `dstack-prepare` and power-cycles.

## `allowAnyApp` (avoid per-worker re-allowlisting)

With `allowAnyApp: true`, any app passing the TCB + `osImages` checks may boot **without** a
per-`appId` entry. Safe on this **single-tenant** node: the KMS still derives a **distinct key
per appId** (apps can't read each other's secrets), `osImages` still gates the OS, and on-chain
worker registration is still gated by the register-contract's `approved_measurements`. This lets
us redeploy workers with new names/versions without editing this allowlist.

It is a two-line `index.ts` customization (the live auth-simple lives in the `meta-dstack`
checkout, outside this repo). **Apply it from git — do NOT hand-edit** — with the idempotent,
re-runnable script `apply-auth-simple.sh` (run on the node; uses sudo only for the restart):

```bash
cd ~/self-hosted-tdx/kms && ./apply-auth-simple.sh
# -> patches index.ts (adds `allowAnyApp` to the schema + an early allow in checkAppBoot,
#    backup at index.ts.bak.pre-allowAnyApp), sets allowAnyApp=true in auth-config.json,
#    restarts outlayer-kms-auth.service. Skips anything already applied.
journalctl -u outlayer-kms-auth.service -f          # watch boot allow/deny decisions
```

The script's two additions: `allowAnyApp: z.boolean().default(false)` in `AuthConfigSchema`, and
at the top of `checkAppBoot(...)` an early `if (config.allowAnyApp) return { isAllowed: true, … }`.

After this, a worker with a new name/version boots (KMS issues its key); it then only needs its
measurements approved on the register-contract (the Mac orchestrator `scripts/deploy_tdx.sh` does
that automatically). Revert: `cp index.ts.bak.pre-allowAnyApp index.ts`, set `allowAnyApp` false
in the config, restart the service.
