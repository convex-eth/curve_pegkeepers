# PegKeeper V3 release and deployment checklist

Status: release candidate; no transaction has been broadcast.

Canonical candidate manifest: [`../deployments/mainnet/PegKeeperV3-release.json`](../deployments/mainnet/PegKeeperV3-release.json)

## Verified release gates

- [x] Production source pins Vyper `0.3.10` and Foundry uses `.venv/bin/vyper` with `optimize = "codesize"`.
- [x] `forge fmt --check`, `git diff --check`, `forge lint`, and `forge build` pass.
- [x] Full unit, fuzz, historical-fork, and live-integration suite passes.
- [x] Vyper/Solidity ABI parity: 62 functions and 11 events. Factory/interface parity: 17 functions and 5 events.
- [x] Constructor-specialized PegKeeper runtime is `22,843` bytes, `1,733` bytes below EIP-170; the compiler runtime template reported by `forge build --sizes` is `22,587` bytes.
- [x] PegKeeper full initcode including all seven static constructor arguments is `24,351` bytes, `24,801` bytes below EIP-3860.
- [x] The EIP-5202 blueprint runtime is `24,130` bytes, `446` bytes below EIP-170. The factory runtime is `4,655` bytes, `19,921` bytes below EIP-170.
- [x] Independent lifecycle/policy, expansion-preview, keeper-economics, impairment-recovery, size-remediation, frxUSD mint-adapter, immutable-factory, and dynamic factory-role reviews returned PASS.
- [x] RED/GREEN deployment tests prove the seven-field constructor and EIP-5202 factory tuples, fixed endpoints, live factory admin/emergency-admin/fee-receiver resolution, immediate old-role revocation, one-based identity, fully paused startup, future-only implementation selection, and runtime bounds.
- [x] Current-mainnet canary passed at block `25,860,454` through USDT → DAI → USDS → sUSDS, quoted `9,994.518945799771997140` crvUSD from the complete reverse route for one-tenth of the received shares, and left no residual route allowances.
- [x] Pinned-mainnet frxUSD canary passed at block `25,857,270`: a full V3 expansion deposited `100,100` USDC through the live Frax custodian, minted `100,100` frxUSD, acquired sfrxUSD through Curve, preserved measured backing accounting, and cleared both route allowances.
- [x] Candidate expansion and contraction path hashes are recorded in the manifest.
- [x] No credentials or private keys are stored in the repository or manifest.

## Operator decisions required before deployment

These are governance decisions. They are deliberately not guessed by the release package.

- [ ] Confirm the deployment-factory `owner`.
- [ ] Confirm the shared `feeReceiver`, governance `admin`, and distinct `emergencyAdmin` dynamically resolved by every factory-created V3.
- [ ] Select default `maxDeployedCrvUsd`.
- [ ] Select the initial ControllerFactory debt ceiling/allocation.
- [ ] Confirm the exact EIP-5202 blueprint runtime hash before initial factory deployment and every future implementation update.
- [ ] Refresh `docs/pegkeeper-v3-routing-and-path-costs.md` at a new pinned block and reject any route whose target-AMM or downstream ladder reaches nonlinear impact below the proposed capacity.
- [ ] For any frxUSD-mint route, re-read the proxy implementation, `asset()`, `frxUSD()`, `mintFee()`, `mintCap()`, `frxUSDMinted()`, and `maxDeposit()`; keep configured capacity below the refreshed mint limit.
- [ ] Approve the expansion and contraction path hashes in the manifest.
- [ ] Calibrate and approve `targetAmmExecutionBufferBps`.
- [ ] Calibrate and approve each route step's `executionBufferBps`.
- [ ] Calibrate and approve `expansionMaxRouteLossBps`.
- [ ] Benchmark and approve `minDownstreamAttemptGas` and `fallbackSettlementGasReserve` with the intended keeper transaction gas limit.
- [ ] Decide which contraction directions, if any, should be enabled at activation. Expansion should be enabled last.

The initial release does **not** expose or register a Curve-router `get_dy`/`exchange` adapter for direct buyback. Direct buyback remains the explicit `buyback()` surface returning only the fixed yield token. Router registration can be proposed later without changing V3 custody or accounting.

## Reproducible pre-broadcast gates

Run from the repository root:

```bash
make setup
forge fmt --check
git diff --check
forge lint
forge build
forge build --sizes
python3 scripts/verify-release-manifest.py
make test
```

Run a fresh current-state mainnet canary immediately before broadcast:

