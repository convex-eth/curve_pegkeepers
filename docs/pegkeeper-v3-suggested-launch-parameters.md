# PegKeeper V3 suggested launch parameters and routes

Status: governance launch proposal only. This document does not authorize deployment, allocation, broadcast, or activation.

Implementation:

- Curve ownership proposal: [`../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol`](../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol)
- Mainnet-fork proposal test: [`../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol`](../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol)

`script/DeployPegKeeperV3.s.sol` performs one explicit six-CREATE deployment of the preview module, locked implementation, immutable EIP-1167 factory, two Curve EMA target adapters for USDC/USDT, and one canonical-proxy Chainlink adapter for frxUSD/USD. It uses hardcoded public mainnet configuration and writes every created address to `deployments/mainnet/PegKeeperV3-deployment.json`. The proposal reads those exact dependencies from the file, deploys and funds the three keepers below, registers each with both aggregate monetary policies currently used by crvUSD mint-market Controllers, and leaves all execution directions paused. Activation remains a separate governance step after deployment verification.

## Initial launch scope

Deploy three PegKeeper V3 instances with a plain ERC-20 frxUSD final endpoint:

| Keeper | Target asset | Final token | Endpoint mode | Backing asset | Suggested `maxDeployedCrvUsd` | ControllerFactory debt ceiling |
|---|---|---|---|---|---:|---:|
| frxUSD | frxUSD | frxUSD | vanilla ERC-20 | frxUSD | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDC | USDC | frxUSD | vanilla ERC-20 | frxUSD | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDT | USDT | frxUSD | vanilla ERC-20 | frxUSD | 5,000,000 crvUSD | 5,000,000 crvUSD |

GHO and PYUSD are not included in the initial launch scope. ERC-4626 final endpoints and the Dai/USDS route adapter remain supported by the implementation but are not selected for these three launch keepers.

`maxDeployedCrvUsd` and the ControllerFactory debt ceiling should match at launch. The factory owner must set the intended deployment default before creating each keeper; changing the factory default afterward does not change an existing keeper's local capacity.

Each new V3 is added to `0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251`, used by the eight current mint-market Controllers, and `0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1`, still used by the legacy sfrxETH Controller. Registration occurs only after deployment, policy configuration, and debt-ceiling allocation. Both monetary policies read `debt()`, which returns V3's current `deployedCrvUsd` exposure; the initially paused keepers therefore contribute zero until expansion occurs. Proposal construction verifies that both policies are administered by the Curve Ownership Agent and point to the canonical crvUSD ControllerFactory.

## Shared factory configuration

| Parameter | Suggested value |
|---|---|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| Factory owner | Curve Ownership Agent — `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| `admin()` | Curve Ownership Agent — `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| `emergency_admin()` | Curve Emergency Admin — `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| `fee_receiver()` | crvUSD FeeSplitter — `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| `targetAmmExecutionBufferBps` | `3` bps |
| `minDownstreamAttemptGas` | `1,500,000` gas |
| `fallbackSettlementGasReserve` | `300,000` gas |
| `expansionMaxRouteLossBps` | `5` bps |

The three role and receiver values are live factory policy. Existing V3 keepers created by this factory read them dynamically. Capacity and execution defaults are copied into each keeper at deployment. Every configured Curve swap, including target-AMM legs, uses a `3 bps` total-loss step buffer. Frax mint and redemption steps use `1 bps`. Every configured downstream deployment route uses the `5 bps` complete-route loss limit. Monetary contraction remains subject to its stricter positive normal or early exit-profit floor.

## Common keeper policy

Use the built-in V3 policy defaults for all three keepers:

| Parameter | Value | Human value |
|---|---:|---:|
| `entryMinProfitPpm` | `10` | `0.1` bps retained after keeper reward |
| `normalExitMinProfitPpm` | `1,000` | `10` bps |
| `earlyExitMinProfitPpm` | `5,000` | `50` bps |
| `keeperProfitShareBps` | `3,000` | `30%` of realized profit |
| `minDeploymentTime` | `172,800` seconds | `2 days` |
| `minExpansionAmount` | `10,000e18` | `10,000 crvUSD` |
| `maxKeeperReward` | absent | no flat reward cap |

