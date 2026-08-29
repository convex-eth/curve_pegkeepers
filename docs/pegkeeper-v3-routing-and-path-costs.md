# PegKeeper V3 routing choices and path costs

Status: mainnet route research; no deployment or activation transaction is authorized.

This document separates V3 route selection from the core specification. It covers the current
candidate target AMMs and fixed yield-token endpoints:

```text
target assets: frxUSD, USDT, USDC, PYUSD, GHO
yield tokens:  sfrxUSD, sUSDS, sUSDe
```

The measurements below are snapshots, not permanent limits or executable governance parameters.
Every deployment still relies on same-transaction quotes, per-step execution minima, exact balance
deltas, the configured full-route loss limit, and the final post-reward backing invariant.

## Measurement basis

```text
Ethereum block: 25,857,270
UTC timestamp:  2026-08-29 00:17:47 UTC
RPC:            mainnet archive RPC
routing:        one deterministic, unsplit linear path
cost unit:      basis points of normalized input value
amount ladder:  10k, 100k, 1m, 2.5m, 5m stable units
gas:            excluded
```

`Expansion cost` means target-asset input minus final yield-token underlying value. `Contraction
cost` means starting yield-token underlying value minus final target-asset output. Negative cost is
a favorable live imbalance. Final yield shares are always normalized with
`yieldToken.convertToAssets(shares)`; raw shares are never compared with stablecoin units.

The target-AMM leg is reported separately from the downstream path. This matters because a valid V3
expansion requires a sufficiently favorable crvUSD-to-target execution to pay the downstream cost,
keeper reward, and entry margin. Adding two static table entries is not an execution guarantee.

## Fixed tokens

