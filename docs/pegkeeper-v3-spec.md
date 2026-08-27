# PegKeeper V3 specification

Status: design draft

This document records the current V3 direction. It is intentionally narrower than a complete implementation specification. Unresolved parameters and integration details are listed at the end rather than guessed.

## Summary

PegKeeper V3 is an asymmetric, protocol-owned peg module:

- **Above peg:** a permissionless keeper deploys crvUSD into a designated external crvUSD/stablecoin AMM, converts the stablecoin proceeds through an approved path, and finishes in a configured yield-bearing token.
- **Below peg:** users can sell crvUSD directly to V3. V3 atomically unwinds enough of the yield-bearing position through the reverse path and pays the user in the configured stablecoin.
- **Fallback below peg:** a permissionless keeper can unwind the yield-bearing position and buy crvUSD through the designated external AMM if direct buyback flow does not arrive.

V3 does not maintain a persistent balance of the intermediate stablecoin. For example, USDT may be the AMM-facing asset while sUSDe is the final yield token:

```text
Expansion:  crvUSD -> USDT -> USDe -> sUSDe
Contraction: sUSDe -> USDe -> USDT -> crvUSD
```

USDT and USDe are transient route assets. Successful state-changing calls should finish with only insignificant route dust outside crvUSD and the configured yield token.

## Goals

1. Expand crvUSD supply when crvUSD trades above peg.
2. Turn expansion proceeds into a productive yield-bearing position.
3. Offer explicit buyback liquidity when crvUSD trades below peg.
4. Reuse bought-back crvUSD during later expansions.
5. Execute only when the complete transaction is profitable after conversion costs and keeper compensation.
6. Pay keepers a governance-set percentage of realized profit, clamped by a maximum reward rate on action notional so splitting cannot bypass the bound.
7. Keep expansion and fallback contraction open to any keeper without a whitelist or private-submission requirement.
8. Expand immediately whenever the complete entry route is locally non-loss-making and satisfies the configured entry margin.
9. Prevent routine rapid expansion/contraction churn while allowing early contraction at a sufficiently profitable distressed exit.
10. Allow governance to replace broken or obsolete swap paths without replacing V3.
11. Include first-class directional pauses, shutdown, and migration controls.
12. Give the governance owner an unrestricted external-call escape hatch for urgent recovery and migration.

## Non-goals

V3 is not intended to:

- manage a conventional two-sided StableSwap LP position;
- maintain a liquid buffer of the AMM-facing stablecoin;
- accept public LP deposits;
- issue an LP token in the first version;
- expose arbitrary routers, calldata, recipients, or tokens chosen by callers;
- guarantee that a yield token can always be redeemed atomically;
- reuse V2's pool-balance accounting or uncapped caller-profit formula.

## Terminology

- **crvUSD:** the stablecoin whose supply V3 expands and contracts.
- **Target AMM:** the external crvUSD/stablecoin pool used by keeper expansion and fallback contraction.
- **Target asset:** the non-crvUSD coin in the target AMM, such as USDT.
- **Backing asset:** the approved stablecoin immediately before yield deployment, such as USDS before an sUSDS deposit.
- **Yield token:** the final token held after the expansion path, such as sUSDe.
- **Expansion path:** the updatable sequence from the target asset to the yield token.
- **Contraction path:** the updatable sequence from the yield token back to the target asset.
- **Mature deployment state:** the configured minimum market time has elapsed since the latest successful material expansion.
- **Young deployment state:** V3 remains inside the minimum market-time window following the latest successful material expansion.
- **Deployed crvUSD:** Factory-allocated crvUSD that V3 has sold and has not yet reacquired.
- **Idle crvUSD:** crvUSD held by V3 and therefore available for a later expansion or Factory debt reduction.

## Actors

### Governance

Governance configures debt capacity, the target AMM, route endpoints, paths, execution constraints, profitability thresholds, trade caps, keeper fees, and the fee receiver. Route changes are delayed. The governance owner can also make an arbitrary external call through `execute()` when a typed path or normal migration flow is insufficient.

### Emergency admin

The emergency admin can immediately disable expansion, direct buyback, keeper buyback, or all execution. It cannot install a new path or move funds to an arbitrary address.

### Keeper

Any account can call the expansion and fallback contraction functions. V3 does not rely on a keeper whitelist or private order flow. Keeper rewards are paid to `msg.sender`, are capped by split-invariant rates, and are paid only after a successful profitable transaction. The keeper chooses the exact amount, but cannot weaken protocol bounds, paths, minimum outputs, or profitability conditions.

### Arbitrageur or user

Any account can sell crvUSD directly to V3 through the buyback function while that direction is enabled. The caller receives the target asset and pays the route gas. No additional keeper reward is paid for this direct trade.

### Fee receiver

The fee receiver receives only realized surplus above the amount required to support outstanding deployed crvUSD and pending obligations. Principal yield-token shares cannot be withdrawn as fees.

## State model

A minimal implementation needs the following state:

```text
factory
targetAmm
targetAsset
backingAsset
yieldToken
feeReceiver

deployedCrvUsd
expansionPath
contractionPath

entryMinProfitBps
normalExitMinProfitBps
earlyExitMinProfitBps
maxExecutionSlippageBps
keeperProfitShareBps
maxKeeperRewardBps

minDeploymentTime
minExpansionAmount
lastExpansionAt

maxExpansionPerCall
maxBuybackPerCall
maxDeployedCrvUsd

expansionPaused
directBuybackPaused
keeperBuybackPaused
shutdown
```

The exact storage representation is deferred until the implementation language and path-step bounds are selected.

## Supply accounting and Factory integration

