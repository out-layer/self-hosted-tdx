# Node hardening: freeze the host so nothing bounces the CVMs

On a TDX/dstack node the CVMs (keystore, worker, kms, gateway) run as QEMU guests launched
by `dstack-vmm` under `dockerd`/`containerd`. **Any restart of that stack restarts the
guests.** For the keystore that is catastrophic: it boots with an *ephemeral* key, submits a
fresh DAO registration proposal, and **hard-times-out after ~30 min if nobody votes** →
`is_ready=false` forever → all `/wallet/*` custody down until a manual restart + DAO vote.
(See incident 2026-07-16 and `keystore.md`.)

So the host must **never** upgrade or restart the container runtime / QEMU unattended.

## What actually bit us (2026-07-16)

`unattended-upgrades` upgraded `libslirp0` (a QEMU user-net lib) at 06:59 UTC. It did not
reboot the node — instead the `needrestart` hook, seeing running processes linked against the
old lib, **restarted `containerd` + `dockerd` + `dstack-vmm`**, which bounced the keystore CVM.
Two independent things had to be disabled: the auto-upgrade **and** needrestart's auto-restart.

## What to disable (all of it — copy-paste, run as root)

```bash
# 1. apt auto-upgrades — both timers + the service. mask so a package can't re-enable them.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
systemctl mask unattended-upgrades.service apt-daily-upgrade.service
printf 'APT::Periodic::Update-Package-Lists "0";\nAPT::Periodic::Unattended-Upgrade "0";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades

# 2. needrestart → LIST ONLY. THE important one: even a *manual* apt op must never
#    auto-restart services (that is what bounced the runtime). Drop-in, survives pkg upgrades.
mkdir -p /etc/needrestart/conf.d
printf "# Never auto-restart services on this TDX host — a runtime restart bounces the CVMs.\n\$nrconf{restart} = 'l';\n" \
  > /etc/needrestart/conf.d/50-no-auto-restart.conf

# 3. Freeze the runtime + QEMU/virt stack so even a manual 'apt upgrade' can't pull a new
#    version and trigger a restart. Ubuntu package names (NOT docker-ce/containerd.io).
#    QEMU here is the TDX-patched build (+tdx1.x) — pinning it also protects attestation.
apt-mark hold \
  containerd docker.io ipxe-qemu libslirp0 libvirt-daemon-driver-qemu \
  qemu-system-common qemu-system-data qemu-system-x86 qemu-utils

# 4. PackageKit is 'static' (can't disable) but can be triggered to apply updates — mask it.
systemctl mask packagekit.service

# 5. fwupd firmware metadata refresh. On a TDX node firmware/microcode changes alter
#    measurements (MRTD/RTMR0) and break attestation — never let anything touch firmware
#    unattended. (fwupd-refresh only fetches metadata, but be conservative here.)
systemctl disable --now fwupd-refresh.timer
```

## Verify

```bash
systemctl list-timers --all | grep -iE 'apt|unattended|fwupd'   # expect: nothing / inactive
apt-mark showhold | sort | tr '\n' ' '; echo
#   -> containerd docker.io ipxe-qemu libslirp0 libvirt-daemon-driver-qemu
#      qemu-system-common qemu-system-data qemu-system-x86 qemu-utils   (9)
cat /etc/needrestart/conf.d/50-no-auto-restart.conf                # $nrconf{restart} = 'l';
```

## Deliberately left ENABLED (safe — download/report only, never install or restart)

- `update-notifier-download.timer`, `ua-timer.timer` — fetch update/compliance metadata only.
- `apport-autoreport.timer` — crash reports.
- `snapd` — present but no application snaps are installed here, so auto-refresh restarts
  nothing that matters. **If you ever install a snap** that backs a service, also run
  `snap refresh --hold` to stop background snap refreshes.

## Doing upgrades later (the right way)

Patch in a **planned window with an operator watching the keystore**:

```bash
apt-mark unhold <pkg...>          # only the packages you intend to update
apt-get update && apt-get install --only-upgrade <pkg...>
# runtime/QEMU changes → the CVMs restart → keystore needs a DAO vote within 30 min:
#   worker-ctl.sh restart mainnet-keystore-0136   (watch: "Waiting for DAO approval of proposal #N")
#   near call dao.outlayer.near vote '{"proposal_id": N, "approve": true}' \
#     --accountId owner.outlayer.near --nodeUrl https://rpc.mainnet.fastnear.com
apt-mark hold <pkg...>            # re-freeze
```

## Does freezing break attestation? No — it protects it

The frozen packages are `docker/containerd/qemu/libvirt/libslirp`; the masks are
`unattended-upgrades/packagekit/fwupd-refresh`. **None of these are attestation collateral.**
QGS (`qgsd`) and PCCS (`pccs`) are untouched and keep fetching Intel PCS collateral over the
network on their own cycle. `fwupd-refresh` only pulls LVFS *metadata* and applies nothing;
Intel microcode and SGX/DCAP arrive via apt packages (`intel-microcode`, `libsgx-*`,
`sgx-dcap-pccs`), which are **not** held.

The point of freezing is the opposite of a risk: an unattended microcode/SEAM/QEMU change would
silently shift the platform TCB (or guest measurements) and **break the running CVMs' attestation
without warning**. Freezing makes every such change **deliberate and planned** — done in a window
with collateral refreshed and DAO votes ready. That planned procedure is the
[maintenance-runbook.md](maintenance-runbook.md).

Note: `intel-microcode` is deliberately **not** frozen (so a security fix is possible) — but with
auto-upgrades off it never changes on its own; you upgrade it explicitly per the runbook.

## Related, out of scope for host hardening

The deeper fragility — keystore wedging on *any* restart because of the ephemeral key +
30-min approval timeout — is a code/ops fix, not a host setting. Tracked separately
(PagerDuty alert on a pending `init-keystore.outlayer.near` DAO proposal;
`~/.claude/plans/keystore-restart-pagerduty-alert.md`).
