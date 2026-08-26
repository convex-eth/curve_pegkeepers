# Curve PegKeeper Experiments

Foundry workspace for reproducing Curve's live crvUSD `PegKeeperV2`, testing protocol offboarding, and using V2 as the starting point for a future V3.

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