The current ControllerFactory mints the configured debt-ceiling increase to V3 upfront. It does not grant V3 a permissionless lazy-mint function.

The first implementation should therefore treat the Factory allocation as reusable inventory:

```text
Idle crvUSD
    -> expansion
Yield-token position
    -> contraction
Idle crvUSD
```

`expand()` deploys idle Factory-allocated crvUSD. It does not mint directly under the current Factory interface. A future Factory adapter may support lazy minting, but that is a separate governance and security decision.

crvUSD received during contraction remains idle in V3 and is out of active circulation. It can be reused in a later expansion. Governance can lower the Factory ceiling when it wants returned idle crvUSD burned.

A burn-only timer would not prevent market churn. Reacquiring crvUSD already removes it from active circulation; waiting to destroy the idle tokens changes Factory accounting but does not postpone the economic contraction. The timer must therefore gate use of the yield position for buyback, not merely the later burn transaction. Once crvUSD has been reacquired, governance may burn it immediately by lowering the Factory ceiling.

### Trusted backing convention

The current ControllerFactory does not inspect or mark to market assets held by a debt-ceiling recipient. It mints the allocation to the approved PegKeeper address and, when lowering the ceiling, burns only crvUSD currently held by that address.[2] Solvency therefore already depends on governance admitting a PegKeeper whose deployed assets are acceptable backing.

V3 makes that trust assumption explicit and narrow:

- governance approves the AMM-facing stablecoin, yield token, vault underlying, and typed conversion paths;
- one normalized unit of an approved backing stablecoin is accounted as one dollar and one crvUSD unit;
- yield-token shares are not treated as one dollar each; they are converted into units of the approved underlying through the configured vault or adapter;
- only the configured backing position counts toward V3 principal and surplus accounting;
- unsolicited tokens and arbitrary assets sent to V3 do not count as backing.

For an ERC-4626-style sUSDe position:

```text
trustedBackingValue(sUSDe shares)
    = normalizeTo1e18(convertToAssets(sUSDe shares))
```

The returned USDe units are then trusted at par because USDe and the sUSDe position were approved by governance as PegKeeper backing. No target-AMM spot price is used to value the final position.

This is a protocol accounting convention, not proof that every approved stablecoin can always be sold for one dollar. If an approved backing asset depegs, freezes, or becomes non-redeemable, V3 can remain nominally solvent under its configured accounting while being economically impaired. Governance must pause affected routes and use path migration or owner `execute()` to move the position.

The core accounting invariant is:

```text
deployedCrvUsd <= Factory allocation
deployedCrvUsd <= trustedBackingValue(yieldPosition)
```

Expansion increases `deployedCrvUsd` by the crvUSD sold. Direct buyback decreases it by crvUSD received from the user; fallback contraction decreases it by crvUSD retained after the keeper reward, always capped at the current deployed amount. Idle crvUSD backs itself; the trusted backing value of the yield position must cover the portion currently deployed into the market after keeper rewards and fee claims.

## Expansion lifecycle

Expansion is keeper-driven. V3 does not offer a separate direct upward-price quote in the initial design.

Expansion has no time cooldown. It should execute immediately whenever the complete atomic route satisfies the internal output checks and leaves V3 with at least principal and the configured entry margin after paying the profit-share keeper reward. A zero-basis-point entry margin still means local break-even after every swap cost and keeper reward; it does not permit a nominally positive AMM quote that leaves the final backing position short.

```text
1. Verify expansion is enabled.
2. Do not require the target AMM spot price to remain close to its EMA. A sharp upward move in crvUSD is the opportunity V3 is meant to act on.
3. Verify the keeper's requested amount is at least `minExpansionAmount` and within idle crvUSD, per-call, and max-deployed limits.
4. Sell crvUSD into the designated target AMM.
5. Receive the target asset.
6. Execute the configured conversion steps from target asset to backing asset.
7. Measure the actual backing-asset balance delta and normalize it to 18-decimal accounting units.
8. Calculate gross entry profit as normalized backing asset received minus crvUSD sold.
9. Calculate the keeper reward as the configured percentage of gross entry profit, clamped by `maxKeeperRewardBps` of crvUSD sold, and transfer it to `msg.sender` in the backing asset.
10. Deploy all remaining backing asset through the configured terminal yield step.
11. Measure actual yield-token shares received by balance delta.
12. Convert the received yield shares into approved underlying units and verify that the remaining position satisfies both the protocol net-profit floor and the internally calculated execution-quality floor.
13. Increase deployedCrvUsd and set `lastExpansionAt` to the current timestamp.
14. Emit the complete execution result, gross profit, keeper reward, and maturity time.
```

A preliminary interface is:

```solidity
function expand(uint256 crvUsdAmount) external returns (
    uint256 crvUsdSold,
    uint256 yieldSharesReceived,
    uint256 keeperReward
);
```

The keeper chooses only the exact crvUSD amount. V3 validates its bounds and calculates gross profit, reward, and every intermediate and final minimum internally. The keeper cannot choose the target AMM, path, output token, fee receiver, reward recipient, fee percentage, reward cap, or minimum output.

The keeper's proposed amount should be previewable:

```solidity
function previewExpansion(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedBackingAssetOut,
        uint256 expectedGrossProfit,
        uint256 expectedKeeperReward,
        uint256 expectedYieldShares
    );
```

## Direct buyback lifecycle

Direct buyback provides one-sided downward liquidity.

