# PegKeeperV3 release checklist

This is an **undeployed, non-upgradeable EIP-1167 release candidate**. It does not authorize deployment, broadcast, proposal submission, registration, debt-ceiling changes, unpause, or activation.

## 0. Frozen source

- [x] Repository: `git@github.com:convex-eth/curve_pegkeepers.git`.
- [x] Production source commit: `24a18f89c13bc912b361f6db92327150e088efa8`.
- [x] Exact pre-commit staged source diff SHA-256: `5a3521f759b4ddbb8f3ad334b1bb7310202dbf36e34b1f790f514034026d26e8`.
- [x] Source commit is pushed to `origin/main`.
- [x] Evidence is regenerated from the exact production source commit.
- [x] Evidence drift is restricted to:
  - `deployments/mainnet/PegKeeperV3-release.json`;
  - `docs/pegkeeper-v3-release-checklist.md`;
  - `scripts/verify-release-manifest.py`.
- [x] Deployment state remains empty: no candidate addresses, transaction hashes, verification, registration, or activation.

## 1. Toolchain and build

- [x] Solidity: `0.8.35`.
- [x] Vyper: `0.3.10+commit.9136169` at `.venv/bin/vyper`.
- [x] Vyper optimizer: `codesize`.
- [x] EVM target: `shanghai`.
- [x] Forge: `1.7.1`.
- [x] `forge fmt --check` passed.
- [x] `git diff --check` passed.
- [x] `forge lint` passed.
- [x] Forced build passed.

## 2. Final artifacts

### PegKeeperV3 implementation

- [x] Source SHA-256: `2e69fdbb01e8e0916adb23b6f7309bf1af1544483ed96217011c7d8d61e94dda`.
- [x] Compiler creation code: `23,915` bytes.
- [x] Compiler creation keccak: `0x8797ee4ac0b2e1fb4050314a7c3d5594223122a39114ae49a728ed023d9cc6c7`.
- [x] Full initcode with constructor argument: `23,947` bytes; EIP-3860 margin `25,205` bytes.
- [x] Semantic runtime core: `23,761` bytes.
- [x] Semantic runtime keccak: `0x83d97e75622beff4a7f7bad21cb00cd2f9685b4e57eae25988caeb3834e62662`.
- [x] Deployed runtime with immutable preview address: `23,793` bytes; EIP-170 margin `783` bytes.
- [x] ABI parity: `80` functions and `13` events.
- [x] Locked implementation cannot be operationally initialized.

### Preview module

- [x] Source SHA-256: `b569039101a69843e14c261802d938c819d22478dffd28046c85264aecf733e0`.
- [x] Runtime: `8,185` bytes; EIP-170 margin `16,391` bytes.
- [x] Runtime keccak: `0xc694c013b8b5e80960fe97a258244d8a14d22db89a1f481e16cf9eeaa245240c`.
- [x] ABI parity: `3` functions and no events.
- [x] Stateless and keeper-identity-bound.

### Factory

- [x] Source SHA-256: `2f3cafdf075556fc3c294c8a133c805c20205734f5d593c48c63bba939c53868`.
- [x] Compiler creation code: `5,113` bytes.
- [x] Full initcode with constructor arguments: `5,465` bytes.
- [x] Deployed runtime with immutables: `3,985` bytes.
- [x] ABI parity: `16` functions and `4` events.
- [x] Implementation binding is immutable and no implementation setter exists.
- [x] Each keeper uses one checked EIP-1167 `CREATE` followed by atomic initialization.

## 3. Endpoint and route semantics

- [x] Final-token endpoint mode is explicit at factory deployment; no interface probing is used.
- [x] Vanilla ERC-20 mode uses identity token-unit/backing-asset conversion.
- [x] ERC-4626 mode uses `convertToAssets()` and `convertToShares()`.
- [x] Intermediate ERC-4626 route steps remain supported independently of persistent endpoint mode.
- [x] Shared `targetAsset == finalToken` inventory is counted once in nominal and oracle backing values.
- [x] Empty expansion is accepted only when target and final tokens are identical; contraction remains independently validated.
- [x] Frax mint is route kind `4`; Frax redemption is distinct route kind `5`; unsupported kinds start at `6`.
- [x] Successful routed-expansion rewards are denominated in configured final-token units.
- [x] Direct-buyback unit sizing uses vanilla identity conversion or ERC-4626 share conversion as configured.
- [x] Dai/USDS and ERC-4626 route support remains compiled and tested but is not selected for this launch.

## 4. Selected undeployed launch

All keepers use plain frxUSD as final token and start fully paused.

1. `frxUSD -> frxUSD`, cap `2,500,000 crvUSD`
   - expansion: empty identity route;
   - contraction: `frxUSD -> crvUSD` through the target AMM.
2. `USDC -> frxUSD`, cap `2,500,000 crvUSD`
   - expansion: Frax `USDC -> frxUSD` mint;
   - contraction: Frax `frxUSD -> USDC` redemption, then target AMM to crvUSD.
3. `USDT -> frxUSD`, cap `5,000,000 crvUSD`
   - expansion: 3pool `USDT -> USDC`, then Frax mint;
   - contraction: Frax redemption, reverse 3pool `USDC -> USDT`, then target AMM to crvUSD.

