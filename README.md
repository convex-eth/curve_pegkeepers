# Curve PegKeeper Experiments

Foundry workspace for reproducing Curve's live crvUSD `PegKeeperV2`, testing protocol offboarding, and using V2 as the starting point for a future V3.

## What PegKeepers are built for

PegKeepers are automated monetary-policy and liquidity contracts for crvUSD. Their job is to push crvUSD back toward its peg while adding liquidity to selected crvUSD/stablecoin markets.

When demand makes crvUSD scarce in a supported pool, a PegKeeper can use crvUSD allocated by the ControllerFactory to add crvUSD-side liquidity. This expands circulating supply, deepens the market, and pushes the pool back toward balance. When crvUSD is abundant, the PegKeeper can remove crvUSD-side liquidity and return that crvUSD to its reserve, where it can be taken out of circulation through Factory debt accounting.

PegKeepers therefore connect three protocol functions:

- crvUSD supply expansion and contraction;
- liquidity provision in the pools used to trade crvUSD;
- permissionless peg maintenance, with a reward for the caller that performs a useful update.

They are not a hard peg guarantee. Their effectiveness depends on pool liquidity, oracle and regulator limits, available debt capacity, and whether the adjustment is economically viable.

## How V2 works

Each `PegKeeperV2` manages one two-coin Curve pool containing crvUSD and another stablecoin.

1. The ControllerFactory assigns the PegKeeper a crvUSD debt ceiling and mints the corresponding idle crvUSD allocation.
2. The shared PegKeeperRegulator checks the aggregate crvUSD price, the target pool's oracle price, other registered PegKeeper pools, and debt-ratio limits before allowing an action.
3. Anyone can call `update()`. If normalized non-crvUSD liquidity exceeds crvUSD liquidity, the PegKeeper can provide crvUSD to the pool. If crvUSD liquidity is excessive, it can withdraw crvUSD from the pool.
4. The PegKeeper records how much crvUSD it has deployed as debt and holds the resulting pool LP tokens.
5. V2 values those LP tokens against its debt. When an update creates positive incremental accounting profit, it pays the caller a configured percentage in LP tokens. The remaining profit belongs to the protocol fee receiver.

V2 does not trade through the pool like a normal swapper. It uses one-sided liquidity additions and imbalance withdrawals to move the pool toward balance.

## What's wrong with V2

### 1. No first-class offboarding or migration path

V2 has governance setters, but no single operation that can quickly retire a PegKeeper or move its position into a replacement. Governance must install an offboarding regulator, change each PegKeeper's regulator, reduce Factory debt ceilings, and wait for residual pool debt to become economically withdrawable. Idle crvUSD can be burned immediately; LP-backed debt can remain stuck until a profitable withdrawal is available.

### 2. Keeper compensation is open-ended

The caller reward is a percentage of incremental profit. It has no absolute cap. A large adjustment can therefore pay far more than the amount needed to cover transaction cost and execution risk. Keeper compensation should be predictable and capped rather than scaling without limit with protocol profit.

### 3. The capital produces little profit

V2 commits a large crvUSD allocation to low-margin stablecoin LP positions. Its return comes mainly from pool fees and favorable imbalance accounting, minus the keeper's percentage. That is a weak revenue source relative to the amount of protocol balance sheet committed.

### 4. crvUSD growth does not produce comparable revenue growth

When demand for crvUSD rises, V2 answers it by minting more crvUSD into an AMM position. This supports the peg and expands supply, but the protocol receives ordinary LP exposure rather than building a dedicated yield-bearing reserve. crvUSD demand can grow substantially while protocol revenue grows little or not at all.

## Preliminary V3 direction

V3 should keep permissionless peg maintenance while changing what the protocol acquires when it expands crvUSD supply. The external AMM asset and the yield-bearing reserve asset are separate choices:

- **Target AMM asset:** the stablecoin quoted against crvUSD through the pool interface, such as USDT.
- **Target yield token:** the asset held behind that interface to earn revenue, such as sUSDe.

A crvUSD/USDT-facing implementation could therefore convert the USDT it earns into USDe and then sUSDe. It does not need to expose sUSDe as the paired pool coin.

1. **Use a flat, Curve-compatible pricing surface.** V3 can expose the functions expected from a normal Curve AMM without using a normal invariant. From the protocol's perspective, the expansion side could sell `1 crvUSD` only when it receives at least `1 + x USDT`, where `x` is a configured number of basis points. The contraction side could spend `1 USDT` only when it receives at least `1 + x crvUSD`. These flat quotes create a no-trade band around the target price instead of continuously moving along a bonding curve.
2. **Convert proceeds into a yield-bearing reserve.** After selling crvUSD for the target AMM asset, V3 can route that asset into a separately configured yield token such as sUSDS, sUSDe, or sfrxUSD. Yield belongs to the protocol and can be forwarded to the fee receiver.
3. **Use sane, capped keeper fees.** Keepers should receive enough to make updates reliable, but every update should have a hard maximum reward. V3 should not pay an uncapped percentage of protocol profit.
4. **Execute only profitable transactions.** The configured quote must leave positive value after pool or routing fees, slippage, keeper compensation, reserve conversion costs, and changes in the yield token's exchange rate. A nominal peg deviation is not enough by itself.
5. **Retain a permissionless `update()` flow.** On the expansion side, an update can mint crvUSD within a governance-controlled limit, sell it for the target AMM asset at the configured profitable quote, and convert the proceeds into the target yield token. On the contraction side, it can redeem enough of the yield reserve, buy crvUSD only at a profitable discount, and return that crvUSD to reserves or take it out of circulation through burning or debt reduction.