```text
1. Verify direct buyback is enabled.
2. Transfer crvUSD from the caller to V3.
3. Bound the transaction by deployed crvUSD and the per-call buyback limit.
4. Determine whether V3 is in the mature or young deployment state.
5. Select the normal exit margin in the mature state or the higher early exit margin in the young state.
6. Determine the maximum yield-token shares that may be spent while preserving the selected margin.
7. Execute the contraction path atomically from yield token to target asset.
8. Measure actual target asset received.
9. Verify the crvUSD received exceeds the trusted backing value of yield-token shares spent by the selected margin.
10. Transfer the target asset to the caller.
11. Reduce deployedCrvUsd by the crvUSD reacquired.
12. Retain the crvUSD as idle inventory.
13. Emit the shares spent, target asset paid, crvUSD reacquired, and whether early exit was used.
```

A preliminary interface is:

```solidity
function buyback(
    uint256 crvUsdAmount,
    uint256 minTargetOut
) external returns (uint256 targetOut, uint256 yieldSharesSpent);
```

The entire call reverts if the contraction path cannot produce an acceptable output. V3 does not promise target-asset liquidity independently of the configured path.

The direct quote should be previewable:

```solidity
function previewBuyback(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedTargetOut,
        uint256 maxYieldShares,
        uint256 requiredExitProfit,
        bool earlyExit
    );
```

The preview is advisory. Execution uses balance deltas and post-transaction profitability checks.

`minTargetOut` is retained here because the direct buyback caller receives the target asset and may require stricter personal slippage protection. The effective minimum is the greater of the user's minimum and V3's internally calculated protocol minimum. Passing zero cannot weaken V3's floor.

## Keeper buyback fallback

If no direct buyback flow arrives, a keeper can contract supply through the target AMM:

```text
1. Verify keeper buyback is enabled.
2. Determine whether V3 is in the mature or young deployment state.
3. Select the normal or early exit margin accordingly.
4. Verify the keeper's requested yield-share amount is within per-call, backing, and deployed-crvUSD bounds.
5. Execute the contraction path from yield token to target asset.
6. Swap the target asset for crvUSD in the designated target AMM.
7. Calculate gross exit profit as crvUSD received minus the trusted backing value of yield-token shares spent.
8. Calculate the keeper reward as the configured percentage of gross exit profit, clamped by `maxKeeperRewardBps` of trusted backing value spent, and pay it to `msg.sender` in crvUSD.
9. Verify the net crvUSD retained after the reward exceeds the trusted backing value spent by the selected exit margin.
10. Reduce deployedCrvUsd by the net crvUSD retained, capped at the deployed amount.
11. Keep the remaining recovered crvUSD idle.
```

A preliminary interface is:

```solidity
function contractViaAmm(uint256 yieldShares)
    external
    returns (uint256 yieldSharesSpent, uint256 crvUsdReceived, uint256 keeperReward);
```

The keeper chooses only the exact yield-token shares. V3 calculates the target-asset minimum, crvUSD minimum, realized profit, and reward internally.

The keeper's proposed fallback should also be previewable:

```solidity
function previewKeeperBuyback(uint256 yieldShares)
    external
    view
    returns (
        uint256 expectedCrvUsdOut,
        uint256 expectedGrossProfit,
        uint256 expectedKeeperReward,
        bool earlyExit
    );
```

## Updatable path system

The path design is adapted from Resupply's `TreasuryStableDiversification`, which stores a governance-replaceable typed target sequence, validates pool and ERC-4626 relationships, uses exact temporary approvals, and measures outputs by balance delta.[1]

V3 should keep the same useful properties while narrowing the allowed operations.

### Supported step types

The first version should support only typed operations:

```solidity
enum StepKind {
    CurveSwap,
    ERC4626Deposit,
    ERC4626Redeem
}

struct RouteStep {
    StepKind kind;
    address venue;
    address tokenIn;
    address tokenOut;
    uint16 executionBufferBps;
}
```

No normal route step accepts arbitrary calldata. Additional venue types require a code change or a separately audited typed adapter. This restriction applies to permissionless execution paths, not the governance owner's separate `execute()` escape hatch.

### Separate directional paths

Expansion and contraction paths are configured separately. V3 must not assume that the reverse path has the same venue, cost, liquidity, or safety parameters.

Example expansion path:

```text
USDT --CurveSwap(USDT/USDe)--> USDe
USDe --ERC4626Deposit(sUSDe)--> sUSDe
```

Example contraction path:

```text
sUSDe --ERC4626Redeem(sUSDe)--> USDe
USDe --CurveSwap(USDe/USDT)--> USDT
```

### Path validation

A path is valid only when:

1. The expansion path starts with `targetAsset` and ends with `yieldToken`.
2. The contraction path starts with `yieldToken` and ends with `targetAsset`.
3. Every step's `tokenOut` equals the next step's `tokenIn`.
4. The expansion path has a distinguished terminal deployment step whose input is `backingAsset` and output is `yieldToken`.
5. The contraction path has a distinguished first unwind step whose input is `yieldToken` and output is `backingAsset`.
6. A Curve step's pool contains both configured tokens.
7. An ERC-4626 deposit step uses `vault.asset() == tokenIn` and the vault share token as `tokenOut`.
8. An ERC-4626 redeem step uses the vault share token as `tokenIn` and `vault.asset()` as `tokenOut`.
9. Execution-buffer parameters remain within governance-set maxima.
10. The path length is bounded.
11. No venue, token, or endpoint is zero.

Changing the target AMM, target asset, or yield token requires applying a complete compatible configuration bundle. Governance cannot leave active paths with mismatched endpoints.

### Path governance

Path replacement is a privileged operation capable of directing the protocol's full conversion flow. It should use delayed two-step governance:

```solidity
function commitPaths(
    RouteStep[] calldata newExpansionPath,
    RouteStep[] calldata newContractionPath
) external;

function applyPaths() external;
function cancelPendingPaths() external;
```

`commitPaths` validates and stores the pending configuration hash and activation time. `applyPaths` validates again before replacing both active paths atomically.

The emergency admin may disable a path immediately but cannot apply a new one.

### Path execution

For every step:

1. Record the output-token balance before execution.
2. Approve only the exact input amount.
3. Execute the typed venue call.
4. Reset the approval to zero.
5. Compute output from the balance delta.
6. Enforce the step's minimum output.
7. Feed the measured output into the next step.

Successful expansion and contraction calls must consume the entire routed input except for bounded rounding dust.

## Keeper-supplied sizing

The split-invariant reward formula removes the compensation reason for V3 to search for a maximum trade size onchain. A keeper may choose an exact amount, while V3 retains every safety decision.

For expansion:

```text
minExpansionAmount <= crvUsdAmount

crvUsdAmount <= min(
    idleCrvUsd,
    maxExpansionPerCall,
    maxDeployedCrvUsd - deployedCrvUsd
)
```

Fallback contraction applies equivalent limits to the requested yield shares and their trusted backing value. The contract executes the requested amount exactly or reverts; it does not silently resize the transaction.

The keeper can use `previewExpansion(amount)` or `previewKeeperBuyback(shares)` offchain to select an economically useful amount. Onchain, V3 still calculates every intermediate minimum, profit-share reward, notional reward cap, and final post-reward margin. A keeper-supplied amount can cause its own transaction to revert but cannot make an unsafe amount execute.

Under-sizing may leave a second profitable action available, but it does not increase aggregate keeper compensation beyond the split-invariant profit and notional bounds. The keeper also pays additional gas for each split. Open competition allows another keeper to consume the remaining opportunity. This simpler model avoids quote-loop gas, monotonicity assumptions, and preview-induced sizing failures.

`minExpansionAmount` remains important because a successful expansion resets the global contraction timer. It should be economically material and may be capacity-relative. Trade and rolling-flow caps remain protocol controls rather than keeper inputs.

## Profitability and execution controls

Realized profitability under the trusted-backing convention is the primary execution gate. V3 should not copy V2-style spot/EMA proximity checks onto the target crvUSD AMM: a sudden crvUSD price spike creates the exact expansion opportunity V3 should capture. Requiring spot to remain close to EMA would suppress the intended trade.

Expansion therefore succeeds only when the approved underlying units represented by the final yield-token shares received, after paying the keeper from gross route profit, exceed the crvUSD sold by at least the configured protocol margin. Intermediate USDT or USDe quotes are not sufficient; the safety check uses the end of the atomic path. The approved underlying unit is treated as one dollar without consulting the target AMM spot.

Contraction applies the inverse test: the crvUSD retained after paying the keeper from gross exit profit must exceed the trusted backing value consumed from the yield-token position by the configured margin.

Sandwich and execution protection should come from controls that do not reject the desired crvUSD dislocation:

- governance-set maximum trade sizes;
- a transaction deadline;
- protocol-calculated intermediate minimum outputs;
- a protocol-calculated final profit floor;
- a protocol-calculated execution-quality floor relative to the path output visible at execution time;
- direct-buyback user minimums that can only make execution stricter;
- measured token-balance deltas rather than trusting venue return values;
- exact temporary approvals reset after each step;
- a final post-route profitability assertion.

When deriving intermediate `minOut` values, V3 may normalize governance-approved stablecoin route assets to one-dollar units and apply a governance-set maximum loss for the specific step or complete route. That lets the contract calculate useful minimums without an external dollar oracle. Actual outputs are still measured by balance delta, and the final trusted-backing-value postcondition remains authoritative.

### DAO fee recapture

Route analysis must distinguish PegKeeper-local profitability from consolidated DAO economics.

At Ethereum block `25,844,317`, Curve 3pool had a `1.5` basis-point swap fee and `admin_fee = 100%`.[7] The full swap fee accrues as admin balances rather than remaining in LP virtual price. A 3pool swap made by V3 therefore reduces the assets received by V3, but the fee is captured by the Curve DAO fee system instead of external LPs.

This makes a route such as:

```text
USDC or USDT
-> DAI through 3pool
-> USDS through the canonical exact converter
-> sUSDS deposit
```

more attractive at the consolidated protocol level than its gross output haircut suggests. The DAI-to-USDS conversion and USDS-to-sUSDS deposit do not add percentage swap fees, so most of the explicit route fee is recycled to the DAO.

V3 must nevertheless enforce its hard profitability condition using only assets actually received by V3. Unclaimed 3pool admin fees are not held by the PegKeeper, are not atomically available as backing, and cannot be counted toward `trustedBackingValue(yieldPosition)`. Otherwise V3 could pass a consolidated-profit test while leaving its own backing position short.

The two views are therefore:

```text
Gross entry profit used for keeper compensation
    = normalized backing asset received before yield deployment
    - crvUSD deployed

PegKeeper-local net profit
    = trusted backing value of final yield shares
    - crvUSD deployed

DAO-consolidated profit
    = PegKeeper-local net profit
    + attributable DAO admin-fee accrual
```

The first is the onchain safety invariant. The second is an offchain route-selection and governance metric. Routes that return equivalent backing to V3 should prefer fees accruing to the DAO over fees retained by external LPs, but fee recapture must never weaken V3's `minOut` or final backing floor. Pool fee ownership is configuration-dependent and must be rechecked before governance installs or updates a route.

