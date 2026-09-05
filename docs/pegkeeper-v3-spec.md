# PegKeeper V3 LP-yield specification

Status: unreleased `3.3.0` candidate on the `lp-yield` branch. Not deployed. Nothing in this document authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## Model

PegKeeper V3 holds a Curve two-coin pool's LP token as backing.

Each deployment fixes:

- `targetAmm`: the crvUSD/target pool used to detect and execute expansion;
- `targetAsset`: the non-crvUSD coin in `targetAmm`;
- `yieldToken`: the non-crvUSD coin paired with crvUSD in the backing pool;
- `yieldAmm`: the Curve backing pool and its ERC-20 LP token;
- `backingAsset`: `yieldToken` in vanilla mode or `yieldToken.asset()` in ERC-4626 mode;
- one mandatory retained-backing oracle for `yieldToken`.

The Factory stores the shared aggregate crvUSD price oracle used by every keeper. Factory ownership may replace it through `setAggregateCrvUsdOracle()`; replacement addresses must contain code.

`yieldAmm` must:

- contain exactly crvUSD and `yieldToken`;
- expose an 18-decimal ERC-20 LP token at the pool address;
- implement StableSwap-NG dynamic-array `calc_token_amount(uint256[],bool)` and `add_liquidity(uint256[],uint256)`;
- implement `get_virtual_price()`, `calc_withdraw_one_coin(uint256,int128)`, and `remove_liquidity_one_coin(uint256,int128,uint256)`.

The initial configuration uses the frxUSD/crvUSD StableSwap-NG pool for every keeper:

```text
yieldAmm   = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1
yieldToken = frxUSD
yield coins: frxUSD[0], crvUSD[1]
```

The keeper does not hold a configurable contraction route. It does not retain target assets after a failed expansion. It does not expose undeployed-backing maintenance or direct inventory buyback.

## Supply accounting

`deployedCrvUsd` records crvUSD externalized by successful expansion, donation matching, or a surplus claim. Idle crvUSD held by the keeper is not counted as deployed debt.

A normal expansion spends two crvUSD amounts:

```text
X = crvUSD sold in targetAmm
Y = normalized backing-asset value of all yieldToken deposited into yieldAmm
principal increase = X + Y
```

`Y` includes both freshly acquired yield tokens and pre-existing donated yield tokens. This means the matched crvUSD is part of exposure, capacity, Factory debt-ceiling, idle-balance, and leaky-bucket checks. Counting only `X` would understate supply.

Contraction reduces `deployedCrvUsd` by the crvUSD retained after the keeper reward. Any terminal amount above remaining debt is transferred to the Factory's current fee receiver.

`debt()` returns `deployedCrvUsd` for aggregate monetary-policy integration.

## LP backing value

The complete held LP position is authoritative:

```text
lpValue = floor(yieldAmm.balanceOf(keeper) * yieldAmm.get_virtual_price() / 1e18)
```

This convention is valid only under the approved equivalent-asset/rate-aware-pool assumption. Governance is responsible for choosing a pool whose virtual price correctly incorporates its coins' exchange rates and whose assets are acceptable nominal backing.

For an ERC-4626 `yieldToken`, the pool's virtual price is still the sole persistent LP valuation rate. V3 must not apply `convertToAssets()` again to the LP value. That would double-count share appreciation already incorporated by the pool.

`yield_token_assets()` and `yield_token_units()` remain route and matching helpers. They are not applied to held LP tokens.

The mandatory yield-token oracle gates operations that settle retained backing and conservatively haircuts `oracle_backing_value()`. Its default and proposed launch floor is `0.999e18`, ten basis points below par. Transient target assets have no oracle configuration or gate because successful expansion must route them completely into `yieldToken` and then atomically settle into LP; route quotes, absolute-value floors, measured deltas, and route-loss bounds protect that transit. The Factory's aggregate crvUSD oracle gates monetary direction. `trusted_backing_value()` uses LP virtual price directly. Virtual price is an accounting value, not an executable withdrawal quote.

Aggregate direction boundaries are exact:

```text
aggregate crvUSD price < 1e18: expansion forbidden; contraction allowed
aggregate crvUSD price = 1e18: expansion and contraction allowed
aggregate crvUSD price > 1e18: expansion allowed; contraction forbidden
```

Both execution and previews use the same boundary. Oracle failure or returndata other than exactly 32 bytes fails closed.

## Local intervention share and pacing

Two keeper-local parameters bound price-moving monetary intervention independently from capacity and velocity:

```text
maxInterventionShareBps = 3_333
minInterventionDelay    = 12 seconds
```

For expansion, let `C` be the target AMM's crvUSD balance and `T` its normalized target-asset balance. Plain target assets use their decimal multiplier. When `targetAsset == yieldToken`, the balance is valued through the same trusted yield-token conversion, including `convertToAssets` for ERC-4626 shares. The requested first leg is bounded by:

