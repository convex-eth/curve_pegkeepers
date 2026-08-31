# PegKeeperV3 release checklist

This checklist is for an **undeployed, non-upgradeable EIP-1167 release candidate**. It is not authorization to deploy, broadcast, submit governance, vote, register, unpause, or activate anything.

## 0. Frozen release state

- [x] Production source commit: `b45211758a97d3806bdadba14f4ec2631cd25568`.
- [x] Repository: `git@github.com:convex-eth/curve_pegkeepers.git`.
- [x] Vyper is pinned to `.venv/bin/vyper` version `0.3.10+commit.9136169` with `--optimize codesize`.
- [x] Foundry uses Solidity `0.8.35` and EVM `shanghai`.
- [x] Release manifest status is `release_candidate_not_deployed`.
- [x] Manifest verifier is fail-closed against source provenance, generated artifacts, ABI parity, bytecode sizes/hashes, proxy architecture, both oracle families, test inventory, canary evidence, and undeployed state.
- [x] Deployment addresses, transaction hashes, registration state, and activation state remain empty/false.
- [x] No deployment or governance execution occurred while preparing this package.

Canonical files:

- `deployments/mainnet/PegKeeperV3-release.json`
- `scripts/verify-release-manifest.py`
- `script/PegKeeperV3ReleaseCanary.s.sol`
- `script/DeployPegKeeperV3.s.sol`
- `script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol`

## 1. Architecture and bytecode evidence

### PegKeeper implementation

- [x] Semantic-core runtime: `21,298` bytes.
- [x] Semantic-core hash: `0x7fb0edd85971d51b9e069dd4c3d08c538c7b0197da7ebb7f0771cd98d1b45828`.
- [x] Specialized deployed runtime: `21,330` bytes.
- [x] Refactor regression budget: at most `22,300` bytes.
- [x] EIP-170 headroom: `3,246` bytes.
- [x] Full implementation initcode: `21,484` bytes.
- [x] EIP-3860 headroom: `27,668` bytes.
- [x] Operational initialization is locked on the standalone implementation.
- [x] Keeper ABI is exactly `76 functions / 12 events` and matches `IPegKeeperV3`.

### Preview module

- [x] Canonical source: `src/vyper/PegKeeperV3PreviewModule.vy`, compiled with Vyper `0.3.10 --optimize codesize`.
- [x] Creation code: `6,717` bytes.
- [x] Runtime: `6,680` bytes.
- [x] Runtime hash: `0x4522452266ef8341fd822456f78b2d8978fe2c89c730090ae7932fe822572324`.
- [x] ABI is exactly `3 functions / 0 events` and matches `IPegKeeperV3PreviewModule`.
- [x] Module is stateless.
- [x] Every keeper-dependent preview derives keeper identity from `msg.sender`; no spoofable keeper argument exists.
- [x] Preview projects post-action global backing, oracle health/value, route/fallback branch, and keeper-local velocity.

### Deployment factory

- [x] Specialized runtime: `3,912` bytes.
- [x] Full initcode: `5,376` bytes.
- [x] Factory ABI is exactly `16 functions / 4 events` and matches `IPegKeeperV3Factory`.
- [x] Factory implementation address is immutable after construction.
- [x] No implementation setter or update event exists.
- [x] All seven legacy custom-error selectors are preserved:
  - `NotOwner()` — `0x30cd7471`
  - `NotPendingOwner()` — `0x1853971c`
  - `InvalidOwner()` — `0x49e27cff`
  - `InvalidImplementation()` — `0x68155f9a`
  - `InvalidDefaults()` — `0xa7f2ca4b`
  - `InvalidTargetAmm()` — `0xf871d4c8`
  - `DeploymentFailed()` — `0x30116425`

### EIP-1167 keepers

- [x] Each keeper is a canonical `45`-byte EIP-1167 runtime.
- [x] Factory performs exactly one `CREATE` per keeper.
- [x] Initialization is factory-bound and atomic with proxy creation.
- [x] Failed deployment/initialization does not mutate keeper count, registry, or index state.
- [x] No proxy admin, upgrade slot, implementation setter, or upgrade path exists.
- [x] Semantic CREATE order is fixed:
  1. `frxUSD -> sfrxUSD`
  2. `USDC -> sUSDS`
  3. `USDT -> sUSDS`

## 2. Mandatory unresolved decisions

These are release blockers. The deployer exposes one explicit recommended configuration; hardcoding it does not substitute for governance confirmation.

