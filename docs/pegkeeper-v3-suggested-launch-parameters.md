# PegKeeper V3 suggested launch parameters and routes

Status: governance launch proposal only. This document does not authorize deployment, allocation, broadcast, or activation.

Implementation:

- Curve ownership proposal: [`../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol`](../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol)
- Mainnet-fork proposal test: [`../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol`](../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol)

The proposal expects an audited, fresh deployment factory in `PKV3_FACTORY`. It deploys and funds the three keepers below while leaving all execution directions paused. Activation remains a separate governance step after deployment verification.

## Initial launch scope

Deploy three PegKeeper V3 instances:

| Keeper | Target asset | Yield token | Backing asset | Suggested `maxDeployedCrvUsd` | ControllerFactory debt ceiling |
|---|---|---|---|---:|---:|
| frxUSD | frxUSD | sfrxUSD | frxUSD | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDC | USDC | sUSDS | USDS | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDT | USDT | sUSDS | USDS | 5,000,000 crvUSD | 5,000,000 crvUSD |

GHO and PYUSD are not included in the initial launch scope.

`maxDeployedCrvUsd` and the ControllerFactory debt ceiling should match at launch. The factory owner must set the intended deployment default before creating each keeper; changing the factory default afterward does not change an existing keeper's local capacity.

## Shared factory configuration

| Parameter | Suggested value |
|---|---|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| Factory owner | Curve Ownership Agent — `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| `admin()` | Curve Ownership Agent — `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| `emergency_admin()` | Curve Emergency Admin — `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| `fee_receiver()` | crvUSD FeeSplitter — `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| `targetAmmExecutionBufferBps` | `5` bps |
| `minDownstreamAttemptGas` | `1,500,000` gas |
| `fallbackSettlementGasReserve` | `300,000` gas |
| `expansionMaxRouteLossBps` | `100` bps |

The three role and receiver values are live factory policy. Existing V3 keepers created by this factory read them dynamically. Capacity and execution defaults are copied into each keeper at deployment.

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

## Address registry

### Tokens

| Token | Address |
|---|---|
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |
| frxUSD | `0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29` |
| sfrxUSD | `0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` |
| sUSDS | `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD` |

### Venues

| Venue | Address | Coin order / function |
|---|---|---|
| frxUSD/crvUSD target AMM | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | `frxUSD[0], crvUSD[1]` |
| USDC/crvUSD target AMM | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | `USDC[0], crvUSD[1]` |
| USDT/crvUSD target AMM | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | `USDT[0], crvUSD[1]` |
| frxUSD/sfrxUSD pool | `0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978` | `sfrxUSD[0], frxUSD[1]` |
| Curve 3pool | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` | `DAI[0], USDC[1], USDT[2]` |
| DaiUsds converter | `0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A` | `daiToUsds` / `usdsToDai` |
| sUSDS vault | `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD` | ERC-4626 deposit / redeem |
| Frax USDC minter | `0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c` | USDC to frxUSD mint only |
| frxUSD/sUSDS pool | `0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7` | `frxUSD[0], sUSDS[1]` |

## Target-AMM configuration

Each target AMM is fixed to its exact target/crvUSD pair:

| Keeper | Expansion target-AMM leg | Target-AMM indices | Buffer |
|---|---|---|---:|
| frxUSD | crvUSD → frxUSD | `1 → 0` | `5` bps |
| USDC | crvUSD → USDC | `1 → 0` | `5` bps |
| USDT | crvUSD → USDT | `1 → 0` | `5` bps |

The target-AMM expansion leg is executed by `expand()` before the configured downstream expansion path. Yield contraction includes the final target → crvUSD target-AMM step in its configured contraction path.

## frxUSD keeper routes

Fixed endpoint configuration:

```text
targetAsset  = frxUSD
backingAsset = frxUSD
yieldToken   = sfrxUSD
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | frxUSD/sfrxUSD | frxUSD | sfrxUSD | `1 → 0` | `5` bps |

Complete expansion:

```text
crvUSD → frxUSD through the target AMM
frxUSD → sfrxUSD through the frxUSD/sfrxUSD pool
```

### Yield-contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | frxUSD/sfrxUSD | sfrxUSD | frxUSD | `0 → 1` | `5` bps |
| 2 | `CURVE_SWAP` | frxUSD/crvUSD target AMM | frxUSD | crvUSD | `0 → 1` | `5` bps |

## USDC keeper routes

Fixed endpoint configuration:

```text
targetAsset  = USDC
backingAsset = USDS
yieldToken   = sUSDS
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | Curve 3pool | USDC | DAI | `1 → 0` | `5` bps |
| 2 | `DAI_USDS_CONVERTER` | DaiUsds | DAI | USDS | `0 → 0` | `0` bps |
| 3 | `ERC4626_DEPOSIT` | sUSDS | USDS | sUSDS | `0 → 0` | `5` bps |

Complete expansion:

```text
crvUSD → USDC through the target AMM
USDC → DAI → USDS → sUSDS
```

### Yield-contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `ERC4626_REDEEM` | sUSDS | sUSDS | USDS | `0 → 0` | `5` bps |
| 2 | `DAI_USDS_CONVERTER` | DaiUsds | USDS | DAI | `0 → 0` | `0` bps |
| 3 | `CURVE_SWAP` | Curve 3pool | DAI | USDC | `0 → 1` | `5` bps |
| 4 | `CURVE_SWAP` | USDC/crvUSD target AMM | USDC | crvUSD | `0 → 1` | `5` bps |

## USDT keeper routes

Fixed endpoint configuration:

```text
targetAsset  = USDT
backingAsset = USDS
yieldToken   = sUSDS
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | Curve 3pool | USDT | DAI | `2 → 0` | `5` bps |
| 2 | `DAI_USDS_CONVERTER` | DaiUsds | DAI | USDS | `0 → 0` | `0` bps |
| 3 | `ERC4626_DEPOSIT` | sUSDS | USDS | sUSDS | `0 → 0` | `5` bps |

Complete expansion:

```text
crvUSD → USDT through the target AMM
USDT → DAI → USDS → sUSDS
```

### Yield-contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `ERC4626_REDEEM` | sUSDS | sUSDS | USDS | `0 → 0` | `5` bps |
| 2 | `DAI_USDS_CONVERTER` | DaiUsds | USDS | DAI | `0 → 0` | `0` bps |
| 3 | `CURVE_SWAP` | Curve 3pool | DAI | USDT | `0 → 2` | `5` bps |
| 4 | `CURVE_SWAP` | USDT/crvUSD target AMM | USDT | crvUSD | `0 → 1` | `5` bps |

## Suggested activation sequence

Every keeper is deployed fully paused.

1. Verify the blueprint hash, factory, ControllerFactory, target AMM, fixed endpoints, path hashes, role getters, fee receiver, local capacity, and ControllerFactory debt ceiling.
2. Run a fork canary for each exact keeper configuration and both route directions.
3. While global execution remains paused, unpause backing deployment, direct buyback, undeployed-backing contraction, and yield contraction.
4. Unpause global execution.
5. Confirm live previews and execute bounded contraction/maintenance canaries.
6. Unpause expansion last.

Final intended launch state:

```text
allExecutionPaused             = false
expansionPaused                = false
backingDeploymentPaused        = false
directBuybackPaused            = false
undeployedContractionPaused    = false
yieldContractionPaused         = false
```

Any failed endpoint, allowance, quote, route, accounting, debt-ceiling, or backing-invariant check leaves expansion paused.

## Optional fourth deployment: USDC to sfrxUSD

This is separate from the initial USDC → sUSDS keeper.

Suggested pilot configuration:

```text
targetAsset          = USDC
backingAsset         = frxUSD
yieldToken           = sfrxUSD
maxDeployedCrvUsd    = 100,000 crvUSD
Controller debt cap  = 100,000 crvUSD
```

### Expansion path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `FRXUSD_MINT` | Frax USDC minter | USDC | frxUSD | `0 → 0` | `5` bps |
| 2 | `CURVE_SWAP` | frxUSD/sfrxUSD | frxUSD | sfrxUSD | `1 → 0` | `5` bps |

Complete expansion:

```text
crvUSD → USDC through the target AMM
USDC → frxUSD through the canonical Frax minter
frxUSD → sfrxUSD through the frxUSD/sfrxUSD pool
```

The Frax adapter is mint-only. Contraction must not assume USDC redemption from the minter.

### Yield-contraction path

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | frxUSD/sfrxUSD | sfrxUSD | frxUSD | `0 → 1` | `5` bps |
| 2 | `CURVE_SWAP` | frxUSD/sUSDS | frxUSD | sUSDS | `0 → 1` | `5` bps |
| 3 | `ERC4626_REDEEM` | sUSDS | sUSDS | USDS | `0 → 0` | `5` bps |
| 4 | `DAI_USDS_CONVERTER` | DaiUsds | USDS | DAI | `0 → 0` | `0` bps |
| 5 | `CURVE_SWAP` | Curve 3pool | DAI | USDC | `0 → 1` | `5` bps |
| 6 | `CURVE_SWAP` | USDC/crvUSD target AMM | USDC | crvUSD | `0 → 1` | `5` bps |

This optional deployment should remain fully paused until the exact mint state, reverse Curve path, route hashes, capacity, and both-direction fork canaries are approved.
