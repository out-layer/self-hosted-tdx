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

## Settings (set, then one job + reboot)
```bash
racadm set BIOS.MemSettings.NodeInterleave Disabled
racadm set BIOS.ProcSettings.ProcX2Apic Enabled
racadm set BIOS.ProcSettings.CpuPaLimit Disabled
racadm set BIOS.SysSecurity.MemoryEncryption MultipleKeys
racadm set BIOS.SysSecurity.GlbMemIntegrity Disabled
racadm set BIOS.SysSecurity.EnableTdx Enabled
racadm set BIOS.SysSecurity.KeySplit 1            # TME-MT/TDX key split, non-zero
racadm set BIOS.SysSecurity.EnableTdxSeamldr Enabled
# IntelSgx unlocks only after MemoryEncryption=MultipleKeys is applied + memory is
# fully populated — so apply the above (jobqueue + powercycle) FIRST, then:
racadm set BIOS.SysSecurity.IntelSgx On
# Required for multi-package platform registration with Intel PCS:
racadm set BIOS.SysSecurity.SgxAutoRegistrationAgent Enabled
# (SgxFactoryReset On forces a fresh registration; values are On/Off, NOT Enabled.)

racadm jobqueue create BIOS.Setup.1-1
racadm serveraction powercycle
```
`IntelSgx`, `EnableTdxSeamldr` are dependent attributes — they only become writable
after `MemoryEncryption=MultipleKeys` is applied, so do it in two reboots if a single
batch errors on a dependency.

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
