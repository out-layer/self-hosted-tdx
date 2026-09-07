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

auth-simple allows a booting CVM only if: TCB is `UpToDate`, its OS image is in `osImages`, and
then — for the KMS itself — its `mrAggregated` is in `kms.mrAggregated` and its device is in
`kms.devices`; for **apps** (workers, keystores) its device is in the top-level `devices` list and
its `appId`+`composeHash` is listed under `apps` (unless `allowAnyApp`, below).

```jsonc
{
  "osImages": ["0x…"],                 // allowed dstack OS image(s)
  "kms":  { "mrAggregated": ["0x…"], "allowAnyDevice": false, "devices": ["0x…"] },
  "apps": { "0x<appId>": { "composeHashes": ["0x<appId+...>"], "allowAnyDevice": true } },
  "allowAnyApp": true,                 // OutLayer customization — see below
  "devices": ["0x…", "0x…"]            // OutLayer customization — sha256(PPID) of OUR hosts
}
```

A worker's `appId` = `sha256(app-compose.json)[:40]`, and the app-compose includes the CVM
**name**, the worker image digest, and the env KEYS — so it changes whenever the name, the
worker version, or the env-var set changes. Without `allowAnyApp`, each such change needs a
new `apps` entry here + an auth-simple restart, or the worker can't get its key and the CVM
fails `dstack-prepare` and power-cycles.

## Device allowlist (`devices`) — hardware binding

`deviceId` = `sha256(PPID)`, taken by the KMS from the **DCAP-verified** quote of the booting CVM
(dstack-attest `get_devide_id`; the PPID sits in the Intel-signed PCK certificate of that CPU), so
it cannot be self-reported or forged without Intel's key or our silicon. The top-level `devices`
list is checked for **every** app boot, before `allowAnyApp`, and an **empty list denies all app
boots** (fail-closed). `kms.devices` gates KMS onboarding and, because the KMS re-asks auth-simple
on every key request, every key request too, with upstream semantics (empty = any device); the
script fills it together with `devices`.

Why this exists: with `--kms`, dstack extends the KMS public key into RTMR3 (`key-provider`
event). That is what makes "our image on our hardware" distinguishable from "our image on
someone else's TDX box" at the DAO / register-contract measurement check. The KMS RPC is
loopback-bound (`KMS_RPC_ADDR=127.0.0.1:11001`, reached from CVMs via slirp `10.0.2.2`) and ufw
drops 11001 on the WAN, but a policy that only holds while a port stays closed is one config
mistake from failing. The device allowlist makes the KMS refuse foreign hardware even if the
port is exposed.

**Verify with a boot.** A wrong entry in `devices` shows up when a CVM next boots (running CVMs never
re-authenticate). A wrong entry in `kms.devices` shows up at once: the KMS re-asks auth-simple on
**every key request** (`ensure_self_allowed`, `enforce_self_authorization = true` upstream default),
so app key requests start failing immediately. Either way the auth log shows the denial together with
the real `deviceId` (the patch logs it in both request lines; stock auth-simple logs
`appId`/`composeHash`/`instanceId` only), auth-simple re-reads the config on every request, and a
denied CVM reboot-loops until it is allowed — so recovery is one config edit, no redeploy. Routine:
apply, restart a **non-critical** CVM, confirm `isAllowed: true` on both the `KMS boot auth` and the
`app boot auth` lines in `journalctl -u outlayer-kms-auth.service`. There is deliberately no "observe"
or "warn-only" switch: a bypass flag in the config is a downgrade path and a phase that is easy to
leave on forever, and it buys nothing the log line does not already give.

Computing the expected id from the PPID the coordinator stores for the node (`tee_nodes.ppid`):

```bash
python3 -c 'import hashlib,sys; print("0x"+hashlib.sha256(bytes.fromhex(sys.argv[1])).hexdigest())' <ppid-hex>
```

Values computed this way for today's nodes (confirm with the boot above):