| Symbol | Address | Decimals | V3 role |
|---|---|---:|---|
| crvUSD | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` | 18 | liability/intervention asset |
| frxUSD | `0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29` | 18 | target or sfrxUSD backing |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | target |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | target/intermediate |
| PYUSD | `0x6c3ea9036406852006290770BEdFcAbA0e23A0e8` | 6 | target |
| GHO | `0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f` | 18 | target/research candidate |
| sfrxUSD | `0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6` | 18 | yield token; backing is frxUSD |
| sUSDS | `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD` | 18 | yield token; backing is USDS |
| sUSDe | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` | 18 | yield token; backing is USDe |
| USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` | 18 | sUSDS backing |
| USDe | `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` | 18 | sUSDe backing |
| DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | 18 | canonical USDS bridge |

Wrapper state at the pinned block:

| Yield token | `asset()` | `convertToAssets(1e18)` | `convertToShares(1e18)` | Direct deposit |
|---|---|---:|---:|---|
| sfrxUSD | frxUSD | 1.207961812596532010 | 0.827840739311522622 | disabled: `previewDeposit=0`, `maxDeposit=0` |
| sUSDS | USDS | 1.107750873476643841 | 0.902730048735171957 | enabled |
| sUSDe | USDe | 1.245442762168418746 | 0.802927304550646213 | enabled |

Consequences:

- sfrxUSD must be acquired and unwound through a Curve pool; V3 must not encode an ERC-4626
  deposit/redeem step for it while deposits remain disabled.
- sUSDS and sUSDe may use typed ERC-4626 deposit/redeem steps.
- V3 additionally requires the final expansion step to be `backingAsset -> yieldToken` and the first
  contraction step to be `yieldToken -> backingAsset`. A Curve pool that outputs a yield token from
  some other asset may therefore be used only as an intermediate step. The frxUSD/sUSDS and
  frxUSD/sUSDe candidates must immediately redeem to backing and redeposit at the terminal step;
  they cannot terminate directly at the pool output. The frxUSD/sfrxUSD pool is valid as a terminal
  step because frxUSD is sfrxUSD's configured backing asset.

## Target AMMs

These are the current target-pool choices. All five have `coins(0) = target` and
`coins(1) = crvUSD`, so expansion uses `exchange(1,0,...)` and undeployed-backing contraction uses
`exchange(0,1,...)`.

| Target | Pool | Approx. API TVL | `fee()` snapshot | Admin share | Dynamic multiplier |
|---|---|---:|---:|---:|---:|
| frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | $13.63m | 1.0 bp | 50% | 5x |
| USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | $55.93m | 1.0 bp | 50% | static implementation |
| USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | $13.18m | 1.0 bp | 50% | static implementation |
| PYUSD | `0x625E92624Bc2D88619ACCc1788365A69767f6200` | $1.09m | 1.0 bp | 50% | 5x |
| GHO | `0x635EF0056A597D13863B73825CcA297236578595` | $1.30m | 0.5 bp | 50% | 8x |

The obsolete near-empty crvUSD/GHO pool at
`0x86152dF0a0E321Afb3B0B9C4deb813184F365ADa` is not the current candidate.

### Target-AMM executable quote cost

| Target | Direction | 10k | 100k | 1m | 2.5m | 5m |
|---|---|---:|---:|---:|---:|---:|
| frxUSD | crvUSD -> target | 1.14 | 1.21 | 1.90 | 3.33 | 9.71 |
| frxUSD | target -> crvUSD | 0.87 | 0.94 | 1.61 | 2.96 | 8.42 |
| USDT | crvUSD -> target | 1.32 | 1.34 | 1.50 | 1.78 | 2.27 |
| USDT | target -> crvUSD | 0.68 | 0.70 | 0.86 | 1.13 | 1.58 |
| USDC | crvUSD -> target | 1.96 | 2.03 | 2.81 | 4.67 | 18.17 |
| USDC | target -> crvUSD | 0.06 | 0.13 | 0.82 | 2.06 | 6.16 |
| PYUSD | crvUSD -> target | 2.77 | 3.92 | 5,406 | 8,162 | 9,081 |
| PYUSD | target -> crvUSD | -0.52 | 0.34 | 3,707 | 7,482 | 8,741 |
| GHO | crvUSD -> target | -4.45 | -3.19 | 1,041 | 6,413 | 8,206 |
| GHO | target -> crvUSD | 5.94 | 8.07 | 5,973 | 8,389 | 9,194 |

The PYUSD and GHO pools are useful only at small sizes in the pinned state. Their configured fees look
small, but inventory exhaustion dominates at larger amounts.

## Candidate downstream venues

| Shorthand | Venue | Coin order | `fee()` snapshot | Admin share | Dynamic multiplier |
|---|---|---|---:|---:|---:|
| 3pool | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` | DAI, USDC, USDT | 1.5 bp | 100% | static |
| PayPool | `0x383E6b4437b59fff47B619CBA855CA29342A8559` | PYUSD, USDC | 1.0 bp | 50% | 10x |
| frxUSD/sfrxUSD | `0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978` | sfrxUSD, frxUSD | 1.0 bp | 50% | 1x |
| frxUSD/sUSDS | `0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7` | frxUSD, sUSDS | 1.0 bp | 50% | 5x |
| frxUSD/sUSDe | `0x47Ab5f9D8C9C7D002a92320f23a696D348C56A7F` | frxUSD, sUSDe | 1.0 bp | 50% | 10x |
| USDT/USDe | `0x5B03CcCAb7BA3010fA5CAd23746cbf0794938e96` | USDT, USDe | 0.3 bp | 50% | 40x |
| USDe/USDC | `0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72` | USDe, USDC | 1.0 bp | 50% | 5x |
| GHO/USDe | `0x670a72e6D22b0956C0D2573288F82DCc5d6E3a61` | GHO, USDe | 0.5 bp | 50% | 8x |
| DaiUsds | `0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A` | DAI <-> USDS | exact 1:1 typed conversion | n/a | n/a |

Pool fee is not route cost. The tables below include current imbalance, price impact, wrapper exchange
rate, and rounding. DAO admin-fee accrual is not V3 backing and never weakens an onchain minimum.

## Route choices

Expansion paths are shown below. A yield-contraction path is the exact reverse, replacing each
ERC-4626 deposit with redeem and ending through the selected target AMM's target -> crvUSD edge.

