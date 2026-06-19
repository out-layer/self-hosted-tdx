# Mainnet launch — self-hosted TDX worker

Replicate the self-hosted TDX worker on **mainnet** (`worker.outlayer.near` /
`outlayer.near`). The full flow is already proven on **testnet** (done 2026-06-17 —
worker `cd009b5b`, FMSPC `B0C06F000000`, registered + executing). This is the mainnet
version of that flow. References: [`cvm-operations.md`](cvm-operations.md) (day-2 ops),
`~/.claude/plans/outlayer-worker-resume.md` (testnet checkpoint + gotchas),
`register-contract/`, `scripts/update_collateral.sh`, `scripts/deploy_phala.sh`,
`deploy/self-hosted-tdx/40-deploy-worker.sh`.

## ⚠️ The one risky step

`worker.outlayer.near` is the **LIVE production register-contract** the Phala fleet
depends on. Mainnet currently runs the OLD single-collateral contract
(`quote_collateral: Option<String>`). Upgrading it to the multi-collateral + FMSPC-match
build requires a **state migration on a live contract** — if it breaks, Phala workers
can't register. Treat task 1 as the high-blast-radius step; everything else is additive.

Already-shipped code (no rewrite needed, just deploy): multi-collateral
(`collaterals: Vec<String>`), `update_collateral(collateral, index)`, FMSPC-match
single-verify in `register_worker_key`, and `migration.rs` (`RegisterContractV2`:
old `quote_collateral` → `collaterals[0]`).

## Prerequisites (already in place on the node)

- TDX host + PCCS live; dstack vmm (`:11000`) + per-node KMS-as-CVM running (network-agnostic — reused for mainnet).
- Testnet worker CVM still running (mainnet worker is a SEPARATE CVM; node has 512 GB RAM, both coexist).
- Owner key for `owner.outlayer.near` and a full-access key for `worker.outlayer.near` in the legacy keychain.

## Tasks

### 0. Pre-flight validation (do BEFORE touching mainnet)
- [ ] On **testnet**, force a **Phala** worker to re-register against the already-deployed
      FMSPC-match contract (restart it) and confirm it still registers via **slot 0**
      (FMSPC `20a06f000000`). This is the only path not yet battle-tested live — the code
      is symmetric with our slot-1 path, but validate before migrating prod.
- [ ] Confirm the current mainnet contract layout matches what `migration.rs`
      (`RegisterContractV2`) expects: `owner_id, init_worker_account, approved_measurements,
      quote_collateral, outlayer_contract_id`. View mainnet state / diff against the
      git version deployed there. A layout mismatch = corrupted migrate.

### 1. Upgrade the register-contract on `worker.outlayer.near` (migrate)
- [ ] `cd register-contract && ./build.sh` → `res/register_contract.wasm`
      (current FMSPC-match SHA-256 `06148cb0…`; rebuild to be current).
- [ ] Deploy **with the migrate call** (NOT `without-init-call` — the struct layout changes
      vs the old mainnet contract):
      ```bash
      near contract deploy worker.outlayer.near \
        use-file register-contract/res/register_contract.wasm \
        with-init-call migrate json-args '{}' prepaid-gas '300.0 Tgas' attached-deposit '0 NEAR' \
        network-config mainnet sign-with-legacy-keychain send
      ```
- [ ] Verify post-migrate: `get_collaterals()` → Phala collateral preserved in **slot 0**;
      `get_approved_measurements`/owner/init_worker_account unchanged; Phala worker can still
      register (re-run the testnet-style check against mainnet, or watch a Phala worker restart).

### 2. Cache OUR collateral in slot 1
- [ ] (Re)generate our `B0C06F000000` collateral ON THE NODE (collateral is platform/FMSPC-
      specific, not network-specific — same procedure as testnet; regenerate fresh in case
      Intel TCB advanced):
      ```bash
      PCCS_URL=https://localhost:8081 /home/outlayer/dcap-qvl/cli/target/release/dcap-qvl \
        verify --hex <worker-quote.hex>   # writes /tmp/our_collateral.json ; confirm fmspc=B0C06F000000
      ```