```text
expansionDeficit   = max(T - C, 0)
expansionAllowance = floor(expansionDeficit * maxInterventionShareBps / 10_000)
require requestedCrvUsd <= expansionAllowance
```

For contraction, let `C` be the yield AMM's crvUSD balance and `Y` the trusted normalized value of its yield-token balance:

```text
contractionExcess    = max(C - Y, 0)
contractionAllowance = floor(contractionExcess * maxInterventionShareBps / 10_000)
require quotedCrvUsdOut <= contractionAllowance
require actualCrvUsdOut <= contractionAllowance
```

Checking both the quote and measured receipt prevents favorable execution from crossing the pre-action cap. The allowance multiplication uses integer-floor rounding in preview and execution.

`lastInterventionAt` records only successful `expand()` and `contractViaAmm()` calls after every accounting and solvency check passes. The first intervention is immediately available; later interventions in either direction require at least `minInterventionDelay` seconds since the last one. Governance may set the delay to zero. This is a shared operation-pacing control, not LP maturity or a holding period: it never assigns age to fungible LP.

Acquired-yield matching and donation settlement are not counted against the local share. `sweepDonatedYield()` and donation settlement inside `claimSurplus()` do not update `lastInterventionAt`; dust cannot postpone a monetary intervention. Their existing regime-aware exact-balance rule independently prevents donation settlement from overshooting the yield pool.

## Expansion

Expansion is keeper-driven and all-or-nothing.

### Separate target and yield pools

For an input `X`:

1. Verify expansion/global pause state, aggregate crvUSD price at least `1e18`, shared intervention delay, local target-pool allowance, amount floor, and yield-token oracle.
2. Swap exactly `X` crvUSD through `targetAmm` and verify measured input/output deltas.
3. Execute the configured typed expansion path from `targetAsset` to `yieldToken` synchronously.
4. Revert the whole transaction if any target swap, route step, allowance reset, measured delta, route-loss bound, or endpoint check fails.
5. Read the complete live `yieldToken` balance. This sweeps freshly acquired and donated yield tokens in the same operation.
6. Convert that balance to normalized backing value `Y` and require an additional `Y` crvUSD.
7. Count `X + Y` against idle crvUSD, local capacity, Factory debt ceiling, and expansion velocity.
8. Add `Y` crvUSD and all yield tokens to `yieldAmm` using its dynamic-array StableSwap-NG ABI.
9. Enforce a quote-derived `minLp`, exact crvUSD/yield-token spending, measured LP receipt, retained-profit floor, and final solvency.
10. Pay the keeper reward in LP tokens and increase `deployedCrvUsd` by `X + Y`.

Example:

```text
500 crvUSD -> 500 USDT -> 500 frxUSD
then add 500 frxUSD + 500 additional crvUSD
total LP notional: 1,000
deployedCrvUsd increase: 1,000
```

### Shared target and yield pool

When `targetAmm == yieldAmm`, `targetAsset` must equal `yieldToken` and the expansion path must be empty. V3 does not swap before providing liquidity.

For requested amount `X` and pre-existing donated yield value `D`:

```text
pool deposit = (X + D) crvUSD + donated yieldToken
principal increase = X + D
```

With no donated yield token, V3 deposits only `X` crvUSD. This is the direct-pool special case. Donations are still swept and matched; they are not stranded.

## Donation and reward attribution

A yield-token donation is protocol property, not keeper-created profit. Expansion therefore uses this baseline:

```text
baseline = LP value before + normalized donated yieldToken value before
principal = all crvUSD spent by this expansion
position gain = LP value after - baseline
realized profit = max(position gain - principal, 0)
```

The keeper receives:

```text
rewardValue = floor(realizedProfit * keeperProfitShareBps / 10_000)
rewardLp    = floor(rewardValue * 1e18 / postDepositVirtualPrice)
```

After reward, retained LP value above the donation-adjusted baseline must cover principal plus the entry margin. A caller cannot donate yield tokens and claim a percentage of the donation as action profit.

Direct LP-token donations increase backing and surplus immediately through the live LP balance. They are not action-local expansion output.

## Dedicated yield-token donation sweep

`sweepDonatedYield(maxYieldTokenAmount)` is a permissionless LP-deployment action for loose `yieldToken` received outside an expansion. It is independent of the target AMM and typed expansion path, so target-market conditions do not prevent donated frxUSD from entering the fixed LP.

Let `D` be the normalized value of the selected donation, `C` the yield AMM's crvUSD balance, and `Y` the normalized value of its yield-token balance. The desired crvUSD match is:

```text
aggregate price >= 1e18: desiredMatch = D
aggregate price <  1e18: desiredMatch = min(D, max(Y + D - C, 0))
actualMatch = min(desiredMatch, available crvUSD/capacity/velocity budget)
```

Below peg, the donation is deposited one-sided while it reduces an existing crvUSD excess. Only the portion that would otherwise overshoot balance is matched. For example, `500 crvUSD / 450 frxUSD` plus a `100 frxUSD` donation deposits `50 crvUSD / 100 frxUSD`, ending at `550 / 550`.

The call:

1. selects at most `maxYieldTokenAmount` from the live donated yield-token balance;
2. requires its normalized value to meet `minExpansionAmount`;
3. requires a healthy yield-token oracle;
4. determines the regime-aware, balance-restoring crvUSD match above;
5. consumes expansion capacity and velocity by only that matched crvUSD;
6. deposits both assets atomically into `yieldAmm` and measures exact token and LP deltas;
7. increases `deployedCrvUsd` by only the matched crvUSD.

The amount bound allows a large donation to be swept in executable chunks rather than forcing an all-balance operation. Expansion and global pauses still block the action. The selected donation is always LP-settled atomically; only its crvUSD match consumes capacity and velocity or increases debt.

Donation value is excluded from keeper-profit attribution. It may absorb LP deposit cost because it is free protocol equity, but after any reward the LP-value increase must still cover the newly matched crvUSD plus the configured entry margin. Any failure reverts the complete sweep.

## Static LP contraction

`contractViaAmm(lpTokenAmount)` requires aggregate crvUSD price at most `1e18` and has one fixed path:

```text
held yieldAmm LP
    -> remove_liquidity_one_coin(lpTokenAmount, crvUsdIndex, minCrvUsd)
    -> crvUSD
```

Execution uses:

```text
quote       = yieldAmm.calc_withdraw_one_coin(lpTokenAmount, crvUsdIndex)
minCrvUsd   = floor(quote * (10_000 - yieldAmmExecutionBufferBps) / 10_000)
valueBefore = floor(lpBefore * vpBefore / 1e18)
valueAfter  = floor(lpAfter  * vpAfter  / 1e18)
valueRemoved = valueBefore - valueAfter
```

The call requires:

- exact requested LP burn by measured balance delta;
- quoted and measured crvUSD output no greater than the pre-action local contraction allowance;
- measured crvUSD receipt at least `minCrvUsd`;
- `valueBefore >= valueAfter` and positive `valueRemoved`;
- realized gross profit at least `500 ppm` (`5 bp`) of `valueRemoved`, before the caller share is paid;
- remaining LP value at least remaining `deployedCrvUsd`.

Virtual price is deliberately not used as `minCrvUsd`. The executable one-coin quote provides slippage protection; whole-position virtual-price deltas provide accounting.

`previewKeeperBuyback(lpTokenAmount)` estimates the same fixed one-coin withdrawal and enforces pause state, aggregate direction, intervention delay, local contraction allowance, the gross exit margin, and final backing-versus-debt solvency before returning. Its input is LP tokens and no configurable path executes.

At the exact `5 bp` gross boundary, a `30%` caller share pays `1.5 bp` to the keeper and leaves `3.5 bp` for the protocol. Deficit recovery is principal rather than gross profit, so any required solvency recovery must occur before this split. Same-block direct expansion, routed expansion, and donation-sweep round trips without `5 bp` of realized gross edge fail in both preview and execution. Curve entry/exit fees and slippage reduce rather than create the required edge.

## Typed expansion routes

Only the expansion path remains configurable. Supported route kinds are:

| Kind | Operation |
|---:|---|
| `0` | Curve exact-input swap |
| `1` | Dai <-> USDS |
| `2` | ERC-4626 deposit |
| `3` | ERC-4626 redeem |
| `4` | Frax USDC -> frxUSD mint |

A nonempty path must start with `targetAsset`, preserve token continuity, and end with `yieldToken`. It is empty only when `targetAsset == yieldToken`. The route is exact-input, uses temporary exact approvals reset to zero, enforces per-step quote floors and normalized loss bounds, and reverts the complete expansion on failure.

There is no isolated downstream subcall, fallback settlement gas reserve, downstream-deployment pause, contraction path, or later undeployed-backing action.

## Pauses and roles

Directions are:

```text
0 expansion
1 LP contraction
2 all execution
```

Factory `admin()` may pause or unpause. `emergency_admin()` may only pause. Every proxy starts with all three directions paused.

The Factory's immutable implementation/proxy design, existing dynamic shared roles, `execute()` recovery hook, `reduce_deployed_crvusd()`, ownership transfer, and fee-receiver handling remain unchanged. The aggregate oracle joins the Factory's live shared policy.

## Capacity and velocity

Expansion consumes pressure by total crvUSD externalized, including matched liquidity. The default bucket remains:

```text
max burst = 5% of maxDeployedCrvUsd
full refill = 300 seconds
```

A reverted expansion, donation sweep, or surplus claim consumes no pressure. Contraction does not refund pressure. The bucket remains active alongside the local intervention share and delay; none replaces another.

`available_expansion()` returns zero while expansion/global execution is paused, aggregate crvUSD price is below `1e18`, or the intervention delay has not elapsed. Otherwise it reports the minimum of the local target-pool allowance, idle balance, local/Factory capacity, and velocity. A separate-pool caller must preview its proposed first-leg amount because matched crvUSD makes total consumption larger than the `expand()` input.

## Surplus

`protocol_surplus()` is LP value above `deployedCrvUsd`. Before calculating claimable profit, `claimSurplus()` LP-settles the complete loose yield-token balance using the same regime-aware matching rule as the dedicated sweep. It reserves capacity and velocity for the requested claim before optional donation matching. It then transfers only idle crvUSD, remains velocity/capacity bounded, increases `deployedCrvUsd`, and must leave LP backing solvent.

`claimSurplus()` is deliberately not aggregate-direction-gated: realized yield remains claimable during contraction cycles. Donation value becomes protocol LP equity rather than a direct token payout. LP tokens and loose yield tokens are never sent as fees.

## Public action surface

```solidity
function expand(uint256 crvUsdAmount) external returns (
    uint256 crvUsdSold,
    uint256 crvUsdMatched,
    uint256 lpTokensReceived,
    uint256 keeperRewardLp,
    bool directDeposit
);

function sweepDonatedYield(uint256 maxYieldTokenAmount) external returns (
    uint256 yieldTokenSwept,
    uint256 crvUsdMatched,
    uint256 lpTokensReceived,
    uint256 keeperRewardLp
);

function previewExpansion(uint256 crvUsdAmount) external view returns (
    uint256 expectedTargetOut,
    uint256 expectedCrvUsdMatched,
    uint256 expectedGrossProfit,
    uint256 expectedKeeperRewardLp,
    uint256 expectedLpTokens,
    bool directDeposit
);

function contractViaAmm(uint256 lpTokenAmount) external returns (
    uint256 lpTokensBurned,
    uint256 crvUsdReceived,
    uint256 keeperReward
);

function previewKeeperBuyback(uint256 lpTokenAmount) external view returns (
    uint256 expectedCrvUsd,
    uint256 expectedGrossProfit,
    uint256 expectedKeeperReward
);

function set_intervention_policy(
    uint256 maxInterventionShareBps,
    uint256 minInterventionDelay
) external;
```

## Deployment and release state

The environment-free deployer creates four contracts: preview module, locked implementation, Factory, and one frxUSD Chainlink adapter. The Factory is initialized with the existing canonical aggregate crvUSD oracle. It no longer creates target-token oracle adapters or FraxNet redemption accounts.

The launch proposal deploys three paused keepers. Each receives the same fixed `yieldAmm` and `yieldToken = frxUSD`; USDC and USDT retain their typed expansion paths. No contraction path calldata exists.

Current compiled bounds under Vyper `0.3.10 --optimize codesize`, Shanghai:

```text
implementation initcode: 22,237 bytes
implementation runtime:  22,104 bytes
Factory core runtime:      3,780 bytes
Factory deployed runtime:  3,844 bytes
Chainlink oracle core:        460 bytes
Chainlink oracle runtime:     556 bytes
preview initcode:         5,781 bytes
preview runtime:          5,745 bytes
minimal proxy runtime:       45 bytes
EIP-170 headroom:          2,472 bytes
```

The published `deployments/mainnet/PegKeeperV3-release.json` and `docs/pegkeeper-v3-release-checklist.md` describe the earlier `3.0.0` release candidate. They are intentionally not rewritten as evidence for this unreleased branch. `make check-release-evidence`, included by `make check`, proves those files and their verifier still match commit `c3a07b66517d91430c0b739f86e4b7c921d9510f`. Full manifest verification remains intentionally checkout-sensitive.

## Required verification

Before this variant can replace the released baseline:

1. Compile with pinned Vyper and Shanghai settings.
2. Run unit, Factory, deployment, proposal, ABI-parity, and runtime-size checks.
3. Run the pinned mainnet canary through real StableSwap-NG dynamic-array deposits and one-coin withdrawal.
4. Re-run stateful invariants for LP backing, donations, capacity, velocity, pauses, exact approvals, and debt reduction.
5. Re-pin current mainnet routes, retained-backing oracle state, pool coin order, liquidity, fees, virtual price, and one-coin exit economics.
6. Generate a new release manifest rather than mutating `3.0.0` evidence.
7. Obtain explicit governance authorization before any deployment, allocation, registration, activation, or broadcast.