The keeper reward remains:

```text
keeperReward = floor(realizedProfit * 3,000 / 10,000)
```

## Mandatory oracle and velocity configuration

Every deployment requires nonzero target and final-token adapters. Both launch floors are `0.9997e18`; favorable prices receive no more than par credit. Governance may replace code-bearing adapters and set nonzero floors up to par without resetting velocity pressure. Target failure blocks expansion. Final-token oracle failure retains the acquired target asset rather than entering the expansion route. Contraction and recovery remain available.

| Keeper | Target adapter | Final-token adapter |
|---|---|---|
| frxUSD → frxUSD | Chainlink frxUSD/USD | Chainlink frxUSD/USD |
| USDC → frxUSD | USDC/USDT EMA, USDC orientation | Chainlink frxUSD/USD |
| USDT → frxUSD | USDC/USDT EMA, USDT orientation | Chainlink frxUSD/USD |

Launch oracle pool:

| Pool | Address | Current depth snapshot | EMA window |
|---|---|---:|---:|
| USDC/USDT | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` | approximately `$5.44m` | `866s` |

The USDC/USDT EMA remains a relative target-health check for those two keepers. Route execution remains protected separately by quote floors, measured output, and route-loss limits.

### Selected Chainlink source

The launch proposal selects one direct canonical-proxy Chainlink adapter for frxUSD/USD. It serves as both the frxUSD target check and the final-token check for all three keepers.

| Pair | Canonical ENS | Canonical proxy | Deviation | Heartbeat |
|---|---|---|---:|---:|
| frxUSD/USD | `frxusd-usd.data.eth` | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | 0.5% | 24 hours |

The canonical proxy reports 8 decimals and normalizes to `1e18`. Fork tests confirm direct `latestRoundData()` reads through the proxy. The immutable adapter address therefore remains stable when Chainlink rotates the proxy's underlying aggregator. The unified deployer and proposal require a provisional `26 hours` maximum delay: the listed 24-hour heartbeat plus two hours of grace. Governance must reconfirm this before broadcast.

Every increase to `deployedCrvUsd`, including `expand()` and `claimSurplus()`, shares one keeper-local leaky bucket:

```text
maxBurst = 5% of maxDeployedCrvUsd
fullRefillPeriod = 300 seconds
```

| Keeper | Max burst | Linear refill rate |
|---|---:|---:|
| frxUSD | `125,000 crvUSD` | `25,000 crvUSD/minute` |
| USDC | `125,000 crvUSD` | `25,000 crvUSD/minute` |
| USDT | `250,000 crvUSD` | `50,000 crvUSD/minute` |

Pressure is shared across callers and calls. Splitting cannot bypass it; contraction does not refund it; configuration changes do not reset it; reverted transactions consume nothing.

## Address registry

### Tokens

| Token | Address |
|---|---|
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |
| frxUSD | `0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |

### Venues

| Venue | Address | Coin order / function |
|---|---|---|
| frxUSD/crvUSD target AMM | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | `frxUSD[0], crvUSD[1]` |
| USDC/crvUSD target AMM | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | `USDC[0], crvUSD[1]` |
| USDT/crvUSD target AMM | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | `USDT[0], crvUSD[1]` |
| Curve 3pool | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` | `DAI[0], USDC[1], USDT[2]` |
| Frax frxUSD custodian | `0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c` | USDC → frxUSD mint; frxUSD external-share redemption → USDC |
| USDC/USDT oracle pool | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` | `USDC[0], USDT[1]` |

The Frax custodian is an inventory-backed primary-market venue, not a guaranteed two-way swap. Minting and redemption are separate typed route kinds. Redemption capacity depends on live custodian USDC inventory and any active Frax limits or fees. A successful fork quote does not prove durable capacity.

## Target-AMM configuration

Each target AMM is fixed to its exact target/crvUSD pair:

