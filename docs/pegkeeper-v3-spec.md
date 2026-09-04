# PegKeeper V3 LP-yield specification

Status: unreleased `3.1.0` candidate on the `lp-yield` branch. Not deployed. Nothing in this document authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## Model

PegKeeper V3 holds a Curve two-coin pool's LP token as backing.

Each deployment fixes:

- `targetAmm`: the crvUSD/target pool used to detect and execute expansion;
- `targetAsset`: the non-crvUSD coin in `targetAmm`;
- `yieldToken`: the non-crvUSD coin paired with crvUSD in the backing pool;
- `yieldAmm`: the Curve backing pool and its ERC-20 LP token;
- `backingAsset`: `yieldToken` in vanilla mode or `yieldToken.asset()` in ERC-4626 mode;
- mandatory target and yield-token oracle adapters.

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

`deployedCrvUsd` records crvUSD externalized by successful expansion or a surplus claim. Idle crvUSD held by the keeper is not counted as deployed debt.

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

Mandatory target and yield-token oracles gate new expansion and conservatively haircut `oracle_backing_value()`. `trusted_backing_value()` uses LP virtual price directly. Virtual price is an accounting value, not an executable withdrawal quote.

## Expansion

Expansion is keeper-driven and all-or-nothing.

### Separate target and yield pools

For an input `X`:

1. Verify expansion/global pause state, amount floor, target oracle, and yield-token oracle.
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

`sweepDonatedYield(maxYieldTokenAmount)` is a permissionless LP-deployment action for loose `yieldToken` received outside an expansion. It is independent of the target AMM, target oracle, and typed expansion path, so a target-market downturn does not prevent donated frxUSD from entering the fixed LP.

The call:

1. selects at most `maxYieldTokenAmount` from the live donated yield-token balance;
2. requires its normalized value to meet `minExpansionAmount`;
3. requires a healthy yield-token oracle;
4. matches it with equal-value crvUSD;
5. consumes expansion capacity and velocity by only that matched crvUSD;
6. deposits both assets atomically into `yieldAmm` and measures exact token and LP deltas;
7. increases `deployedCrvUsd` by only the matched crvUSD.

The amount bound allows a large donation to be swept in executable chunks rather than forcing an all-balance operation. Expansion and global pauses still block the action because it externalizes new crvUSD. Successful sweeps update `lastExpansionAt`; the minimum prevents dust donations from cheaply resetting contraction age.

Donation value is excluded from keeper-profit attribution. It may absorb LP deposit cost because it is free protocol equity, but after any reward the LP-value increase must still cover the newly matched crvUSD plus the configured entry margin. Any failure reverts the complete sweep.

## Static LP contraction

`contractViaAmm(lpTokenAmount)` has one fixed path:

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
- measured crvUSD receipt at least `minCrvUsd`;
- `valueBefore >= valueAfter` and positive `valueRemoved`;
- post-reward net crvUSD at least `valueRemoved` plus the normal or early exit margin;
- remaining LP value at least remaining `deployedCrvUsd`.

Virtual price is deliberately not used as `minCrvUsd`. The executable one-coin quote provides slippage protection; whole-position virtual-price deltas provide accounting.

`previewKeeperBuyback(lpTokenAmount)` estimates the same fixed one-coin withdrawal. The historical function name is retained, but its input is LP tokens and no configurable path executes.

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

The immutable Factory implementation/proxy design, dynamic shared roles, `execute()` recovery hook, `reduce_deployed_crvusd()`, ownership transfer, and fee-receiver handling remain unchanged.

## Capacity and velocity

Expansion consumes pressure by total crvUSD externalized, including matched liquidity. The default bucket remains:

```text
max burst = 5% of maxDeployedCrvUsd
full refill = 300 seconds
```

A reverted expansion or donation sweep consumes no pressure. Contraction does not refund pressure.

`available_expansion()` reports the remaining aggregate crvUSD budget from idle balance, local/Factory capacity, and velocity. A separate-pool caller must preview its proposed first-leg amount because matched crvUSD makes total consumption larger than the `expand()` input.

## Surplus

`protocol_surplus()` is LP value above `deployedCrvUsd`. `claimSurplus()` may transfer only idle crvUSD, is velocity/capacity bounded, increases `deployedCrvUsd`, and must leave LP backing solvent. LP tokens and loose yield tokens are not fee payouts.

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
```

## Deployment and release state

The environment-free deployer creates six contracts: preview module, locked implementation, immutable Factory, two Curve EMA adapters, and one frxUSD Chainlink adapter. It no longer creates FraxNet redemption accounts.

The launch proposal deploys three paused keepers. Each receives the same fixed `yieldAmm` and `yieldToken = frxUSD`; USDC and USDT retain their typed expansion paths. No contraction path calldata exists.

Current compiled bounds under Vyper `0.3.10 --optimize codesize`, Shanghai:

```text
implementation initcode: 20,077 bytes
implementation runtime:  19,944 bytes
preview initcode:         5,775 bytes
preview runtime:          5,739 bytes
minimal proxy runtime:       45 bytes
EIP-170 headroom:          4,632 bytes
```

The published `deployments/mainnet/PegKeeperV3-release.json` and `docs/pegkeeper-v3-release-checklist.md` describe the earlier `3.0.0` release candidate. They are intentionally not rewritten as evidence for this unreleased branch.

## Required verification

Before this variant can replace the released baseline:

1. Compile with pinned Vyper and Shanghai settings.
2. Run unit, Factory, deployment, proposal, ABI-parity, and runtime-size checks.
3. Run the pinned mainnet canary through real StableSwap-NG dynamic-array deposits and one-coin withdrawal.
4. Re-run stateful invariants for LP backing, donations, capacity, velocity, pauses, exact approvals, and debt reduction.
5. Re-pin current mainnet routes, oracle state, pool coin order, liquidity, fees, virtual price, and one-coin exit economics.
6. Generate a new release manifest rather than mutating `3.0.0` evidence.
7. Obtain explicit governance authorization before any deployment, allocation, registration, activation, or broadcast.