Optional depeg or venue-health checks may still protect the non-crvUSD conversion path, but they must be independent from the target AMM's crvUSD spot/EMA divergence and must not override a transaction that already proves sufficient realized final value. Caller minimums can only make execution stricter; they cannot weaken protocol minimums.

For expansion, V3 first calculates the keeper reward from the realized backing-asset output immediately before yield deployment:

```text
require normalize(backingAssetOut) >= crvUsdSold
grossEntryProfit = normalize(backingAssetOut) - crvUsdSold

keeperRewardValue = min(
    floor(grossEntryProfit * keeperProfitShareBps / 10_000),
    floor(crvUsdSold * maxKeeperRewardBps / 10_000)
)

keeperRewardTokens = denormalizeDown(keeperRewardValue)
backingAssetToDeploy = backingAssetOut - keeperRewardTokens
```

If normalized backing output does not exceed crvUSD sold, gross entry profit and keeper compensation are zero and the transaction cannot pass any positive entry margin. Reward conversion rounds down so decimal normalization cannot overpay the keeper.

V3 then calculates the final yield-share minimum after subtracting the reward:

```text
profitFloor = sharesRequiredForTrustedAssets(
    crvUsdSold + entryMargin
)

executionFloor = expectedFinalShares
    * (1 - maxExecutionSlippageBps)

protocolMinShares = max(profitFloor, executionFloor)
```

`expectedFinalShares` comes from the configured target AMM quote, each typed path preview, the expected profit-share reward, and the terminal yield-deployment preview. Actual shares are measured by balance delta. Share count is not compared directly with deposited underlying because a yield-token share need not equal one underlying unit. `sharesRequiredForTrustedAssets` converts the required approved-underlying units into shares through the configured vault or adapter; it does not derive a dollar price from the crvUSD target AMM.

### Expansion postcondition

```text
trustedBackingValue(yieldSharesReceived)
>= crvUsdSold
 + entryMargin
```

### Direct buyback postcondition

```text
crvUsdReceived
>= trustedBackingValue(yieldSharesSpent)
 + selectedExitMargin
```

### Keeper buyback postcondition

```text
grossExitProfit
    = crvUsdReceived
    - trustedBackingValue(yieldSharesSpent)

keeperReward = min(
    floor(grossExitProfit * keeperProfitShareBps / 10_000),
    floor(
        trustedBackingValue(yieldSharesSpent)
        * maxKeeperRewardBps
        / 10_000
    )
)

crvUsdReceived - keeperReward
>= trustedBackingValue(yieldSharesSpent)
 + selectedExitMargin
```

The implementation still needs an asset-specific adapter interface and exact rounding direction. Expansion must round required shares up, reward-token conversion down, and surplus calculations down.

## Asymmetric timing and carry

Entry and exit should not have symmetric urgency.

### Entry policy

Expansion should remain immediately callable with no time delay:

```text
entryMargin = crvUsdSold * entryMinProfitBps / 10_000

trustedBackingValue(yieldSharesReceived)
>= crvUsdSold + entryMargin
```

`entryMinProfitBps` may be set to zero. That does not socialize route loss: because the check uses final backing after all swaps and after the keeper takes its share of gross profit, a zero entry margin still requires the crvUSD premium to cover every local route cost and keeper compensation. If the route costs two basis points, the realized premium must exceed those costs enough for the remaining post-reward yield position to cover principal. Adding a one-basis-point entry margin requires the protocol's retained post-reward profit to cover another basis point.

Expansion should not wait for a timer, EMA, or accumulated yield. If the complete atomic trade is acceptable now, delaying it gives away the above-peg opportunity.

### Exit policy

Routine contraction in the mature deployment state requires a governance-set `normalExitMinProfitBps`. While V3 remains in the young deployment state, contraction must instead satisfy the larger `earlyExitMinProfitBps`:

```text
selectedExitMarginBps =
    block.timestamp < lastExpansionAt + minDeploymentTime
        ? earlyExitMinProfitBps
        : normalExitMinProfitBps

earlyExitMinProfitBps > normalExitMinProfitBps >= entryMinProfitBps
```

The higher early-exit margin acts as the distress override. A sufficiently deep below-peg dislocation naturally creates enough realized buyback profit to satisfy it, allowing V3 to contract before maturity without trusting a separately manipulable spot-price trigger. Mild volatility cannot wash newly expanded exposure back and forth unless it pays the protocol's larger early-exit spread.

This produces the intended asymmetry:

```text
Above peg and locally profitable:
    expand immediately

Below peg after minimum market time:
    contract at normal exit margin

Below peg before minimum market time:
    contract only at the higher early/distress margin
```

### Carry horizon

At a simple annualized stablecoin yield of `4%` to `5%`, earning one basis point takes approximately:

```text
4% APR: 21.9 hours
5% APR: 17.5 hours
```

One full day earns approximately `1.10` to `1.37` basis points at those rates. A one-day minimum deployment time is therefore a reasonable initial reference if the objective is to let roughly one basis point of carry accrue before a routine exit.

The timer must not be used as a solvency assumption. Yield can change, stop, or become impaired. Every contraction still has to pass its realized final-value condition. Carry only improves the economics of holding exposure through short-lived volatility.

### Material-expansion timer

A single global `lastExpansionAt` is acceptable for the initial design if only a material successful expansion can reset it. The keeper chooses the amount, but `expand()` can complete only when the sale meets `minExpansionAmount` and receives acceptable final backing after route costs and the keeper reward.

The normal-exit timer is:

```text
earlyExit =
    deployedCrvUsd > 0
    && block.timestamp < lastExpansionAt + minDeploymentTime
```