- [ ] Choose one oracle family for the final proposal and manifest deployment section:
  - Curve StableSwap-NG EMA adapters; or
  - direct canonical Chainlink proxy adapters.
- [ ] If Chainlink is selected, reconfirm or replace the provisional `26 hours` (`93,600` seconds) `maxDelay` for `frxUSD/USD`.
- [ ] If Chainlink is selected, independently reconfirm or replace the provisional `26 hours` (`93,600` seconds) `maxDelay` for `USDS/USD`.
- [ ] Document how the selected `USDS/USD` check is applied to sUSDS economic backing and any required share-to-asset conversion.
- [ ] Confirm the independent USDC and USDT target-health checks; selecting Chainlink for frxUSD/USDS does not remove them.
- [ ] Confirm the hardcoded deployment-factory owner: Curve Ownership Agent `0x40907540d8a6C65c637785e8f8B742ae6b0b9968`.
- [ ] Confirm all shared factory defaults and candidate addresses.
- [ ] Obtain explicit authorization before any broadcast, proposal submission, vote, registration, debt-ceiling update, unpause, or activation.

The checked evidence below proves reproducibility. It does **not** resolve these decisions.

## 3. Oracle-provider validation

Common adapter API:

```solidity
function price() external view returns (uint256);
```

Common policy:

- [x] Adapter must be a nonzero contract; `address(0)` never disables checks.
- [x] Output is normalized to `1e18`.
- [x] Favorable prices are capped in keeper accounting: `effectivePrice = min(price, 1e18)`.
- [x] Launch floor currently encoded by the Curve proposal: `999_700_000_000_000_000`.
- [x] Target-unhealthy expansion reverts.
- [x] Target-healthy/yield-unhealthy expansion retains target as `undeployed_backing`.
- [x] Preview and execution apply the same target-oracle haircut to route-loss and fallback valuation.

### Curve EMA alternative

Candidate pools:

- USDC/USDT: `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85`
- frxUSD/sUSDS: `0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7`
- sfrxUSD/frxUSD: `0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978`

Candidate roles:

- frxUSD target: frxUSD/sUSDS, frxUSD orientation.
- sfrxUSD downstream backing: sfrxUSD/frxUSD, sfrxUSD orientation.
- USDC target: USDC/USDT, USDC orientation.
- USDT target: USDC/USDT, USDT orientation.
- sUSDS downstream backing: frxUSD/sUSDS, sUSDS orientation.

Before selection:

- [ ] Reconfirm pool code, `N_COINS == 2`, coin order, and distinct indices.
- [ ] Reconfirm `price_oracle()` behavior, inversion, and zero-output rejection.
- [ ] Reconfirm rate-provider normalization for yield-bearing pool coins.
- [ ] Record current pool liquidity, recent EMA behavior, and relative-pair contagion risk.
- [ ] Record five deployed adapter addresses and verify their immutable configuration.

### Direct Chainlink proxy alternative

Pinned candidate configuration:

- frxUSD/USD ENS: `frxusd-usd.data.eth`
- frxUSD/USD canonical proxy: `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83`
- frxUSD/USD official deviation threshold: `0.5%`; heartbeat: `86,400` seconds (`24 hours`).
- USDS/USD ENS: `usds-usd.data.eth`
- USDS/USD canonical proxy: `0xfF30586cD0F29eD462364C7e81375FC0C71219b1`
- USDS/USD official deviation threshold: `0.3%`; heartbeat: `86,400` seconds (`24 hours`).
- Provisional frxUSD/USD maximum delay: `93,600` seconds (`26 hours`).
- Provisional USDS/USD maximum delay: `93,600` seconds (`26 hours`).

Before selection:

- [ ] Reconfirm both canonical proxy addresses against Chainlink's official feed listings and ENS records.
- [ ] Reconfirm proxy code, 8-decimal metadata, current positive answer, completed round, update timestamp, and approved freshness window.
- [ ] Record the rationale for each approved `maxDelay`; do not copy one threshold without reviewing both feeds.
- [ ] Record two separately deployed adapter addresses and verify proxy/feed-decimals/max-delay immutables.
- [ ] Confirm every adapter `price()` succeeds through its canonical proxy.
- [ ] Confirm underlying aggregator rotation remains live through the same immutable proxy address.

Fork tests confirm direct `latestRoundData()` reads through both canonical proxies. The access-controlled addresses previously returned by the Feed Registry were underlying OCR aggregators, not the stable consumer-facing proxy endpoints.

