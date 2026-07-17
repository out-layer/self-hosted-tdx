# Maintenance runbook — self-hosted TDX node (`173.237.9.76`)

What to do for planned changes, and — critically — **in what order**, so attestation and
custody don't break. Read [node-hardening.md](node-hardening.md) first (why the host is frozen).

## Mental model: three INDEPENDENT things

Do not conflate these. Each has its own trigger and its own on-chain action.

| Thing | What it is | Changes when… | On-chain action |
|---|---|---|---|
| **Measurements** (MRTD/RTMR0-3) | fingerprint of the CVM's *code/config* | you **redeploy a CVM** with a new image, new compose (`COMPOSE_NAME`/image digest/env KEYS/flags), or different vCPU/memory. **A plain restart does NOT change them.** | `add_approved_measurements` (owner-signed) on `dao.outlayer.near` (keystore) / `worker.outlayer.near` (workers) |
| **Collateral** (Intel TCB info / QE identity / CRL) | Intel's signed statement about the *platform* TCB | **time** (Intel reissues weekly-ish; collateral expires) or **platform TCB moves** (microcode / SEAM / BIOS update). Independent of your code. | `update_collateral(collateral, index)` on `dao.outlayer.near` + `worker.outlayer.near` |
| **Keystore restart vote** | keystore's ephemeral per-boot key needs DAO approval | **every keystore (re)start** | `vote(proposal_id, true)` within ~30 min, else it wedges — see [keystore.md] and the incident note |

Key consequence: **restarting a CVM is not the same as re-approving measurements or refreshing
collateral.** Today's 07:01 incident was *only* the keystore-restart-vote row — measurements and
collateral were already valid.

---

## A. Routine: refresh Intel collateral (weekly / on Intel TCB release)

No CVM restart needed. Stale collateral only blocks **new** registrations (and, once expired,
on-chain quote verification); already-approved CVMs keep running.

```bash
# 1. Get the current collateral JSON. Easiest source: a running CVM logs the collateral it used —
#    copy the JSON block from keystore/worker logs into collateral.json. Or fetch fresh:
scripts/fetch_intel_collateral.sh          # writes/prints the 9-field collateral (Intel-signed)
#    -> save the JSON as ./collateral.json

# 2. Push it to BOTH contracts (keystore DAO + worker register-contract), each collateral slot.
scripts/update_collateral_mainnet.sh       # calls dao.outlayer.near + worker.outlayer.near update_collateral
#    (the contract stores N slots — collaterals_count; update the slot(s) you verify against via `index`)
```

Verify: a test registration / `get_config` shows `has_collateral: true` and the CVMs still
attest. Cadence: **weekly, or the day Intel publishes a TCB update.** Decoupled from restarts.

---

## B. Planned host update (microcode / firmware / frozen pkgs) — FULL NODE EVENT

This is **not** "restart the workers". Microcode applies at boot → the **whole node reboots** →
**every CVM restarts** and re-attests. Order matters because microcode moves the platform TCB.

**Pre-flight (before touching the host):**
```bash
# 1. Refresh on-chain collateral FIRST so it covers the new TCB level the new microcode reports.
scripts/fetch_intel_collateral.sh          # -> collateral.json
scripts/update_collateral_mainnet.sh
# 2. Announce a maintenance window and have the owner key (owner.outlayer.near) ready to vote.
```

**Apply (on the node):**
```bash
# microcode is intentionally NOT in the apt-mark hold list, so no unhold needed:
apt install --only-upgrade intel-microcode
# if updating a frozen pkg too (rare — plan it):  apt-mark unhold <pkg>; apt install --only-upgrade <pkg>; apt-mark hold <pkg>
reboot                                     # microcode + any firmware take effect on boot
```

**Post-boot (custody recovery — do promptly, 30-min keystore window):**
```bash
worker-ctl.sh status                       # all CVMs 'running'
# each keystore restarted → new ephemeral key → new DAO proposal → VOTE within 30 min:
worker-ctl.sh follow mainnet-keystore-0136 # watch "Waiting for DAO approval of proposal #N"
near call dao.outlayer.near vote '{"proposal_id": N, "approve": true}' \
  --accountId owner.outlayer.near --nodeUrl https://rpc.mainnet.fastnear.com
# repeat for testnet-keystore-0136 if used
```

**Verify:**
```bash
curl -s https://a56c7dae3e7fb9f7334a2782366918b627f3a06c-8081.dstack.outlayer.ai/health   # ok
# from coordinator: no fresh "Keystore not ready", /wallet/* returns 200
```

Note: microcode changes the **TCB level**, not MRTD/RTMR — so you refresh **collateral**, you do
**not** re-approve measurements here. If verification post-boot reports the TCB as OutOfDate,
the collateral wasn't current — redo step A and re-register.

---

## C. Redeploy a CVM with a NEW image / compose (measurements change)

Triggered by: new dstack/worker/keystore image version, changed `COMPOSE_NAME`, image digest,
env-var KEYS, compose flags, or vCPU/memory. A new image changes MRTD/RTMR → **new App ID** →
must be approved before it can register.

```bash
# 1. Get the new measurements. The CVM logs them on boot:
#    "📋 Measurements from TDX quote: mrtd=… rtmr0=… rtmr1=… rtmr2=… rtmr3=…"
#    (or compute from the app-compose before deploy).
# 2. Approve on the matching contract (owner-signed):
#    keystore -> dao.outlayer.near ;  worker -> worker.outlayer.near
near call dao.outlayer.near add_approved_measurements \
  '{"measurements":{"mrtd":"…","rtmr0":"…","rtmr1":"…","rtmr2":"…","rtmr3":"…"},"clear_others":false}' \
  --accountId owner.outlayer.near --nodeUrl https://rpc.mainnet.fastnear.com
# 3. Deploy (see 40-deploy-keystore.sh / 40-deploy-worker.sh). Keystore then needs the
#    restart-vote (section B post-boot), workers auto-register once measurements are approved.
```

Reuse rule: same version + same compose + same vCPU/memory → **identical measurements** → already
approved → no step 2 needed. Only a genuine change needs one re-approval.

---

## D. Any plain CVM restart (no image/host change) — keystore only

Stop/start, crash, or dstack bounce. Measurements & collateral unchanged. The **only** action is
the keystore restart-vote (section B post-boot). Workers recover on their own once the keystore is
ready. See the incident note for why the keystore wedges without the vote.

---

## Quick decision guide

- Node package/microcode/firmware update → **B** (full node, reboot, collateral first).
- New CVM image/compose/version → **C** (approve measurements), then B-post-boot for keystore.
- Collateral old / Intel TCB release / weekly → **A** (no restart).
- Something just restarted a CVM → **D** (vote).

## Related
- Host freeze / what's disabled: [node-hardening.md](node-hardening.md)
- Keystore restart wedge + PagerDuty plan: `~/.claude/plans/keystore-restart-pagerduty-alert.md`
- CVM day-2 ops (deploy/logs/stop-start): [cvm-operations.md](cvm-operations.md)
- Contract methods: `keystore-dao-contract/src/lib.rs` (`add_approved_measurements`,
  `update_collateral`), `register-contract/src/lib.rs` (same).
- Collateral scripts: `scripts/fetch_intel_collateral.sh`, `scripts/update_collateral_mainnet.sh`.
