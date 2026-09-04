# PegKeeper V3 LP-yield suggested launch parameters

Status: unreleased `lp-yield` candidate. This document does not authorize deployment, allocation, registration, activation, governance execution, or broadcast.

## Candidate scope

All three candidate keepers hold the same frxUSD/crvUSD Curve StableSwap-NG LP token.

| Keeper | Target AMM | Target asset | Yield token | Yield AMM / held LP | Candidate cap |
|---|---|---|---|---|---:|
| frxUSD | `0x13e12...43e1` | frxUSD | frxUSD | `0x13e12...43e1` | 20m crvUSD |
| USDC | `0x4DEcE...61F30` | USDC | frxUSD | `0x13e12...43e1` | 20m crvUSD |
| USDT | `0x390f3...97BF4` | USDT | frxUSD | `0x13e12...43e1` | 20m crvUSD |

Full addresses:

```text
crvUSD                 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
frxUSD                 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
USDC                   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT                   0xdAC17F958D2ee523a2206206994597C13D831ec7
frxUSD/crvUSD yield AMM 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1
USDC/crvUSD target AMM  0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E
USDT/crvUSD target AMM  0x390f3595bCa2Df7d23783dFd126427CCeb997BF4
Curve 3pool             0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7
Frax mint custodian     0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c
```

The yield AMM coin order is:

```text
frxUSD[0]
crvUSD[1]
```

The pool address is also the 18-decimal LP token. Its deposit ABI uses dynamic arrays:

```solidity
calc_token_amount(uint256[] amounts, bool isDeposit)
add_liquidity(uint256[] amounts, uint256 minLp)
```

## Shared Factory defaults

| Parameter | Candidate value |
|---|---:|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| owner/admin | Curve Ownership Agent `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| emergency admin | `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| fee receiver | `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| `maxDeployedCrvUsd` | `20_000_000e18` |
| `targetAmmExecutionBufferBps` | `3` |
| `yieldAmmExecutionBufferBps` | `3` |
| `expansionMaxRouteLossBps` | `5` |

Removed defaults:

- downstream attempt gas;
- fallback settlement gas reserve;
- contraction-route loss limit.

Expansion no longer accepts a fallback target-inventory state. A failed route or LP deposit reverts atomically.

## Common keeper policy

| Parameter | Value |
|---|---:|
| `entryMinProfitPpm` | `10` |
| `normalExitMinProfitPpm` | `1_000` |
| `earlyExitMinProfitPpm` | `5_000` |
| `keeperProfitShareBps` | `3_000` |
| `minDeploymentTime` | `172_800` seconds |
| `minExpansionAmount` | `10_000e18` |
| velocity max burst | `5%` of cap |
| velocity full refill | `300` seconds |

The velocity bucket counts total crvUSD committed to the LP, not just the first target-AMM leg. A normal expansion around par therefore consumes approximately twice its `expand()` input.

`sweepDonatedYield(maxYieldTokenAmount)` uses the same expansion/global pauses, `minExpansionAmount`, yield-oracle floor, capacity, velocity, LP execution buffer, and entry margin. It skips the target market and expansion route, matches only the selected donated frxUSD with crvUSD, and increases debt only by that matched crvUSD.

## Oracles

| Keeper | Target oracle | Yield-token oracle |
|---|---|---|
| frxUSD | canonical frxUSD/USD Chainlink adapter | same adapter |
| USDC | USDC/USDT Curve EMA, USDC orientation | frxUSD/USD adapter |
| USDT | USDC/USDT Curve EMA, USDT orientation | frxUSD/USD adapter |

Both floors remain `0.9997e18`. Oracle health gates expansion. Contraction remains executable from the held LP because executable output and final solvency are enforced directly.

## Expansion paths

### frxUSD keeper

```text
targetAmm == yieldAmm
expansion path = []
```

No target swap occurs. Requested crvUSD is deposited directly into the frxUSD/crvUSD LP. Any donated frxUSD is included in that deposit with an equal additional amount of crvUSD.

### USDC keeper

| Step | Kind | Venue | Token in | Token out | Buffer |
|---:|---|---|---|---|---:|
| 1 | `FRXUSD_MINT` | Frax mint custodian | USDC | frxUSD | `1` bp |

Complete expansion:

```text
X crvUSD -> USDC
USDC -> frxUSD
all frxUSD + equal-value additional crvUSD -> frxUSD/crvUSD LP
```

### USDT keeper

| Step | Kind | Venue | Token in | Token out | Indices | Buffer |
|---:|---|---|---|---|---|---:|
| 1 | `CURVE_SWAP` | Curve 3pool | USDT | USDC | `2 -> 1` | `3` bps |
| 2 | `FRXUSD_MINT` | Frax mint custodian | USDC | frxUSD | `0 -> 0` | `1` bp |

Complete expansion:

```text
X crvUSD -> USDT
USDT -> USDC
USDC -> frxUSD
all frxUSD + equal-value additional crvUSD -> frxUSD/crvUSD LP
```

## Contraction

There are no deployment-specific contraction paths or FraxNet redemption accounts.

Every keeper uses the same static operation against the held LP:

```text
frxUSD/crvUSD LP
    -> remove_liquidity_one_coin(lpAmount, crvUsdIndex = 1, minCrvUsd)
    -> crvUSD
```

`yieldAmmExecutionBufferBps = 3` protects the executable one-coin quote. The normal/early exit floor and whole-position virtual-price delta remain independent checks.

## Deployment/proposal sequence

The deployer performs six monotonic CREATEs:

1. preview module;
2. locked implementation;
3. immutable EIP-1167 Factory;
4. USDC target oracle;
5. USDT target oracle;
6. frxUSD Chainlink oracle.

The proposal:

1. validates deployed bytecode and oracle identities;
2. deploys each keeper with `yieldToken = frxUSD` and the fixed frxUSD/crvUSD `yieldAmm`;
3. installs only the expansion path;
4. allocates the candidate Factory debt ceiling;
5. registers `debt()` with both aggregate monetary policies;
6. leaves expansion, LP contraction, and global execution paused.

No FraxNet account creation, contraction path, undeployed backing action, direct buyback, activation, or broadcast is included.

## Activation order

If governance later authorizes activation:

1. Reconfirm implementation/preview hashes, proxy targets, oracles, pool coin order, StableSwap-NG dynamic-array ABI, virtual price, fees, balances, and one-coin quote behavior.
2. Reconfirm Frax mint capacity for USDC/USDT expansion.
3. Confirm all keepers start with directions `0`, `1`, and `2` paused.
4. Unpause LP contraction (`1`) while global remains paused.
5. Unpause global execution (`2`).
6. Run bounded expansion and contraction canaries.
7. Unpause expansion (`0`) last.

The branch's pinned non-broadcasting canary already exercises the real USDT expansion path, matched LP deposit, allowance cleanup, and fixed one-coin LP contraction at block `25,868,730`. A current-block canary is still mandatory before any production action.