A caller can still flash-borrow liquidity, buy crvUSD to create an expansion opportunity, request the minimum accepted expansion, and sell back afterward. That can reset the timer, but it is not free. The actor pays the market round trip, AMM fees and slippage, and enough manipulated premium for at least `minExpansionAmount` of V3's complete entry route and keeper compensation to pass. Making the threshold capacity-relative prevents the reset cost from becoming economically negligible as the position grows.

The minimum makes timer manipulation economically self-penalizing rather than free. V3 sells the requested material amount into the price increase the actor created, so the attacker buys high, is countertraded by V3, then sells back lower while also paying pool fees. V3 captures the entry economics. This does not make manipulation cryptographically impossible: an actor with a sufficiently valuable external position may rationally pay that loss to delay normal-margin contraction. It cannot deadlock contraction because the timer never disables the exit functions; it only selects the higher early-exit margin. Genuinely distressed crvUSD can still be contracted during the timer while paying V3 that larger spread.

The global timer also means a sequence of legitimate profitable expansions extends the normal-exit delay for the whole position. That is consistent with the initial anti-churn objective and is considerably simpler than tranche accounting. If live behavior shows that old exposure remains locked too often, governance can migrate a later implementation to bounded maturity buckets.

`minExpansionAmount` should remain economically meaningful as capacity changes. Governance may express it as an absolute amount, a percentage of configured capacity, or the greater of both. The exact initial threshold remains to be selected.

## Open keeper and flash-liquidity model

Open keepers are an explicit design choice. V3 cannot prevent an account from using flash liquidity to move the target AMM, call `expand()` or `contractViaAmm()`, and reverse the market trade afterward.

The minimum-profit postcondition does not prevent that behavior and does not guarantee V3 captures every available basis point of market spread. It guarantees that any completed action leaves V3 with at least the configured nominal profit after the keeper reward under the approved-backing-at-par convention. A manipulator may capture residual spread, but cannot force V3 to complete below its own floor unless the configured vault or adapter accounting itself is compromised. A real depeg of an approved backing asset is governance collateral risk rather than target-AMM price manipulation.

The execution-quality floor prevents the configured route from performing materially worse than the quote visible when V3 executes. It cannot detect a malicious keeper that moved the AMM before the V3 transaction and restores it afterward. Preventing that completely would require a trusted price reference, auction, private order flow, or keeper whitelist. Those mechanisms are outside the current open-keeper design.

The practical V3 policy is therefore:

1. Accept that open execution can leak some transient market spread.
2. Require expansion to achieve local break-even after route costs and keeper reward, plus any configured entry margin.
3. Require contraction to achieve the selected normal or early exit margin after any keeper reward.
4. Bound transaction size and reject dust-sized reward farming.
5. Never trust keeper-provided minimum outputs.

### V2 comparison

V2 is not unprotected. Its regulator checks pool spot against the pool oracle for spam-attack protection, checks the aggregate crvUSD price and other registered pools, and can disable either direction. `PegKeeperV2` also uses a 12-second action delay, adjusts only one fifth of the observed imbalance per update, and reverts unless LP-accounting profit increases with `peg unprofitable`.

Those controls reduce simple one-block manipulation and prevent an immediately unprofitable V2 update. They do not prove that V2 captures all available spread or eliminate multi-transaction market manipulation. V3 keeps the economically necessary post-trade profit condition but does not copy a target-AMM spot/EMA proximity check that would suppress the upward price spike V3 is meant to monetize.

## Keeper compensation

Keeper compensation is a percentage of realized gross profit, clamped by a maximum basis-point rate on action notional:

```text
keeperReward = min(
    floor(grossProfit * keeperProfitShareBps / 10_000),
    floor(actionNotional * maxKeeperRewardBps / 10_000)
)
```

For expansion, `grossProfit` is normalized backing asset received immediately before the terminal yield deployment minus crvUSD sold, and `actionNotional` is crvUSD sold. The keeper is paid in that backing asset before the remaining balance is deployed. For keeper fallback contraction, `grossProfit` is crvUSD received minus trusted backing value spent, `actionNotional` is that trusted backing value, and the keeper is paid in crvUSD. Direct buyback callers receive no separate reward.

This cap is split-invariant. For any set of calls `i`, with gross profits `P_i`, notionals `N_i`, profit-share rate `s`, and notional reward cap `c`:

```text
sum(min(s * P_i, c * N_i))
<= min(s * sum(P_i), c * sum(N_i))
```

Splitting one expansion into multiple transactions, including transactions batched in one block, cannot increase total compensation above the same profit-share and notional-rate bounds applied to aggregate activity. Larger keeper-selected trades may improve peg effectiveness and gas efficiency, but reward safety does not depend on forcing maximum sizing.

The reward rules are:

1. `keeperProfitShareBps` cannot exceed `10_000` and should be materially lower so the protocol retains profit.
2. The reward is calculated from realized balance deltas, never a preview or caller-supplied value.
3. The reward is paid only after the route has produced positive gross profit and the complete state transition can satisfy the post-reward protocol margin.
4. The reward is paid to `msg.sender`; callers cannot supply an arbitrary beneficiary.
5. Decimal conversion rounds the reward down.
6. `maxKeeperRewardBps` limits compensation relative to action notional and cannot be bypassed by splitting notional across calls.
7. The reward cannot consume principal or the configured protocol margin.

No fixed stipend is paid. A keeper decides whether its percentage reward is worth its gas and execution risk. If governance also requires a hard dollar-denominated budget, it must be cumulative over a block or epoch rather than reset per call; such a budget can exhaust and suppress otherwise useful immediate execution, so it is not part of the minimal design.

## Fee receiver and surplus

