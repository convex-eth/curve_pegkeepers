# Curve PegKeeper Experiments

Foundry workspace for reproducing Curve's live crvUSD `PegKeeperV2`, testing protocol offboarding, and using V2 as the starting point for a future V3.

## What PegKeepers are built for

PegKeepers are automated monetary-policy and liquidity contracts for crvUSD. Their job is to push crvUSD back toward its peg while adding liquidity to selected crvUSD/stablecoin markets.

When demand makes crvUSD scarce in a supported pool, a PegKeeper can use crvUSD allocated by the ControllerFactory to add crvUSD-side liquidity. This expands circulating supply, deepens the market, and pushes the pool back toward balance. When crvUSD is abundant, the PegKeeper can remove crvUSD-side liquidity and return that crvUSD to its idle balance, where it can be taken out of circulation through Factory debt accounting.

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

## V2 limitations and tradeoffs

### 1. No first-class offboarding or migration path

V2 has governance setters, but no single operation that can quickly retire a PegKeeper or move its position into a replacement. Governance must install an offboarding regulator, change each PegKeeper's regulator, reduce Factory debt ceilings, and wait for residual pool debt to become economically withdrawable. Idle crvUSD can be burned immediately; LP-backed debt can remain stuck until a profitable withdrawal is available.

### 2. Keeper compensation has no flat ceiling

The caller reward is a percentage of incremental profit with no absolute per-call ceiling. This is not a principal-safety failure: V2 pays from positive incremental accounting profit. It can nevertheless overpay relative to keeper gas during an unusually favorable update. V3 keeps percentage sharing but adds a flat per-call maximum as a modest economic refinement rather than a primary reason for replacement.

### 3. The capital produces little profit

V2 commits a large crvUSD allocation to low-margin stablecoin LP positions. Its return comes mainly from pool fees and favorable imbalance accounting, minus the keeper's percentage. That is a weak revenue source relative to the amount of protocol balance sheet committed.

### 4. crvUSD growth does not produce comparable revenue growth

When demand for crvUSD rises, V2 answers it by minting more crvUSD into an AMM position. This supports the peg and expands supply, but the protocol receives ordinary LP exposure rather than building a dedicated yield-bearing position. crvUSD demand can grow substantially while protocol revenue grows little or not at all.

## Current V3 direction

The current V3 design is asymmetric:

- **Above peg:** a permissionless keeper sells idle Factory-allocated crvUSD into a designated crvUSD/stablecoin AMM. V3 prefers to deploy the proceeds through the configured yield route, but a downstream failure leaves the target stablecoin as approved accounted backing instead of reverting the peg-critical swap.
- **Below peg:** users can sell crvUSD directly to V3 against available approved backing.
- **Fallback below peg:** if direct buyback flow does not arrive, a keeper can buy crvUSD using either buffered target stablecoin or an independently configured yield-unwind path.

For a USDT-facing sUSDS implementation:

```text
Preferred expansion: crvUSD -> USDT -> DAI -> USDS -> sUSDS
Fallback expansion:  crvUSD -> USDT (accounted target buffer)

Buffer contraction:  USDT -> crvUSD
Yield contraction:   sUSDS -> USDS -> crvUSD
```

The target buffer is intentional backing; intermediate DAI and USDS balances remain transient route assets. The core backing invariant counts normalized accounted USDT plus the trusted USDS value represented by sUSDS. Unsolicited token transfers do not enter accounting automatically.

The downstream expansion and yield contraction paths are separately updatable through delayed governance. Routes use typed Curve-swap, exact-converter, and ERC-4626 steps rather than caller-provided routers or arbitrary calldata. Target-buffer contraction uses the designated target AMM directly and does not depend on the downstream yield route.

The governance owner also has a separate unrestricted `execute(target, value, calldata)` escape hatch. It can move or convert assets through a one-off recovery path if a configured venue breaks or governance loses confidence in the held yield token or an underlying stablecoin. This power belongs only to the DAO owner, not keepers or the emergency admin. The DAO already controls crvUSD minting and protocol configuration, so the function does not introduce a new trusted actor; it makes that existing governance authority directly usable for urgent recovery.

V3 does not require the target crvUSD AMM spot price to remain close to its EMA. A sharp upward crvUSD move is the opportunity the expansion keeper should capture. After the target swap, V3 attempts the fixed downstream path in an isolated call. Success finishes in yield backing; failure rolls back only the downstream attempt and retains target backing. The keeper cannot select the branch, route, minima, or recipient, and an implementation gas reserve prevents deliberate fallback through gas starvation.