| Target | Yield | Deterministic expansion path | Current use |
|---|---|---|---|
| frxUSD | sfrxUSD | frxUSD -> sfrxUSD pool | **preferred; scalable** |
| frxUSD | sUSDS | frxUSD -> sUSDS pool -> USDS (redeem) -> sUSDS (deposit) | small-cap only |
| frxUSD | sUSDe | frxUSD -> sUSDe pool -> USDe (redeem) -> sUSDe (deposit) | small-cap only |
| USDT | sUSDS | USDT -> DAI (3pool) -> USDS (DaiUsds) -> sUSDS (deposit) | **preferred; scalable** |
| USDT | sUSDe | USDT -> USDe -> sUSDe (deposit) | small-cap only |
| USDT | sfrxUSD | USDT -> USDe -> sUSDe -> frxUSD -> sfrxUSD | research only |
| USDC | sUSDS | USDC -> DAI (3pool) -> USDS (DaiUsds) -> sUSDS (deposit) | **preferred; scalable** |
| USDC | sUSDe | USDC -> USDe -> sUSDe (deposit) | small-cap only |
| USDC | sfrxUSD | USDC -> USDe -> sUSDe -> frxUSD -> sfrxUSD | research only |
| PYUSD | sUSDS | PYUSD -> USDC (PayPool) -> DAI (3pool) -> USDS -> sUSDS | **preferred downstream path; target pool limits total capacity** |
| PYUSD | sUSDe | PYUSD -> USDC -> USDe -> sUSDe | small-cap only |
| PYUSD | sfrxUSD | PYUSD -> USDC -> USDe -> sUSDe -> frxUSD -> sfrxUSD | research only |
| GHO | sUSDS | GHO -> USDe -> USDC -> DAI -> USDS -> sUSDS | not activation-ready |
| GHO | sUSDe | GHO -> USDe -> sUSDe | not activation-ready |
| GHO | sfrxUSD | GHO -> USDe -> sUSDe -> frxUSD -> sfrxUSD | not activation-ready |

No path loops through crvUSD between the target-AMM intervention and the final yield token. Such a
loop would partially undo or contaminate the monetary-policy action and is rejected as a route choice
even if an optimizer quotes it favorably.

The frxUSD/sUSDS and frxUSD/sUSDe cost rows include the V3-required terminal wrapper round trip. At
the pinned block and 10k input, `previewRedeem(poolShares)` followed by `previewDeposit(assets)` loses
one share for each wrapper, below the displayed basis-point precision. It is retained in the route
because omitting it would make the path fail `setPaths()` validation.

## Downstream expansion cost ladder

Values are all-in target -> final yield backing loss in basis points.

| Target | Yield | 10k | 100k | 1m | 2.5m | 5m |
|---|---|---:|---:|---:|---:|---:|
| frxUSD | sfrxUSD | 0.92 | 0.93 | 1.09 | 1.39 | 3.11 |
| frxUSD | sUSDS | 2.05 | 2.76 | 1,401 | 6,553 | 8,277 |
| frxUSD | sUSDe | -2.36 | -0.36 | 5,783 | 8,313 | 9,157 |
| USDT | sUSDS | 1.68 | 1.69 | 1.73 | 1.80 | 1.91 |
| USDT | sUSDe | 0.42 | 0.80 | 7,066 | 8,826 | 9,413 |
| USDT | sfrxUSD | 6.37 | 10.70 | 7,448 | 8,979 | 9,490 |
| USDC | sUSDS | 1.46 | 1.47 | 1.51 | 1.59 | 1.71 |
| USDC | sUSDe | 0.28 | 3.88 | 6,548 | 8,619 | 9,310 |
| USDC | sfrxUSD | 6.22 | 13.77 | 7,442 | 8,977 | 9,488 |
| PYUSD | sUSDS | 2.09 | 2.10 | 2.23 | 2.44 | 2.81 |
| PYUSD | sUSDe | 0.90 | 4.51 | 6,548 | 8,619 | 9,310 |
| PYUSD | sfrxUSD | 6.84 | 14.40 | 7,442 | 8,977 | 9,488 |
| GHO | sUSDS | 22.78 | 8,234 | 9,823 | 9,929 | 9,965 |
| GHO | sUSDe | 18.84 | 8,233 | 9,823 | 9,929 | 9,965 |
| GHO | sfrxUSD | 24.77 | 8,234 | 9,823 | 9,929 | 9,965 |

## Reverse contraction cost ladder

Values are all-in starting yield backing -> target loss in basis points, before the final target ->
crvUSD target-AMM leg.

