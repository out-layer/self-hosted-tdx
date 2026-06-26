# BIOS settings for TDX (Dell 16G PowerEdge via iDRAC racadm)

Verified on a Dell R760 (Xeon Gold 6548Y+). Other vendors: enable the equivalent
settings in the platform's "Socket Configuration → Processor → TME/TME-MT/TDX/SGX".

## Access iDRAC
- Enable temporary public OOB access on the provider portal (or use the provider VPN).
- `ssh admin@<idrac-ip>` → racadm shell. Run commands non-interactively from your
  shell, e.g. `ssh admin@<idrac-ip> "racadm get BIOS.SysSecurity"` (the racadm shell
  itself has no pipes/grep).

## Memory requirement (mandatory for SGX/TDX)
All IMC channel slot-0 must be populated: **8 identical DIMMs per populated CPU
socket** (dual-socket = 16). With fewer, `IntelSgx` stays read-only `Off` and TDX
attestation can't work.

## Settings — TWO passes, each = set + jobqueue create + powercycle

`EnableTdx`, `EnableTdxSeamldr`, `IntelSgx` are **dependent attributes**: on a fresh read
they print with a leading `#` (read-only) and a `set` is rejected until their parent is
applied. So this is a strict two-reboot sequence (confirmed on R760 / iDRAC 7.30, BIOS 2.10,
2026-06-23). `ProcX2Apic` / `NodeInterleave` are often already correct from the factory —
check first, skip if so.

**Pass 1 — enable memory encryption (this is what unlocks TDX/SGX):**
```bash
racadm set BIOS.MemSettings.NodeInterleave Disabled      # usually already Disabled
racadm set BIOS.ProcSettings.ProcX2Apic Enabled          # usually already Enabled
racadm set BIOS.ProcSettings.CpuPaLimit Disabled
racadm set BIOS.SysSecurity.MemoryEncryption MultipleKeys
racadm set BIOS.SysSecurity.GlbMemIntegrity Disabled
racadm jobqueue create BIOS.Setup.1-1
racadm serveraction powercycle
```
After Pass 1 applies, `EnableTdx` and `IntelSgx` lose the `#` (become writable).
`EnableTdxSeamldr` is **still** `#` here — it depends on `EnableTdx`, not on
`MemoryEncryption`.

**Pass 2 — enable TDX + SGX. Order matters:** stage `EnableTdx=Enabled` **first** — that
unlocks `EnableTdxSeamldr` *within the same racadm session* (no extra reboot needed), and
`IntelSgx=On` unlocks `SgxAutoRegistrationAgent`:
```bash
racadm set BIOS.SysSecurity.EnableTdx Enabled            # set this BEFORE Seamldr
racadm set BIOS.SysSecurity.EnableTdxSeamldr Enabled
racadm set BIOS.SysSecurity.IntelSgx On
racadm set BIOS.SysSecurity.SgxAutoRegistrationAgent Enabled  # multi-package reg w/ Intel PCS
# KeySplit is typically already 1 (read-only `#1`) — no set needed.
# (SgxFactoryReset On forces a fresh registration; values are On/Off, NOT Enabled.)
racadm jobqueue create BIOS.Setup.1-1
racadm serveraction powercycle
```
Each `set` should return `RAC1017 ... change is in pending state`. Confirm with
`racadm get BIOS.SysSecurity` showing `(Pending Value=...)` before creating the job.
The BIOS job runs on the next boot; the apply itself is ~5–8 min of POST (memory retrain).

## Verify
```bash
racadm get BIOS.SysSecurity      # MemoryEncryption=MultipleKeys, EnableTdx=Enabled,
                                 # EnableTdxSeamldr=Enabled, IntelSgx=On, KeySplit=1
```
Also update BIOS + microcode (Maintenance → System Update) so the TCB is current —
the on-chain attestation rejects platforms whose TCB is not `UpToDate`.

## SGX multi-package registration
`SgxAutoRegistrationAgent=Enabled` + reboot runs the registration agent. On "won't
save keys" platforms the manifest is NOT auto-sent to Intel — push it to the local
PCCS instead (README Step 2). Check `/var/log/mpa_registration.log`.