## 4. Launch configuration

- [x] frxUSD -> sfrxUSD maximum deployed crvUSD: `2,500,000e18`.
- [x] USDC -> sUSDS maximum deployed crvUSD: `2,500,000e18`.
- [x] USDT -> sUSDS maximum deployed crvUSD: `5,000,000e18`.
- [x] Every keeper starts paused.
- [x] Existing PegKeeperV2 registrations remain untouched.
- [x] No GHO, pyUSD, or USDC -> sfrxUSD keeper is included.
- [x] Every new keeper is registered with both active aggregate monetary policies:
  - `0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251`
  - `0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1`

Keeper-local velocity:

- [x] One global bucket per keeper, shared across callers and exposure-increasing paths.
- [x] `expand()` and `claimSurplus()` charge the same bucket.
- [x] Contraction does not refund pressure.
- [x] Oracle, policy, floor, ceiling, and factory-setting updates do not reset pressure.
- [x] Reverted transactions consume no pressure.
- [x] Launch burst is `5%` of `maxDeployedCrvUsd`.
- [x] Full refill is `300 seconds`.

Launch rates:

| Keeper | Burst | Refill rate |
|---|---:|---:|
| frxUSD -> sfrxUSD | 125,000 crvUSD | 25,000 crvUSD/minute |
| USDC -> sUSDS | 125,000 crvUSD | 25,000 crvUSD/minute |
| USDT -> sUSDS | 250,000 crvUSD | 50,000 crvUSD/minute |

## 5. Reproducible release gates

All checked gates were run against production source commit `b45211758a97d3806bdadba14f4ec2631cd25568`.

```bash
forge fmt --check
git diff --check
forge lint
forge build --sizes
forge test --force --summary
forge test --match-path 'test/PegKeeperV3*Fork.t.sol' -vv
forge test --match-contract PegKeeperV3RuntimeSizeTest -vv
forge test --match-contract PegKeeperV3UnifiedDeploymentTest -vv
forge test --match-contract PegKeeperV3ProposalDeploymentJsonTest -vv
forge script script/PegKeeperV3ReleaseCanary.s.sol:PegKeeperV3ReleaseCanary \
  --fork-url "$ETH_RPC_URL" \
  --fork-block-number 25868730 -vv
PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify-release-manifest.py
```

ABI checks:

```bash
python3 scripts/check-vyper-solidity-abi.py \
  out/PegKeeperV3.vy/PegKeeperV3.json \
  out/IPegKeeperV3.sol/IPegKeeperV3.json
python3 scripts/check-vyper-solidity-abi.py \
  out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json \
  out/IPegKeeperV3Factory.sol/IPegKeeperV3Factory.json
python3 scripts/check-vyper-solidity-abi.py \
  out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json \
  out/IPegKeeperV3PreviewModule.sol/IPegKeeperV3PreviewModule.json
python3 scripts/check-vyper-solidity-abi.py \
  out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json \
  out/IChainlinkStablecoinOracle.sol/IChainlinkStablecoinOracle.json
```

Recorded outcomes:

- [x] `forge fmt --check`: pass.
- [x] `git diff --check`: pass.
- [x] `forge lint`: pass.
- [x] `forge build --sizes`: pass.
- [x] Complete suite: `246 passed, 0 failed, 0 skipped`.
- [x] PegKeeperV3 fork tests: pass.
- [x] Curve adapter unit/deployment/proposal coverage: pass.
- [x] Chainlink adapter unit/deployment/live-proxy fork coverage: pass.
- [x] Unified deployment and chain-bound JSON handoff coverage: pass.
- [x] Actual `DeployPegKeeperV3.run()` mainnet-fork simulation: ten sequential CREATEs, complete JSON output, no broadcast; simulated output removed afterward.
- [x] Mainnet canary at block `25,868,730`: pass with no broadcast.
- [x] Manifest verifier: pass.
- [x] Manifest mutation tests reject wrong proxy, heartbeat, preview artifact, test inventory, direct-read policy, and undeployed-state values; byte-exact restoration passes.

Canary route hashes:

- expansion: `0x44f656895137eb8000021497d6f0e888c645e33302d3f669924f2c690722422f`
- contraction: `0x725f94e6e18aaf43cbc98a5cb47f187661271a0f8d7879a3955ac7817e3ba986`

## 6. Independent review evidence

