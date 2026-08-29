# PegKeeper V3 release and deployment checklist

Status: release candidate; no transaction has been broadcast.

Canonical candidate manifest: [`../deployments/mainnet/PegKeeperV3-release.json`](../deployments/mainnet/PegKeeperV3-release.json)

## Verified release gates

- [x] Production source pins Vyper `0.3.10` and Foundry uses `.venv/bin/vyper` with `optimize = "codesize"`.
- [x] `forge fmt --check`, `git diff --check`, `forge lint`, and `forge build` pass.
- [x] Full unit, fuzz, historical-fork, and live-integration suite passes.
- [x] Vyper/Solidity ABI parity: 62 functions and 13 events.
- [x] Constructor-specialized deployed runtime is `22,077` bytes, `2,499` bytes below EIP-170; the compiler runtime template reported by `forge build --sizes` is `21,853` bytes.
- [x] Full initcode including all nine static constructor arguments is `23,433` bytes, `25,719` bytes below EIP-3860.
- [x] Independent lifecycle/policy, expansion-preview, size-remediation, and frxUSD mint-adapter reviews returned PASS.
- [x] Deployment script has a RED/GREEN test proving the constructor tuple, fixed endpoints, roles, capacity, fully paused startup, and runtime bound.
- [x] Current-mainnet canary passed at block `25,857,968` through USDT → DAI → USDS → sUSDS, quoted `9,994.628476759022303461` crvUSD from the complete reverse route for one-tenth of the received shares, and left no residual route allowances.
- [x] Pinned-mainnet frxUSD canary passed at block `25,857,270`: a full V3 expansion deposited `100,100` USDC through the live Frax custodian, minted `100,100` frxUSD, acquired sfrxUSD through Curve, preserved measured backing accounting, and cleared both route allowances.
- [x] Candidate expansion and contraction path hashes are recorded in the manifest.
- [x] No credentials or private keys are stored in the repository or manifest.

## Operator decisions required before deployment

These are governance decisions. They are deliberately not guessed by the release package.

- [ ] Confirm `feeReceiver`.
- [ ] Confirm governance `admin` and distinct `emergencyAdmin`.
- [ ] Select `maxDeployedCrvUsd`.
- [ ] Select the initial Factory debt ceiling/allocation.
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

Set all constructor values explicitly; there are no defaults:

```bash
export PKV3_FACTORY=0x...
export PKV3_TARGET_AMM=0x...
export PKV3_TARGET_ASSET=0x...
export PKV3_BACKING_ASSET=0x...
export PKV3_YIELD_TOKEN=0x...
export PKV3_FEE_RECEIVER=0x...
export PKV3_ADMIN=0x...
export PKV3_EMERGENCY_ADMIN=0x...
export PKV3_MAX_DEPLOYED_CRVUSD=...

forge script script/DeployPegKeeperV3.s.sol:DeployPegKeeperV3 \
  --rpc-url "$ETH_RPC_URL" -vv
```

Check the returned address and constructor getters. The deployment script rejects a runtime over EIP-170, mismatched constructor state, or any deployment that starts with an enabled direction.

## Broadcast and activation

Do not combine deployment with activation.

1. [ ] Obtain explicit authorization for the exact constructor tuple, compiler creation-bytecode hash, and resulting full initcode hash.
2. [ ] Re-run the current-block canary and all release gates from a clean checkout.
3. [ ] Add wallet configuration and `--broadcast` to the deployment command only after authorization.
4. [ ] Record the deployment transaction hash, deployed address, block, compiler settings, constructor arguments, source hash, compiler creation-bytecode hash, full initcode hash, runtime-template hash, and actual constructor-specialized deployed-code hash in the manifest.
5. [ ] Verify the exact Vyper source, constructor arguments, and `codesize`/Shanghai compiler settings on the selected explorer.
6. [ ] Confirm every getter and all pause flags against the manifest.
7. [ ] Governance calls `set_policy`, if defaults are not approved.
8. [ ] Governance calls `setPaths` and verifies emitted path hashes against the manifest.
9. [ ] Governance calls `set_expansion_config` with approved target buffer and gas values.
10. [ ] Factory governance sets the approved debt ceiling/allocation.
11. [ ] Re-run read-only previews and current-state route canaries against the deployed address.
12. [ ] Enable approved contraction/maintenance directions first.
13. [ ] Enable global execution only after monitoring and emergency procedures are live.
14. [ ] Enable expansion last.
15. [ ] Update the manifest from `release_candidate_not_deployed` to the actual deployment state.

## Post-activation checks

- [ ] `trusted_backing_value() >= deployed_crvusd()`.
- [ ] Accounted target and yield units do not exceed actual balances.
- [ ] All target-AMM and typed-route allowances are zero after each operation.
- [ ] `last_expansion_at` changes only on successful expansion.
- [ ] Keeper rewards match the configured percentage/cap and selected branch token.
- [ ] Factory ceiling and local `max_deployed_crvusd` match governance records.
- [ ] Emergency admin can pause but cannot unpause or execute recovery calls.
- [ ] Alerts cover backing invariant failure, route failure/fallback rate, allowance residue, pause changes, role changes, target-AMM changes, frxUSD-minter proxy/fee/cap changes, and exposure ceilings.