V3 treats governance-approved backing stablecoins as one-dollar assets for PegKeeper accounting. Yield shares are first converted into units of their approved underlying through the configured vault or adapter; raw share count is never assumed to equal underlying. The target AMM spot is not used to price the final position. This matches the Factory trust model: the Factory mints an allocation to an approved PegKeeper but does not independently inspect or mark to market what that PegKeeper acquires. A real depeg or redemption failure is therefore governance collateral risk, handled through pauses, route migration, and the owner execute escape hatch—not something the nominal profit check can detect.

Governance route analysis also distinguishes gross PegKeeper output from DAO-consolidated cost. A Curve pool may direct some or all swap fees to Curve DAO admin balances rather than LPs. V3 still treats every fee as a local execution cost because it does not receive admin balances atomically, but governance can prefer DAO-capturing routes when comparing where protocol-level fees accrue. The current 3pool example is recorded in the V3 specification.

Keeper rewards are paid from realized gross profit rather than principal. A fully deployed expansion measures profit after the downstream stable conversion and before terminal yield deposit. A target-only fallback measures normalized target asset received minus crvUSD sold. Each branch pays `min(grossProfit * keeperProfitShareBps / 10_000, maxKeeperReward)` in its realized stablecoin and must retain principal plus the configured margin after reward. Contraction applies the analogous formula to crvUSD received minus the trusted backing source spent. Direct buyback and later buffer-deployment callers receive no percentage reward.

Future target-to-yield fees are not deducted hypothetically from fallback keeper profit because later conversion is optional: the USDT may instead contract crvUSD directly. `deployBufferedTarget(amount)` can invest accounted USDT later, but conversion loss may consume only existing protocol surplus, remains bounded by a route-specific loss limit, and can never reduce combined trusted backing below deployed crvUSD plus the configured reserve. It does not reset the expansion timer or increase deployed debt.

Old buffered USDT is not blindly combined with a newly rewarded expansion. A successful new expansion may trigger a separate capped, best-effort buffer flush with independent balance snapshots; failure of that maintenance subcall cannot revert the peg action. The explicit buffer-deployment function remains available if the route recovers without another expansion.

Keeper execution remains fully open. Rewarded keeper functions accept an exact amount but no caller-selected route or minimum-output parameters. The contract validates minimum and maximum size bounds, computes every path minimum and reward internally, and enforces the selected branch's realized profit. V3 does not calculate or probe for a maximum amount. A keeper may split an opportunity and collect more than one flat cap, but every call must independently leave the configured post-reward margin and pay its own gas. `minExpansionAmount` blocks true dust; the design treats remaining fragmentation as bounded rent leakage rather than a solvency problem.

Timing is intentionally asymmetric. Expansion has no cooldown and should execute immediately whenever final backing covers principal, route costs, keeper compensation, and the configured entry margin. Routine contraction uses the normal exit margin only after the minimum time has elapsed since the latest successful material expansion. Before then, contraction requires a higher early-exit margin, making realized distress—not a manipulable spot trigger—the override. The timer gates contraction rather than token destruction: once crvUSD is reacquired it is already out of circulation, so delaying its later Factory burn would not prevent market churn.

The initial timing model can use one global `lastExpansionAt`, but only a successful expansion meeting a governance-set `minExpansionAmount` resets it. A flash-liquidity actor can buy crvUSD, request the minimum expansion, and sell back to reset the timer, but V3 countertrades at least that material threshold. The actor eats the round-trip loss, fees, and V3's required entry economics. The attack is therefore paid rather than free, while genuinely distressed crvUSD can still use the higher-profit early-exit path.

At `4%` to `5%` annualized stablecoin yield, approximately one basis point accrues in `17.5` to `21.9` hours. A one-day minimum deployment time is therefore a useful initial reference for assets that reached the yield token, but buffered USDT earns no such carry. The global timer remains an anti-churn control rather than a guarantee that every backing source earned yield; every exit must still pass its final-value check.

The complete current draft is in [`docs/pegkeeper-v3-spec.md`](docs/pegkeeper-v3-spec.md). It records route governance, lifecycle steps, accounting, interfaces, invariants, risks, and deferred decisions.

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
docs/
└── pegkeeper-v3-spec.md
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