- [x] Immutable EIP-1167 factory review: no findings; targeted factory suite `19 passed, 0 failed`.
- [x] Chainlink adapter/deployment review: no findings; targeted non-fork suite `8 passed, 0 failed`.
- [x] Preview/execution parity review: no logic finding.
- [x] PegKeeperV3 invariant-helper refactor review: no security or logic findings; frozen source diff `880390b5f2d9d1eec7bbf3e95b98bfb1be4be5262d0f015704fa75e14476feb2`.
- [x] Unified deployment review: no security or logic findings; frozen source diff `031c41652daba68622b3cfe1d816e0d9d63632421487b319494f1d78eeb8e77e`.
- [x] Deployment-visibility correction review: no security or logic findings; frozen source diff `3e3f3231bfbd5f37c3ae8f80e0fd101adc0971b515ed96c69f8a08b38ee96010`.
- [x] Vyper preview semantic-parity and integration reviews: no blocking findings; frozen source diff `2fb94ff190d694b359fd91c9f80ad2ccb6721d9f6ba6f727e56006d38223f5d8`.
- [x] Canonical Chainlink proxy semantic/security and deployment/integration reviews: no blocking findings; frozen source diff `879bfffa66d470cb3c9eacdcef455f8c01156626cb67a8ac85cb1929e2957eb6`.
- [x] Reviewer-identified stale release evidence was resolved by replacing the Solidity-preview and Feed-Registry-era manifest, verifier, and checklist claims with this Vyper/direct-proxy package.
- The final package audit must review the exact frozen evidence diff and be reported with publication; it is not self-certified inside the diff it reviews.

## 7. Pre-broadcast simulation only

Do not add `--broadcast` until all unresolved decisions are checked and explicit authorization exists.

1. Build from the exact production source commit.
2. Run the manifest verifier.
3. Simulate `DeployPegKeeperV3.s.sol` on a fresh mainnet fork with the intended deployment sender and no `--broadcast`.
4. Confirm exactly ten sequential CREATEs: preview module, implementation, factory, five Curve adapters, then two Chainlink adapters.
5. Validate every deployed contract and immutable configuration in simulation, including all factory defaults and both provisional Chainlink delays.
6. Inspect `deployments/mainnet/PegKeeperV3-deployment.json`; confirm chain ID and all ten addresses match the transaction batch.
7. Select and document one coherent oracle family for the keeper proposal. Deploying both alternatives does not select one.
8. Re-run the current-block canary and complete test suite.
9. Independently review the complete transaction batch and deployment JSON.
10. Add `--broadcast` only after explicit authorization and with the same reviewed sender/configuration.

## 8. Proposal simulation

Required proposal input:

```text
deployments/mainnet/PegKeeperV3-deployment.json
```

The proposal rejects a deployment file whose `chainId` differs from the active chain and then validates the factory, implementation, preview module, and selected Curve adapters on-chain before building calldata.

Before proposal submission:

- [ ] Confirm every candidate address and code hash from an independent source.
- [ ] Confirm the selected oracle family is wired coherently; do not mix providers accidentally.
- [ ] Recompute the three factory CREATE addresses from the final factory nonce.
- [ ] Confirm semantic keeper order and names.
- [ ] Confirm all three keepers remain paused after execution.
- [ ] Confirm exact debt ceilings and both monetary-policy registrations.
- [ ] Simulate the full proposal from a fresh pinned mainnet fork.
- [ ] Have a reviewer compare decoded calldata against the approved checklist.
- [ ] Record proposal identifier only after authorized submission.

## 9. Post-deployment verification and activation

After an authorized deployment—but before registration or activation:

- [ ] Record preview module, implementation, factory, oracle, and keeper addresses.
- [ ] Record transaction hashes and deployment block.
- [ ] Verify source and bytecode against this package.
- [ ] Confirm each keeper proxy runtime is canonical EIP-1167 and points to the pinned implementation.
- [ ] Confirm each keeper is initialized once, correctly indexed, and paused.
- [ ] Confirm owner, emergency admin, fee receiver, routes, policies, oracle floors, velocity, and capacities.
- [ ] Re-run live read-only previews and accounting invariants.
- [ ] Obtain explicit governance approval for registration/debt-ceiling actions.
- [ ] Register and set debt ceilings only through the approved proposal.
- [ ] Keep activation/unpause as a separate explicit decision after monitoring and review.

Stopping after deployment is valid. Stopping after registration while paused is valid. Unpausing without a separate explicit decision is not.