This is a design direction, not a V3 specification. Follow-up work must define the exact Curve-compatible interface, flat-price quote rules, asset-conversion route, accounting model, oracle rules, profitability test, keeper fee formula, loss handling, reserve limits, emergency controls, and migration/offboarding lifecycle.

## Toolchain

- Foundry with native Vyper compilation support (verified with Forge `1.7.1`)
- Solidity `0.8.30`
- Vyper `0.3.10`
- Shanghai EVM target, which is supported by both pinned compilers

Foundry compiles both `src/**/*.sol` and `src/**/*.vy`. The Vyper executable is pinned in `foundry.toml` to `.venv/bin/vyper`; there is no FFI compilation path.

```bash
git submodule update --init --recursive
make setup
make build
make test
```

Set `ETH_RPC_URL` to an archive-capable Ethereum endpoint if the bundled public fallback is unavailable:

```bash
ETH_RPC_URL=https://your-archive-rpc.example make test
```

## Source layout

```text
src/
├── interfaces/
│   ├── IControllerFactory.sol
│   ├── IERC20.sol
│   ├── IPegKeeperOffboarding.sol
│   ├── IPegKeeperRegulator.sol
│   ├── IPegKeeperV2.sol
│   ├── IStableSwap2Pool.sol
│   └── IUSDT.sol
└── vyper/
    ├── PegKeeperOffboarding.vy
    └── PegKeeperV2.vy
test/
└── PegKeeperLifecycle.t.sol
```

The Vyper contracts were taken from [`curvefi/curve-stablecoin`](https://github.com/curvefi/curve-stablecoin) at commit [`cf1d05fb6bf7c608973cc41786b2e1fd81dc3a6a`](https://github.com/curvefi/curve-stablecoin/tree/cf1d05fb6bf7c608973cc41786b2e1fd81dc3a6a). `PegKeeperV2.vy` matches the verified live V2 source (apart from the source file's final newline) and pins `# pragma version 0.3.10`.

## Pinned fork

Tests fork Ethereum at block `25,837,866`.

| Contract | Address |
| --- | --- |
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| PegKeeperRegulator | `0x36a04CAffc681fa179558B2Aaba30395CDdd855f` |
| Factory admin / OwnerProxy | `0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79` |
| Ownership agent | `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| Emergency admin | `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| USDT/crvUSD pool | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` |

Current V2 PegKeepers covered by the retirement test:

- USDC: `0x9201da0D97CaAAff53f01B2fB56767C7072dE340`
- USDT: `0xFb726F57d251aB5C731E5C64eD4F5F94351eF9F3`
- pyUSD: `0x3fA20eAa107DE08B38a8734063D605d5842fe09C`
- frxUSD: `0x338Cb2D827112d989A861cDe87CD9FfD913A1f9D`
- GHO: `0x53876B157DeCf04389eEd66c7C29d73863f8C50b`

## Tests

### `test_retireAllCurrentPegKeepers`

Models the actual slow-wind-down path rather than inventing a `retire()` or token sweep:

1. Deploy `PegKeeperOffboarding`.
2. Register all five current PegKeepers with it.
3. As the ownership agent, switch each PegKeeper to the offboarding regulator.
4. As the ControllerFactory admin, set every debt ceiling to zero.
5. Assert that idle crvUSD is burned immediately, the Factory residual equals debt still represented by pool liquidity, new provision is forbidden, and withdrawal remains allowed.

The USDT PegKeeper retains residual debt at the pinned block because that crvUSD is in its pool. It can withdraw liquidity over time; permissionless `rug_debt_ceiling` calls can then burn returned idle crvUSD. Principal is never routed to governance or the fee receiver.

### `test_deployReplacementUsdtPegKeeperAndAdjustAfterCrvUsdPurchase`

1. Offboards the current PegKeeper set.
2. Deploys the pinned V2 source against the live USDT/crvUSD pool and live ControllerFactory.
3. Registers it with the live regulator and assigns a `40,000,000 crvUSD` ceiling.
4. Swaps `10,000,000 USDT` for crvUSD in the live pool.
5. Calls `update()` three times, respecting the 12-second action delay.
6. Asserts that PegKeeper debt and LP position grow, the pool imbalance falls after every adjustment, and the caller receives incremental LP profit.

The old USDT PegKeeper remains in the live regulator's list as a read-only pool/debt reference while its own regulator is the offboarding contract. It cannot provide new debt.

At the pinned block, the system-wide aggregator reports crvUSD below $1, so the live regulator would correctly reject provision even after manipulating only the USDT pool. The lifecycle test therefore uses governance controls **inside the fork only** to install a fixed `$1.001` aggregate price and relax spot/oracle thresholds. This isolates the V2 pool mechanics without pretending that a one-pool purchase moved the real system-wide oracle. No mainnet state is changed.