Yield-token appreciation and execution spread create protocol surplus. Fee withdrawal must not reduce the trusted backing value supporting outstanding deployed crvUSD.

A withdrawal function should calculate the maximum withdrawable yield-token shares from current trusted backing value, rounding principal requirements against the fee receiver, and transfer no more than that amount.

```solidity
function claimSurplus(uint256 maxShares)
    external
    returns (uint256 sharesTransferred);
```

This function is permissionless to call but always pays the configured fee receiver.

## Curve compatibility

V3 is asymmetric. The first version does not need a full StableSwap invariant or LP token.

The direct buyback side may expose Curve-style two-coin methods where useful for routing:

```solidity
function coins(uint256 index) external view returns (address);
function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
```

Only the crvUSD-to-target-asset direction is directly executable. Upward expansion remains keeper-driven through the external target AMM. Unsupported directions must return no quote or revert consistently; exact router compatibility requires targeted integration testing before this surface is finalized.

V3 should not publish fake LP balances, virtual prices, or TVL merely to resemble StableSwap.

## Governance and emergency controls

Required controls:

- pause expansion;
- pause direct buyback;
- pause keeper buyback;
- global shutdown;
- lower trade and deployment caps immediately;
- delayed increases to caps;
- delayed target-AMM and path replacement;
- immediate cancellation of a pending path;
- fee-receiver update;
- first-class migration of the yield-token position;
- approval revocation for retired venues;
- owner-only arbitrary external execution for urgent recovery;
- expansion-disabled contraction-only offboarding mode.

Shutdown should stop new expansion while preserving a controlled path for reacquiring crvUSD and reducing deployed exposure.

## Owner execute escape hatch

The governance owner must be able to call an arbitrary target with arbitrary calldata:

```solidity
function execute(address target, uint256 value, bytes calldata data)
    external
    onlyOwner
    returns (bytes memory result);
```

This function exists for failures that the typed routes and normal migration functions cannot handle quickly enough. Examples include:

- loss of confidence in the current yield token or one of its underlying stablecoins;
- a vault, pool, or route changing behavior;
- an urgent migration to a replacement token or venue;
- recovery of tokens or approvals not anticipated by the original implementation;
- interacting with a one-off rescue contract approved by the DAO.

`execute()` performs a normal external `call`, not `delegatecall`. It bubbles the target's revert data and returns the target's return data. It has no target allowlist because an allowlist would defeat its role as a general recovery mechanism.

The owner is expected to be the same DAO or governance executor that already controls crvUSD minting, debt capacity, and protocol configuration. Within that governance trust model, `execute()` does not add a new trusted actor or materially expand the DAO's ultimate authority. It does increase the immediate blast radius of an owner compromise or governance mistake at this contract, so it must never be callable by keepers, public operators, or the emergency admin.

Governance should pause affected directions before using `execute()` where practical. If the call moves principal or changes token composition, normal execution remains paused until accounting and active paths match the post-recovery state.

## Events

At minimum:

```solidity
event Expanded(
    address indexed keeper,
    uint256 crvUsdSold,
    uint256 targetReceived,
    uint256 backingAssetReceived,
    uint256 yieldSharesReceived,
    uint256 grossProfit,
    uint256 keeperReward,
    uint256 unlockTime
);

event DirectBuyback(
    address indexed caller,
    uint256 crvUsdReceived,
    uint256 targetPaid,
    uint256 yieldSharesSpent,
    bool earlyExit
);

event KeeperBuyback(
    address indexed keeper,
    uint256 yieldSharesSpent,
    uint256 targetReceived,
    uint256 crvUsdReceived,
    uint256 grossProfit,
    uint256 keeperReward,
    bool earlyExit
);

event PathsCommitted(bytes32 expansionHash, bytes32 contractionHash, uint256 activationTime);
event PathsApplied(bytes32 expansionHash, bytes32 contractionHash);
event PathsCancelled();
event DirectionPaused(uint8 indexed direction, bool paused);
event SurplusClaimed(uint256 yieldShares);
event Executed(
    address indexed target,
    uint256 value,
    bytes4 indexed selector,
    bytes32 dataHash
);
```

## Invariants

1. `deployedCrvUsd` never exceeds configured capacity.
2. Expansion cannot spend more idle crvUSD than V3 owns.
3. Contraction cannot reacquire more than the amount counted as deployed without explicit surplus accounting.
4. Keeper rewards equal the configured percentage of realized gross profit, clamped by `maxKeeperRewardBps` of action notional and rounded down.
5. Keeper rewards and fee claims cannot consume required principal or the configured protocol margin.
6. Caller-supplied minimums can only make execution stricter.
7. Callers cannot choose routes, venues, output recipients, or reward recipients.
8. Active paths always connect the configured endpoints.
9. Successful route execution leaves no material intermediate-token balance.
10. Disabling expansion never disables the governance-approved contraction and offboarding path unless global shutdown explicitly does so.
11. A path update cannot bypass its governance delay.
12. Every external conversion is non-reentrant and uses measured balance deltas.
13. Only the governance owner can execute arbitrary targets or calldata.
14. Keeper-supplied parameters cannot weaken protocol-calculated output or profit floors.
15. Trusted backing value remaining after rewards and fee claims is never below `deployedCrvUsd`.
16. Expansion is not delayed when its complete route satisfies the entry floor.
17. `lastExpansionAt` changes only after a successful expansion of at least `minExpansionAmount`.
18. Contraction during the young deployment state always satisfies `earlyExitMinProfitBps`.
19. A failed or below-minimum expansion cannot extend the normal-exit timer.

## Risks

### Route and venue failure