- [x] Curve swap and target-AMM tolerance: `3 bps`.
- [x] Frax mint/redemption tolerance: `1 bps`.
- [x] ERC-4626 deposit/redeem support tolerance: `1 bps`.
- [x] Dai/USDS conversion tolerance: `0 bps`.
- [x] Complete expansion/downstream route loss bound: `5 bps`.
- [x] Monetary contraction uses positive exit-profit floors, not a general route-loss allowance.
- [x] Velocity: `5%` burst, `300` seconds full refill, shared by exposure-increasing paths.

## 5. Oracles

- [x] USDC target health: USDC/USDT Curve EMA, inverted as required by coin order.
- [x] USDT target health: USDT/USDC Curve EMA.
- [x] frxUSD target/final-token health: canonical `frxusd-usd.data.eth` Chainlink proxy `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83`.
- [x] Chainlink adapter reads the proxy directly and tolerates underlying aggregator rotation.
- [x] Feed decimals: `8`.
- [x] Provisional `maxDelay`: `93,600` seconds.
- [ ] Governance must reconfirm the proxy, feed metadata, positive completed round, and `maxDelay` immediately before broadcast.

## 6. Verification evidence

- [x] Full forced suite: `289 passed`, `0 failed`, `0 skipped`.
- [x] Stateful invariants: all six campaigns passed at `256` runs × `500` calls.
- [x] All focused endpoint, Frax redemption, deployment, proposal, fork, and rollback suites passed.
- [x] ABI parity passed for implementation, Factory, preview module, Curve oracle, and Chainlink oracle.
- [x] Runtime-size and pinned code-identity tests passed.
- [x] Unified no-broadcast deployment simulation passed and its temporary JSON was validated then removed.
- [x] Pinned mainnet canary passed at block `25,868,730` with no broadcast:
  - crvUSD sold: `100000000000000000000000`;
  - frxUSD received: `100016620117244135933000`;
  - contraction quote input: `10001662011724413593300` frxUSD;
  - contraction quote output: `9999492700894871027318` crvUSD;
  - expansion path hash: `0x17600eb74b28066eb62f0c63fd46e6e6352fd34efb7b7c8415971240b25e7f9d`;
  - contraction path hash: `0x61b682ab566b6d45ed43332470c1e8c2e635e328d857df01aa06052fb1f095f1`.
- [x] Independent review confirmed the NatSpec source change is documentation-only, ABI-safe, accurate, and has no blocker.
- [x] Independent bounded reviews found no protocol-level source blocker and no launch-policy/proposal-wiring blocker.
- [x] This regenerated evidence package is subject to a final exact staged-diff audit.
- [x] Manifest mutation tests rejected top-level schema drift, test-count drift, endpoint-mode drift, Frax redemption-buffer drift, adapter-count drift, deployed-state drift, canary-hash drift, and activation-blocker drift; byte-exact restoration passed.

## 7. Deployment package

The hardcoded deployer performs six monotonic CREATEs:

1. preview module;
2. locked implementation;
3. Factory;
4. USDC Curve target oracle;
5. USDT Curve target oracle;
6. frxUSD Chainlink oracle.

- [x] Deployer and proposal contain no environment-driven production inputs.
- [x] Proposal consumes the chain-bound deployment JSON and validates candidate identities before use.
- [x] USDS deployment/oracle evidence is not required for this launch.
- [x] No deployment JSON exists in the release package.
- [x] No deployment or governance transaction has been broadcast.

## 8. Activation blockers

- [ ] Reconfirm frxUSD Chainlink proxy, metadata, round health, and delay bound.
- [ ] Reconfirm Curve EMA pool code, coin order, orientation, and behavior.
- [ ] Reconfirm Frax custodian endpoints, fees, limits, authorization, preview behavior, and live USDC inventory.
- [ ] Run an inventory-bounded current-block Frax redemption execution canary before enabling either redemption route.
- [ ] Obtain explicit approval for Factory defaults, candidate addresses, debt ceilings, policy registration, and activation order.
- [ ] Run every release gate and a fresh current-block canary from the production source commit immediately before broadcast.

The pinned-block custodian inventory observation is not an activation guarantee. The current release stays undeployed and every keeper starts paused.

## 9. Operator sequence after explicit authorization

1. Check out `24a18f89c13bc912b361f6db92327150e088efa8` and verify the evidence commit changes only the three evidence files.
2. Run `make check` and the current-block no-broadcast canary.
3. Run the unified deployer without broadcast from the intended deployment sender; inspect and remove the temporary deployment JSON if the run is rejected.
4. Reconfirm all hardcoded addresses, code hashes, nonces, oracle health, Frax capacity, and policy/cap values.
5. Only after separate explicit authorization, broadcast the deployment.
6. Verify deployed code, immutables, ownership, Factory defaults, and JSON provenance before constructing governance calldata.
7. Simulate the exact proposal against the deployed candidates; keep all execution directions paused.
8. Submit, vote, register, fund, and activate only under separate governance authorization and a staged risk plan.