| Keeper | Expansion target-AMM leg | Target-AMM indices | Buffer |
|---|---|---|---:|
| frxUSD | crvUSD → frxUSD | `1 → 0` | `3` bps |
| USDC | crvUSD → USDC | `1 → 0` | `3` bps |
| USDT | crvUSD → USDT | `1 → 0` | `3` bps |

The target-AMM expansion leg is executed by `expand()` before the configured expansion path. The contraction path includes the final target → crvUSD target-AMM step.

## frxUSD keeper routes

Fixed endpoint configuration:

```text
targetAsset             = frxUSD
backingAsset            = frxUSD
yieldToken              = frxUSD
yieldTokenIsErc4626     = false
```

### Expansion path

The expansion path is empty because the target asset is already the configured final token.

```text
crvUSD → frxUSD through the target AMM
frxUSD remains as final-token backing
```

### Contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | frxUSD/crvUSD target AMM | frxUSD | crvUSD | `0 → 1` | `3` bps |

## USDC keeper routes

Fixed endpoint configuration:

```text
targetAsset             = USDC
backingAsset            = frxUSD
yieldToken              = frxUSD
yieldTokenIsErc4626     = false
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `FRXUSD_MINT` | Frax custodian | USDC | frxUSD | `0 → 0` | `1` bps |

Complete expansion:

```text
crvUSD → USDC through the target AMM
USDC → frxUSD through the Frax custodian
```

### Contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `FRXUSD_REDEEM` | Frax custodian | frxUSD | USDC | `0 → 0` | `1` bps |
| 2 | `CURVE_SWAP` | USDC/crvUSD target AMM | USDC | crvUSD | `0 → 1` | `3` bps |

## USDT keeper routes

Fixed endpoint configuration:

```text
targetAsset             = USDT
backingAsset            = frxUSD
yieldToken              = frxUSD
yieldTokenIsErc4626     = false
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | Curve 3pool | USDT | USDC | `2 → 1` | `3` bps |
| 2 | `FRXUSD_MINT` | Frax custodian | USDC | frxUSD | `0 → 0` | `1` bps |

Complete expansion:

```text
crvUSD → USDT through the target AMM
USDT → USDC through Curve 3pool
USDC → frxUSD through the Frax custodian
```

### Contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `FRXUSD_REDEEM` | Frax custodian | frxUSD | USDC | `0 → 0` | `1` bps |
| 2 | `CURVE_SWAP` | Curve 3pool | USDC | USDT | `1 → 2` | `3` bps |
| 3 | `CURVE_SWAP` | USDT/crvUSD target AMM | USDT | crvUSD | `0 → 1` | `3` bps |

## Suggested activation sequence

Every keeper is deployed fully paused.

1. Verify the implementation core hash, preview-module hash, 45-byte proxy runtime and embedded target, factory, ControllerFactory, oracle pool/orientation, aggregate monetary-policy membership, target AMM, explicit final-token mode, fixed endpoints, path hashes, role getters, fee receiver, local capacity, zero launch pressure, and ControllerFactory debt ceiling.
2. Reconfirm the Frax custodian's `asset()`, external frxUSD share token, `previewDeposit()`, `previewRedeem()`, fees, limits, authorization model, and live USDC redemption inventory at the intended execution block.
3. Run a fork canary for each exact keeper configuration and both route directions. Redemption tests must use an amount within demonstrated live custodian capacity.
4. While global execution remains paused, unpause backing deployment, direct buyback, undeployed-backing contraction, and yield contraction.
5. Unpause global execution.
6. Confirm live previews and execute bounded contraction/maintenance canaries.
7. Unpause expansion last.

Final intended launch state:

```text
allExecutionPaused             = false
expansionPaused                = false
backingDeploymentPaused        = false
directBuybackPaused            = false
undeployedContractionPaused    = false
yieldContractionPaused         = false
```

Any failed endpoint, custodian inventory, fee, limit, authorization, allowance, quote, route, accounting, debt-ceiling, or backing-invariant check leaves expansion paused. The proposal only installs paused keepers; it does not assert that Frax redemption capacity will still exist at activation time.