Any path venue can lose liquidity, pause, change behavior, or become unsafe. Atomic execution prevents partial state changes, while path governance and directional pauses provide recovery.

### Yield-token impairment

A yield token can lose value or become temporarily non-redeemable. V3 deliberately trusts approved backing at par for protocol accounting, so the minimum-profit check does not detect an economic depeg by itself. Governance must pause affected execution and migrate or recover the position; the owner execute escape hatch exists partly for this case.

### Stablecoin basis risk

A USDT-facing AMM combined with an sUSDe yield position crosses USDT, USDe, and sUSDe. Governance explicitly accepts those approved assets as dollar-par PegKeeper backing. The route still must satisfy actual balance-delta and share-conversion checks, but those checks prove nominal profitability under the trust convention rather than external-market dollar value.

### Oracle and preview manipulation

Target-AMM spot quotes and ERC-4626 previews can be manipulated or stale. V3 does not use the target-AMM spot as the dollar valuation source. It relies on actual balance deltas, the configured backing adapter, final nominal-profit assertions, deadlines, and transaction-size caps. Governance is responsible for approving a vault or adapter whose share-to-underlying accounting is acceptable for backing.

### MEV

Keeper swaps through the external target AMM can be surrounded by flash-liquidity trades. Internal minimums, post-trade profitability checks, and bounded size prevent protocol loss under the configured accounting but do not guarantee capture of all transient spread. This residual value leakage is accepted to preserve open keeper participation.

### Keeper under-sizing

A keeper may choose less than the maximum profitable amount and leave a second opportunity available. The split-invariant reward formula prevents extra aggregate compensation, while the keeper bears extra transaction gas and open competition allows another caller to act. Minimum trade sizes and rolling flow limits bound nuisance execution. Under-sizing can reduce immediate peg response but cannot weaken final profitability or backing checks.

### Exit-delay liveness

A strict holding period could deadlock downward peg support during an actual crisis. V3 therefore does not impose an absolute lock: the timer selects a higher early-exit margin instead of disabling contraction. The global timer can be reset only by a successful minimum-sized expansion that pays its own execution economics, and a sufficiently distressed realized exit remains executable during the timer. Emergency governance and owner recovery remain separate last-resort paths.

### Governance route power

An updatable path can direct all future flows into a malicious venue. Typed steps, endpoint validation, delayed activation, exact approvals, and emergency cancellation limit this risk.

### Governance execute power

The owner can intentionally bypass typed routes and move or approve assets through `execute()`. This is an explicit trust assumption, not a permissionless surface. A compromised owner can drain V3, but the designated DAO already controls crvUSD minting and the protocol configuration that determines V3's capacity. Ownership must not be delegated to a weaker hot-key or keeper role.

## Deferred decisions

The following are deliberately unresolved:

- whether any aggregate crvUSD trigger is needed beyond realized final profitability;
- whether any separate target-asset or yield-token depeg guard is desirable despite the approved-backing-at-par convention;
- whether V3 eventually receives lazy mint/burn authority;
- initial `entryMinProfitBps`, `normalExitMinProfitBps`, and `earlyExitMinProfitBps`;
- whether a later version may permit a tightly capped negative entry margin expected to be amortized by carry; the initial design does not;
- initial `minDeploymentTime` and whether `minExpansionAmount` is absolute, capacity-relative, or the greater of both;
- whether a later implementation needs tranche or bounded-bucket maturity accounting instead of the initial global timer;
- initial `keeperProfitShareBps` and `maxKeeperRewardBps`;
- whether keeper rewards need an additional aggregate dollar budget per block or epoch;
- path length bound;
- governance delay duration;
- maximum per-call and rolling flow limits;
- the execution-quality benchmark used in addition to the hard profit floor;
- exact adapter interface and rounding rules for converting supported yield shares into trusted underlying units;
- whether the direct buyback interface should be registered in Curve routing infrastructure;
- whether exact-output route adapters are needed;
- how surplus is separated between yield and execution spread;
- whether V3 supports one yield token permanently or permits delayed endpoint migration;
- the final shutdown and migration transaction sequence.

## Sources

[1] https://github.com/resupplyfi/resupply/blob/3fcd20e8ce6bda0225b1f7424f8e25e76884020d/src/dao/TreasuryStableDiversification.sol — Resupply TreasuryStableDiversification path configuration
    > "function setTargets(Target[] calldata newTargets) external onlyOwner {"
    > "inputToken.forceApprove(target.swapPool, inputAmount);
        ICurveStableSwapPool(target.swapPool).exchange(assetIndex, targetIndex, inputAmount, minOut);
        inputToken.forceApprove(target.swapPool, 0);"
[2] https://github.com/curvefi/curve-stablecoin/blob/cf1d05fb6bf7c608973cc41786b2e1fd81dc3a6a/curve_stablecoin/ControllerFactory.vy — Curve ControllerFactory debt-ceiling allocation
    > "diff: uint256 = min(old_debt_residual - debt_ceiling, STABLECOIN.balanceOf(addr))"
    > "if debt_ceiling > old_debt_residual:
        to_mint: uint256 = debt_ceiling - old_debt_residual
        STABLECOIN.mint(addr, to_mint)"
[7] https://etherscan.io/address/0xbEbc44782C7dB0a1A60Cb6fE97d0b483032FF1C7 — Curve 3pool live fee configuration
    > "Ethereum block: 25844317
Curve 3pool: 0xbEbc44782C7dB0a1A60Cb6fE97d0b483032FF1C7
fee()(uint256)=1500000 [1.5e6]
admin_fee()(uint256)=10000000000 [1e10]"