| node | expected deviceId |
|------|----------|
| node-tdx-dal-2 | `0xc84189f534d6d90747e068fe8090eafd870f5969176b42f9c43be3bb7e8162ce` |
| node-tdx-ams-1 | `0x4a252cf80d209d96bb06ce96e17342ea2234f721b4a158707718b18732d6e4a1` |

Every TDX node runs its own KMS + auth-simple (same dstack version everywhere) and only its own
CVMs reach it, so run step 4b on each node; each node's list needs just its own id, and listing all
nodes keeps the configs identical, which is harmless.

## `allowAnyApp` (avoid per-worker re-allowlisting)

With `allowAnyApp: true`, any app passing the TCB + `osImages` + `devices` checks may boot
**without** a per-`appId` entry. Safe on this **single-tenant** node: the KMS still derives a
**distinct key per appId** (apps can't read each other's secrets), `osImages` still gates the OS,
`devices` gates the hardware, and on-chain registration (register-contract `approved_measurements`
for workers, the keystore DAO vote for keystores) still gates the app itself. This lets us
redeploy workers with new names/versions without editing this allowlist.

Both customizations are a small `index.ts` patch (the live auth-simple lives in the `meta-dstack`
checkout, outside this repo). **Apply them from git — do NOT hand-edit** — with the idempotent,
re-runnable script `apply-auth-simple.sh` (run on the node; uses sudo only for the restart).
`KMS_DEVICES` is required; the script refuses an empty list:

```bash
cd ~/self-hosted-tdx/kms && KMS_DEVICES=0x<sha256(ppid)>[,...] ./apply-auth-simple.sh
# -> patches index.ts (schema: allowAnyApp + devices; checkAppBoot: device check, then the
#    allowAnyApp early allow; deviceId in both request log lines; backup at
#    index.ts.bak.pre-deviceAllowlist), writes allowAnyApp, devices, kms.allowAnyDevice=false,
#    kms.devices, restarts outlayer-kms-auth.service. Skips anything already applied; stops if
#    index.ts carries an allowAnyApp early allow in a shape it does not recognise.
journalctl -u outlayer-kms-auth.service -f          # watch boot allow/deny decisions
```

The script's additions: `allowAnyApp` and `devices` in `AuthConfigSchema`; at the top of
`checkAppBoot(...)` a deny unless `deviceId ∈ config.devices`, followed by the `allowAnyApp` early
allow; `deviceId` in the two boot-auth request log lines. Upstream `bun test` then fails its
app-boot cases (their fixtures configure no `devices`), which is the fail-closed rule doing its job,
not a regression.

The script validates everything before it modifies anything: each id is `0x` + 64 hex, the config
parses, and the config as it will be written has the shape the schema accepts (`osImages` and
`kms.mrAggregated` non-empty, every `apps` value an object). A violation is refused with the field
named, and neither `index.ts` nor the config is touched — a patched `index.ts` next to an unpatched
config would deny every boot at the next service restart.

**Tests:** `test-apply-auth-simple.sh` (needs bun and an upstream auth-simple tree, default the
node's `meta-dstack` checkout; on a dev machine `AUTH_SIMPLE_SRC=<dstack clone>/kms/auth-simple`).
It exercises the patch on a stock file, on the shape the earlier `allowAnyApp`-only patch left on the
live nodes, on an unrecognised shape (must abort untouched), checks idempotency and the written
config, then runs `apply-auth-simple.test.ts` against the patched server: our/foreign device for
app and KMS boots, empty and missing lists, hex normalization, the per-app path, schema-invalid and
malformed configs (deny everything), and `deviceId` in both log lines.

After this, a worker with a new name/version boots (KMS issues its key); it then only needs its
measurements approved on the register-contract (the Mac orchestrator `scripts/deploy_tdx.sh` does
that automatically). Revert: `cp index.ts.bak.pre-deviceAllowlist index.ts`, drop `allowAnyApp`
and `devices` from the config, restart the service.