- [ ] Owner caches it in slot 1:
      ```bash
      ./scripts/update_collateral.sh our_collateral.json 1 mainnet   # -> worker.outlayer.near, signer owner.outlayer.near
      ```

### 3. Deploy the mainnet worker CVM
- [ ] `cp deploy/self-hosted-tdx/worker/worker.env.template worker.env` and set MAINNET values
      (diff against the testnet worker.env):
      - `API_BASE_URL=https://api.outlayer.fastnear.com`
      - `NEAR_RPC_URL=https://rpc.mainnet.fastnear.com`
      - `OFFCHAINVM_CONTRACT_ID=outlayer.near`
      - `OPERATOR_ACCOUNT_ID=worker.outlayer.near`
      - `INIT_ACCOUNT_ID=init-worker.outlayer.near` + `INIT_ACCOUNT_PRIVATE_KEY` (full-access key;
        the contract requires the register caller == `init_worker_account` — confirm via
        `get_init_worker_account` on `worker.outlayer.near`)
      - mainnet `KEYSTORE_BASE_URL` / `KEYSTORE_AUTH_TOKEN` / `API_AUTH_TOKEN` (secrets)
- [ ] Deploy (same v0.1.35 prod image as Phala; use a distinct `APP_NAME`, e.g. `outlayer-worker-mainnet`,
      so it doesn't collide with the testnet CVM):
      ```bash
      APP_NAME=outlayer-worker-mainnet ./deploy/self-hosted-tdx/40-deploy-worker.sh v0.1.35
      ```
      (Env is KMS-encrypted, NOT baked into the measured compose.)

### 4. Approve the mainnet worker's measurements
- [ ] First boot will fail "measurements not approved". Harvest the worker's 5 measurements
      (MRTD + RTMR0–3) from its logs (see cvm-operations.md — discover the agent port, container
      `dstack-worker-1`). NOTE: if the mainnet compose/image is byte-identical to testnet's, the
      measurements are likely identical — but re-harvest, don't assume.
- [ ] Owner approves on `worker.outlayer.near`:
      ```bash
      near contract call-function as-transaction worker.outlayer.near add_approved_measurements \
        json-args '{"measurements":{"mrtd":"…","rtmr0":"…","rtmr1":"…","rtmr2":"…","rtmr3":"…"}}' \
        prepaid-gas '100 Tgas' attached-deposit '0 NEAR' \
        sign-as owner.outlayer.near network-config mainnet sign-with-legacy-keychain send
      ```

### 5. Verify registration + end-to-end
- [ ] Restart the mainnet worker CVM → it does ONE FMSPC-matched verify (slot 1) → registers.
      Confirm `✅ Worker key registered successfully!` + tx hash; the worker's key appears on
      `worker.outlayer.near` (FunctionCall → outlayer.near); worker enters the event loop.
- [ ] Run a REAL mainnet execution request end-to-end and confirm `resolve_execution` success.
      ⚠️ Mainnet charges real stablecoins/NEAR — start with a trivial request.

## Mainnet-specific cautions
- **Real money**: executions are billed for real. Test with minimal-cost requests first.
- **NEAR Intents EXIST on mainnet** (testnet has none). If the worker workload touches intents,
  mainnet is the first place that path actually runs — validate intents flows separately.
- **Coexistence with Phala prod**: the migrated contract must keep Phala (slot 0) registering.
  FMSPC-match routes Phala quotes to slot 0; our worker to slot 1. Verify both after the migrate.
- **Day-2 gotchas** (from testnet, see cvm-operations.md): stop/start reassigns the guest-agent
  host port AND can leak a stale qemu (uuid not in `lsvm`); worker log container = `dstack-worker-1`.

## Open questions to confirm before executing
- Is mainnet `worker.outlayer.near` definitely still on the OLD single-collateral contract?
  (If someone already migrated it, task 1 differs.) — VERIFY first.
- One mainnet worker CVM, or replace/retire the testnet one? (Plan assumes a separate, coexisting CVM.)
- Does the mainnet worker reuse the existing keystore, or need a mainnet keystore endpoint?