| Target | Yield | 10k | 100k | 1m | 2.5m | 5m |
|---|---|---:|---:|---:|---:|---:|
| frxUSD | sfrxUSD | 1.09 | 1.10 | 1.27 | 1.65 | 5.28 |
| frxUSD | sUSDS | 0.10 | 0.75 | 185.95 | 6,015 | 8,007 |
| frxUSD | sUSDe | 5.03 | 8.97 | 7,438 | 8,975 | 9,488 |
| USDT | sUSDS | 1.32 | 1.32 | 1.37 | 1.43 | 1.55 |
| USDT | sUSDe | 0.24 | 0.56 | 6,789 | 8,716 | 9,358 |
| USDT | sfrxUSD | -1.03 | 1.30 | 6,789 | 8,716 | 9,358 |
| USDC | sUSDS | 1.54 | 1.54 | 1.59 | 1.66 | 1.79 |
| USDC | sUSDe | 2.49 | 6.58 | 6,840 | 8,736 | 9,368 |
| USDC | sfrxUSD | 1.22 | 7.31 | 6,845 | 8,738 | 9,369 |
| PYUSD | sUSDS | 2.93 | 2.95 | 3.09 | 3.33 | 3.80 |
| PYUSD | sUSDe | 3.89 | 7.98 | 6,840 | 8,736 | 9,368 |
| PYUSD | sfrxUSD | 2.62 | 8.72 | 6,845 | 8,738 | 9,369 |
| GHO | sUSDS | 1.37 | 7,029 | 9,703 | 9,881 | 9,941 |
| GHO | sUSDe | -0.45 | 7,029 | 9,703 | 9,881 | 9,941 |
| GHO | sfrxUSD | -1.72 | 7,029 | 9,703 | 9,881 | 9,941 |

## Capacity conclusions

### Activation-ready combinations

```text
frxUSD target -> sfrxUSD
USDT target   -> sUSDS
USDC target   -> sUSDS
PYUSD target  -> sUSDS downstream, but only with a target-AMM cap far below 1m at current depth
```

The first three retain low-single-digit downstream cost through the 5m ladder. The PYUSD downstream
path remains efficient, but its crvUSD/PYUSD target AMM exhausts around the 1m scale, so the target
pool—not the yield path—is the binding limit.

### Small-cap combinations

```text
frxUSD -> sUSDS or sUSDe
USDT/USDC/PYUSD -> sUSDe
```

These can look excellent at 10k-100k and then collapse because one shallow output-side pool is nearly
drained. A low nominal fee is not capacity.

### Research-only combinations

```text
USDT/USDC/PYUSD -> sfrxUSD through sUSDe and frxUSD
all GHO -> yield routes
```

The cross-yield sfrxUSD routes add hops and inherit the shallow sUSDe/frxUSD bridge. GHO is further
limited by the roughly $47k GHO/USDe venue. GHO may remain a valid target-AMM candidate for future
liquidity, but it is not activation-ready for the current yield set.

## Governance calibration rules

Before any deployment or route update:

1. Re-pin a fresh block and repeat the full quote ladder in both directions.
2. Verify every `coins(i)` live; do not trust this document after pool replacement.
3. Re-read `fee()`, `admin_fee()`, `offpeg_fee_multiplier()`, balances, and wrapper conversions.
4. Select a local/Factory capacity below the first nonlinear impact point of both the target AMM and
   downstream route.
5. Derive per-step execution buffers from measured same-transaction quote behavior. Do not encode the
   historical table cost itself as slippage tolerance.
6. Keep `expansionMaxRouteLossBps` separate from quote-relative buffers and the final entry margin.
7. Run a fork canary for the exact constructor tuple, paths, amount cap, and gas policy.
8. Treat DAO admin-fee accrual as consolidated economics only; it is never V3 backing.
9. Pause expansion immediately on target, backing, or yield-token impairment. Contraction and owner
   recovery remain the wind-down paths.

## Source and reproduction notes

Pool enumeration used Curve's Ethereum pool API, then the addresses, coin order, fees, wrapper state,
and `get_dy` results were checked against mainnet state at the pinned block. Cost rows were generated
by sequential pinned `eth_call` evaluation of every swap, converter, and wrapper hop, then transcribed
into this document; they are not estimates copied from a routing UI. All 15 documented
expansion/contraction templates are also instantiated against the live contracts and accepted by
V3's exact endpoint, terminal-backing, continuity, venue, and pool-index validation in
`test/PegKeeperV3RouteMatrixFork.t.sol`.

The canonical costing method is:

```text
finalBacking = yieldToken.convertToAssets(finalYieldShares)
routeCostBps = (normalizedInput - finalBacking) * 10_000 / normalizedInput
```

For reverse routes:

```text
startShares  = yieldToken.convertToShares(backingNotional)
startBacking = yieldToken.convertToAssets(startShares)
routeCostBps = (startBacking - normalizedTargetOut) * 10_000 / startBacking
```

These are route-selection measurements. Production execution remains authoritative.
