# PegKeeper V3 suggested launch parameters and routes

Status: governance launch proposal only. This document does not authorize deployment, allocation, broadcast, or activation.

Implementation:

- Curve ownership proposal: [`../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol`](../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol)
- Mainnet-fork proposal test: [`../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol`](../test/integration/curveProposals/CurveProposalLaunchPegKeeperV3.t.sol)

`script/DeployPegKeeperV3.s.sol` performs one explicit deployment of the preview module, locked implementation, immutable EIP-1167 factory, five Curve EMA adapters, and both alternative Chainlink adapters. It uses hardcoded public mainnet configuration and writes every created address to `deployments/mainnet/PegKeeperV3-deployment.json`. The proposal reads its factory and selected Curve adapters from that file, deploys and funds the three keepers below, registers each with both aggregate monetary policies currently used by crvUSD mint-market Controllers, and leaves all execution directions paused. Activation remains a separate governance step after deployment verification.

## Initial launch scope

Deploy three PegKeeper V3 instances:

| Keeper | Target asset | Yield token | Backing asset | Suggested `maxDeployedCrvUsd` | ControllerFactory debt ceiling |
|---|---|---|---|---:|---:|
| frxUSD | frxUSD | sfrxUSD | frxUSD | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDC | USDC | sUSDS | USDS | 2,500,000 crvUSD | 2,500,000 crvUSD |
| USDT | USDT | sUSDS | USDS | 5,000,000 crvUSD | 5,000,000 crvUSD |

GHO and PYUSD are not included in the initial launch scope.

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

## Mandatory oracle and velocity configuration

Every deployment requires nonzero target and downstream adapters. Both launch floors are `0.9997e18`; favorable prices receive no more than par credit. Governance may replace code-bearing adapters and set nonzero floors up to par without resetting velocity pressure. Target failure blocks expansion. Downstream failure retains the acquired target asset rather than entering the yield route. Contraction and recovery remain available.

| Keeper | Target adapter | Downstream backing adapter |
|---|---|---|
| frxUSD → sfrxUSD | frxUSD/sUSDS EMA, frxUSD orientation | sfrxUSD/frxUSD EMA, sfrxUSD orientation |
| USDC → sUSDS | USDC/USDT EMA, USDC orientation | rate-normalized frxUSD/sUSDS EMA, sUSDS/frxUSD orientation |
| USDT → sUSDS | USDC/USDT EMA, USDT orientation | rate-normalized frxUSD/sUSDS EMA, sUSDS/frxUSD orientation |

Launch oracle pools:

| Pool | Address | Current depth snapshot | EMA window |
|---|---|---:|---:|
| USDC/USDT | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` | approximately `$5.44m` | `866s` |
| frxUSD/sUSDS | `0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7` | approximately `$1.86m` | `866s` |
| sfrxUSD/frxUSD | `0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978` | approximately `$11.86m` | verify before launch |

The frxUSD/sUSDS pool applies its sUSDS rate provider. Its EMA is therefore an underlying economic comparison, not a raw share-count quote. The frxUSD keeper instead checks downstream `sfrxUSD` health against the materially deeper sfrxUSD/frxUSD pool. Each keeper converts held shares to underlying assets once before applying the capped adapter multiplier; favorable values above par cannot over-credit backing. Route execution remains protected separately by quote floors, measured output, and route-loss limits.

### Alternative Chainlink sources — not selected

The repository also contains separate registry-bound Chainlink adapters for frxUSD/USD and USDS/USD. They are alternatives for the frxUSD and USDS checks above, not additional launch requirements. The current proposal remains Curve-only until governance selects one source family and updates the exact adapter addresses.

If selected, the frxUSD/USD adapter can serve both the frxUSD target check and the frxUSD-valued downstream check after `sfrxUSD.convertToAssets()`. The USDS/USD adapter can replace the Curve sUSDS/frxUSD downstream check after `sUSDS.convertToAssets()`. This decision does not by itself replace the separately configured USDC and USDT target checks.

| Item | Address |
|---|---|
| Ethereum Feed Registry | `0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf` |
| USD denomination | `0x0000000000000000000000000000000000000348` |
| frxUSD/USD feed resolved by registry | `0x62a897c3e81d809c7444BB63D7D51E1F2EbB6C3D` |
| USDS/USD feed resolved by registry | `0x592700e4FcDd674dC54d2681DED3B63f54F63f9A` |

Both feeds report 8 decimals and normalize to `1e18`. Direct contract calls to these feed proxies currently revert `No access`; the adapter therefore reads through the authorized Feed Registry and fails closed if the registry later resolves a different feed. The unified deployer currently uses a provisional `26 hours` maximum delay for both adapters, based on recent roughly daily registry updates plus limited grace. This value is not approved policy: re-confirm both feed mappings, descriptions, decimals, recent update intervals, contract-read access, and the independent freshness limits before broadcast.

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
| sfrxUSD/frxUSD pool | `0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978` | `sfrxUSD[0], frxUSD[1]` |
| USDC/USDT oracle pool | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` | `USDC[0], USDT[1]` |

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

1. Verify the implementation core hash, preview-module hash, 45-byte proxy runtime and embedded target, factory, ControllerFactory, oracle pool/orientation, aggregate monetary-policy membership, target AMM, fixed endpoints, path hashes, role getters, fee receiver, local capacity, zero launch pressure, and ControllerFactory debt ceiling.
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