```bash
ETH_RPC_URL=https://your-mainnet-rpc.example \
forge script script/PegKeeperV3ReleaseCanary.s.sol:PegKeeperV3ReleaseCanary \
  --rpc-url "$ETH_RPC_URL" -vv
```

The canary is simulation-only. It uses local fork state overrides and never calls `startBroadcast()`.

## Deployment simulation

Deploy the immutable creation-code blueprint and owner-gated deployment factory with explicit shared defaults:

```bash
export PKV3_DEPLOYMENT_FACTORY_OWNER=0x...
export PKV3_CONTROLLER_FACTORY=0x...
export PKV3_ADMIN=0x...
export PKV3_EMERGENCY_ADMIN=0x...
export PKV3_FEE_RECEIVER=0x...
export PKV3_MAX_DEPLOYED_CRVUSD=...
export PKV3_TARGET_AMM_BUFFER_BPS=...
export PKV3_MIN_DOWNSTREAM_ATTEMPT_GAS=...
export PKV3_FALLBACK_GAS_RESERVE=...
export PKV3_EXPANSION_MAX_ROUTE_LOSS_BPS=...

forge script script/DeployPegKeeperV3Factory.s.sol:DeployPegKeeperV3Factory \
  --rpc-url "$ETH_RPC_URL" -vv
```

Check the returned blueprint and factory addresses, blueprint preamble/hash, owner, ControllerFactory, implementation pointer, zero keeper count, and every stored default. The script rejects an oversized blueprint or mismatched factory state. Validate the complete configuration before adding `--broadcast`: blueprint and factory creation are separate transactions, so a later factory-constructor failure could otherwise leave an unused blueprint deployment.

The factory owner then calls `deployPegKeeper(targetAmm, yieldToken, expansionSteps, contractionSteps)`. The factory derives target/backing assets, assigns the next index, deploys from the current blueprint, snapshots deployment-only capacity and execution defaults, installs routes/configuration, and records the fully paused keeper atomically. The keeper stores no local admin, emergency-admin, or fee-receiver state; it resolves those shared values from the deployment factory on every use.

## Broadcast and activation

Do not combine deployment with activation.

1. [ ] Obtain explicit authorization for the exact blueprint hash, factory constructor tuple, factory bytecode hash, shared PegKeeper roles/fee receiver, deployment defaults, target AMM, yield token, and route hashes.
2. [ ] Re-run the current-block canary and all release gates from a clean checkout.
3. [ ] Validate every factory input before broadcast, then add wallet configuration and `--broadcast` only after authorization.
4. [ ] Record the blueprint and factory transactions, addresses, blocks, constructor arguments, source hashes, bytecode hashes, and deployed-code hashes in the manifest.
5. [ ] Verify the exact Solidity factory and Vyper creation blueprint sources and compiler settings on the selected explorer.
6. [ ] Confirm factory owner, implementation, shared roles/fee receiver, deployment defaults, and zero initial keeper count against the manifest.
7. [ ] Authorize the factory-owner call for the exact target AMM, yield token, expansion route, and contraction route.
8. [ ] Record the PegKeeper deployment transaction, address, index/name, blueprint provenance, constructor-specialized code hash, and emitted route hashes.
9. [ ] Confirm every PegKeeper getter, including the deployment-factory and ControllerFactory references plus live role/receiver getters, path hash, and pause flag against the manifest.
10. [ ] PegKeeper governance calls `set_policy` only if the built-in policy defaults are not approved.
11. [ ] ControllerFactory governance sets the approved debt ceiling/allocation.
12. [ ] Re-run read-only previews and current-state route canaries against the deployed address.
13. [ ] Enable approved contraction/maintenance directions first.
14. [ ] Enable global execution only after monitoring and emergency procedures are live.
15. [ ] Enable expansion last.
16. [ ] Update the manifest from `release_candidate_not_deployed` to the actual deployment state.

## Post-activation checks

- [ ] `trusted_backing_value() >= deployed_crvusd()`.
- [ ] Accounted target and yield units do not exceed actual balances.
- [ ] All target-AMM and typed-route allowances are zero after each operation.
- [ ] `last_expansion_at` changes only on successful expansion.
- [ ] Keeper rewards match the configured percentage of realized profit and selected branch token.
- [ ] Factory ceiling and local `max_deployed_crvusd` match governance records.
- [ ] Emergency admin can pause but cannot unpause or execute recovery calls.
- [ ] Alerts cover backing invariant failure, route failure/fallback rate, allowance residue, pause changes, role changes, target-AMM changes, frxUSD-minter proxy/fee/cap changes, and exposure ceilings.
