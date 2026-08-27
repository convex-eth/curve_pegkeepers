# PegKeeper V3 specification

Status: design draft

This document records the current V3 direction. It is intentionally narrower than a complete implementation specification. Unresolved parameters and integration details are listed at the end rather than guessed.

## Summary

PegKeeper V3 is an asymmetric, protocol-owned peg module:

- **Above peg:** a permissionless keeper deploys crvUSD into a designated external crvUSD/stablecoin AMM. V3 prefers to continue through an approved yield path, but a failure after the peg-critical AMM swap leaves the target stablecoin as accounted backing instead of reverting an otherwise profitable expansion.
- **Below peg:** users can sell crvUSD directly to V3 against available approved backing.
- **Fallback below peg:** a permissionless keeper can use either the buffered target stablecoin or an independently configured yield-unwind path to buy crvUSD if direct buyback flow does not arrive.

The target asset is an intentional fallback backing state, not merely route dust. For a USDT-facing sUSDS deployment:

```text
Preferred expansion: crvUSD -> USDT -> DAI -> USDS -> sUSDS
Fallback expansion:  crvUSD -> USDT (hold as accounted backing)

Buffer contraction:  USDT -> crvUSD
Yield contraction:   sUSDS -> USDS -> crvUSD
```

Intermediate assets inside the downstream conversion remain transient. Only the configured target asset, configured yield token, and idle crvUSD are intended persistent strategy balances.

## Goals

1. Expand crvUSD supply when crvUSD trades above peg.
2. Prefer to turn expansion proceeds into a productive yield-bearing position without making above-peg support depend on downstream route availability.
3. Offer explicit buyback liquidity when crvUSD trades below peg.
4. Reuse bought-back crvUSD during later expansions.
5. Require each completed branch to retain principal and its configured margin after realized route costs and keeper compensation.
6. Pay keepers a governance-set percentage of realized profit, clamped by an absolute per-call maximum.
7. Keep expansion and fallback contraction open to any keeper without a whitelist or private-submission requirement.
8. Expand immediately whenever at least the target-AMM leg is locally non-loss-making after reward and satisfies the configured fallback margin.
9. Prevent routine rapid expansion/contraction churn while allowing early contraction at a sufficiently profitable distressed exit.
10. Allow governance to replace broken or obsolete swap paths without replacing V3.
11. Include first-class directional pauses, shutdown, and migration controls.
12. Give the governance owner an unrestricted external-call escape hatch for urgent recovery and migration.

## Non-goals

V3 is not intended to:

- manage a conventional two-sided StableSwap LP position;
- accept arbitrary token balances as strategy backing;
- accept public LP deposits;
- issue an LP token in the first version;
- expose arbitrary routers, calldata, recipients, or tokens chosen by callers;
- guarantee that a yield token can always be redeemed atomically;
- reuse V2's pool-balance accounting or uncapped caller-profit formula.

## Terminology

- **crvUSD:** the stablecoin whose supply V3 expands and contracts.
- **Target AMM:** the external crvUSD/stablecoin pool used by keeper expansion and fallback contraction.
- **Target asset:** the non-crvUSD coin in the target AMM, such as USDT.
- **Accounted target buffer:** target asset retained by a successful fallback expansion and explicitly included in backing accounting. Unsolicited target-asset transfers are not automatically included.
- **Backing asset:** the approved stablecoin immediately before yield deployment, such as USDS before an sUSDS deposit.
- **Yield token:** the final token held after the expansion path, such as sUSDS.
- **Downstream expansion path:** the updatable sequence from the target asset to the yield token.
- **Yield contraction path:** an independently configured sequence from the yield token to crvUSD, such as sUSDS redemption followed by a USDS/crvUSD swap.
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

Any account can call the expansion and fallback contraction functions. V3 does not rely on a keeper whitelist or private order flow. Keeper rewards are paid to `msg.sender`, take a configured share of realized profit subject to a flat cap, and are paid only after a successful profitable transaction. The keeper chooses the exact amount, but cannot weaken protocol bounds, paths, minimum outputs, or profitability conditions.

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
accountedTargetBuffer
downstreamExpansionPath
yieldContractionPath

entryMinProfitBps
normalExitMinProfitBps
earlyExitMinProfitBps
maxExecutionSlippageBps
keeperProfitShareBps
maxKeeperReward

minDeploymentTime
minExpansionAmount
lastExpansionAt

maxExpansionPerCall
maxBuybackPerCall
maxDeployedCrvUsd
maxTargetBuffer
maxBufferDeployPerCall
maxBufferDeploymentLossBps
requiredBackingReserve
downstreamAttemptGas

expansionPaused
bufferDeploymentPaused
directBuybackPaused
targetContractionPaused
yieldContractionPaused
shutdown
```

The exact storage representation is deferred until the implementation language and path-step bounds are selected.

## Supply accounting and Factory integration

The current ControllerFactory mints the configured debt-ceiling increase to V3 upfront. It does not grant V3 a permissionless lazy-mint function.

The first implementation should therefore treat the Factory allocation as reusable inventory:

```text
Idle crvUSD
    -> expansion
Accounted target buffer or yield-token position
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
- only the configured target buffer and configured yield position count toward V3 principal and surplus accounting;
- unsolicited tokens and arbitrary assets sent to V3 do not count as backing.

For an ERC-4626-style sUSDS position:

```text
trustedBackingValue(sUSDS shares)
    = normalizeTo1e18(convertToAssets(sUSDS shares))
```

The returned USDS units are then trusted at par because USDS and the sUSDS position were approved by governance as PegKeeper backing. No target-AMM spot price is used to value the final position.

This is a protocol accounting convention, not proof that every approved stablecoin can always be sold for one dollar. If an approved backing asset depegs, freezes, or becomes non-redeemable, V3 can remain nominally solvent under its configured accounting while being economically impaired. Governance must pause affected routes and use path migration or owner `execute()` to move the position.

For a USDT-facing sUSDS deployment:

```text
trustedBackingValue
    = normalize(accountedTargetBuffer)
    + normalize(convertToAssets(sUsdsShares))

deployedCrvUsd <= Factory allocation
deployedCrvUsd <= trustedBackingValue
```

Expansion increases `deployedCrvUsd` by the crvUSD sold regardless of whether the action finishes in target asset or yield token. Direct buyback decreases it by crvUSD received from the user; keeper contraction decreases it by crvUSD retained after the keeper reward, always capped at the current deployed amount. Idle crvUSD backs itself; the combined trusted value of the accounted target buffer and yield position must cover the portion currently deployed into the market after rewards, later conversion costs, and fee claims.

## Expansion lifecycle

Expansion is keeper-driven. V3 does not offer a separate direct upward-price quote in the initial design.

Expansion has no time cooldown. The target-AMM sale is the peg-critical leg; downstream yield deployment is preferred but best effort. A zero-basis-point entry margin still requires whichever branch completes to retain at least principal after its realized route costs and keeper reward.

```text
1. Verify expansion is enabled.
2. Do not require the target AMM spot price to remain close to its EMA. A sharp upward move in crvUSD is the opportunity V3 is meant to act on.
3. Verify the keeper's requested amount is at least `minExpansionAmount` and within idle crvUSD, per-call, and max-deployed limits.
4. Sell crvUSD into the designated target AMM.
5. Receive the target asset.
6. Attempt the configured target-to-yield path in an isolated, typed, `onlySelf` call with protocol-calculated minima. That subcall includes full-route balance measurement, keeper payment in the backing asset, terminal yield deployment, and the final yield-backing floor.
7. Treat the downstream branch as successful only if the isolated call completes all of those operations and returns consistent measured deltas.
8. If the downstream call reverts, roll back only that subcall, calculate fallback gross profit from the target asset actually received, pay the keeper in target asset, require the resulting accounted buffer not to exceed `maxTargetBuffer`, and retain the remainder as accounted target backing.
9. Require the selected branch to leave principal plus its configured entry margin after reward. A failure of both branches reverts the complete expansion, including the target-AMM swap.
10. Increase `deployedCrvUsd` and set `lastExpansionAt` to the current timestamp.
11. Emit the branch, complete execution result, gross profit, keeper reward, target amount buffered, and maturity time.
```

The downstream call must not be an arbitrary keeper-controlled call. It uses the active typed path, exact temporary approvals, fixed recipients, and an implementation-level gas reserve or fixed forwarded-gas policy so a keeper cannot deliberately starve the downstream attempt and force the more favorable fallback branch. Any route, reward, deposit, or full-route economic failure reverts the isolated call and selects fallback with the original target asset still held by V3. If the isolated call returns success but its returned deltas are inconsistent with outer balance checks, the outer expansion reverts entirely rather than accepting fallback after state has committed.

A preliminary interface is:

```solidity
function expand(uint256 crvUsdAmount) external returns (
    uint256 crvUsdSold,
    uint256 targetBuffered,
    uint256 yieldSharesReceived,
    uint256 keeperReward,
    bool deployedToYield
);
```

The keeper chooses only the exact crvUSD amount. V3 validates its bounds and calculates gross profit, reward, and every intermediate and final minimum internally. The keeper cannot choose the target AMM, path, output token, fee receiver, reward recipient, fee percentage, reward cap, or minimum output.

The keeper's proposed amount should be previewable:

```solidity
function previewExpansion(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedTargetOut,
        uint256 expectedBackingAssetOut,
        uint256 expectedGrossProfit,
        uint256 expectedKeeperReward,
        uint256 expectedYieldShares,
        bool expectedToDeploy
    );
```

The preview is advisory. A downstream quote can become stale or the route can revert during execution; the state-changing call selects the branch from actual call success and realized balance deltas.

### Fallback profit and keeper payment

For a target-only fallback:

```text
fallbackGrossProfit
    = normalize(targetAssetReceived)
    - crvUsdSold

fallbackKeeperRewardValue = min(
    floor(fallbackGrossProfit * keeperProfitShareBps / 10_000),
    maxKeeperReward
)

targetAssetRetained
    = targetAssetReceived
    - denormalizeDown(fallbackKeeperRewardValue)

fallbackEntryMargin
    = crvUsdSold * entryMinProfitBps / 10_000

normalize(targetAssetRetained)
    >= crvUsdSold + fallbackEntryMargin
```

The target asset is a valid terminal backing state. V3 does not deduct a hypothetical future yield-route fee before paying this reward because future deployment is optional: the target buffer may instead be used directly for contraction. With an illustrative `30%` keeper share, V3 retains principal plus at least `70%` of this branch's realized gross profit before normalization rounding when the flat cap does not bind, and more when it does.

### Later target-buffer deployment

Buffered target asset may be converted later through the same fixed downstream path:

```solidity
function deployBufferedTarget(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 yieldSharesReceived);
```

This is a separate maintenance action, not another crvUSD expansion. It does not increase `deployedCrvUsd`, reset `lastExpansionAt`, or pay a percentage reward on pre-existing protocol assets. It uses only `accountedTargetBuffer`; unsolicited target tokens are excluded unless governance explicitly reconciles them.

Later route fees are paid only from existing protocol surplus:

```text
trustedBackingBefore
    = normalize(accountedTargetBufferBefore)
    + trustedYieldValueBefore

availableDeploymentSurplus
    = max(
        trustedBackingBefore
        - deployedCrvUsd
        - requiredBackingReserve,
        0
      )

conversionCost = max(
    normalize(targetSpent) - trustedValue(yieldSharesReceived),
    0
)

conversionCost <= availableDeploymentSurplus
conversionCost <= normalize(targetSpent)
    * maxBufferDeploymentLossBps / 10_000

trustedBackingAfter
    >= deployedCrvUsd + requiredBackingReserve
```

If the route is unavailable or those checks fail, the maintenance call reverts and the target buffer remains intact. This means later deployment can reduce the protocol's retained execution spread, but cannot consume the principal backing deployed crvUSD.

V3 should not blindly combine the entire old buffer with a newly rewarded expansion. That would contaminate current-call profit attribution and may make a healthy small conversion fail from excessive combined size. After a new expansion has settled its own reward and demonstrated that the downstream route works, V3 may make a separate best-effort subcall for:

```text
min(accountedTargetBuffer, maxBufferDeployPerCall)
```

The flush has independent balance snapshots and failure cannot revert the completed expansion. An explicit `deployBufferedTarget()` remains necessary when the route recovers without another expansion.

## Direct buyback lifecycle

Direct buyback provides one-sided downward liquidity against an explicitly selected protocol backing source. The caller may select only a fixed entry point and amount, never a route, venue, recipient, or accounting value.

```text
1. Verify direct buyback is enabled.
2. Transfer crvUSD from the caller to V3.
3. Bound the transaction by deployed crvUSD and the per-call buyback limit.
4. Determine whether V3 is in the mature or young deployment state.
5. Select the normal exit margin in the mature state or the higher early exit margin in the young state.
6. Determine whether the called entry point spends accounted target buffer or redeems yield backing.
7. Determine the maximum backing amount that may be spent while preserving the selected margin.
8. Measure the exact approved backing transferred to the caller.
9. Verify the crvUSD received exceeds the trusted backing value spent by the selected margin.
10. Decrease `accountedTargetBuffer` when the target-buffer entry point is used.
11. Reduce deployedCrvUsd by the crvUSD reacquired.
12. Retain the crvUSD as idle inventory.
13. Emit the shares spent, target asset paid, crvUSD reacquired, and whether early exit was used.
```

A preliminary interface is:

```solidity
function buybackFromTargetBuffer(
    uint256 crvUsdAmount,
    uint256 minTargetOut
) external returns (uint256 targetOut, uint256 targetSpent);

function buybackFromYield(
    uint256 crvUsdAmount,
    uint256 minUnderlyingOut
) external returns (uint256 underlyingOut, uint256 yieldSharesSpent);
```

The target-buffer entry point pays the configured target asset directly and does not depend on the downstream yield route. The yield-backed entry point redeems the configured yield token and pays its configured approved underlying, such as USDS from sUSDS; it does not need to reconstruct USDT. Each call reverts if its selected backing source cannot produce an acceptable output.

The direct quote should be previewable:

```solidity
function previewBuybackFromTargetBuffer(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedTargetOut,
        uint256 maxTargetSpent,
        uint256 requiredExitProfit,
        bool earlyExit
    );
```

The preview is advisory. Execution uses balance deltas and post-transaction profitability checks.

Caller minimums are retained here because the direct buyback caller supplies crvUSD and receives the backing output. The effective minimum is the greater of the user's minimum and V3's internally calculated protocol minimum. Passing zero cannot weaken V3's floor.

## Keeper buyback fallback

If no direct buyback flow arrives, a keeper can contract supply from either backing source.

For buffered target asset:

```text
1. Spend an exact bounded amount of accounted target buffer.
2. Swap target asset for crvUSD through the target AMM.
3. Calculate gross exit profit as crvUSD received minus normalized target asset spent.
4. Pay the percentage-plus-flat-cap keeper reward in crvUSD.
5. Enforce the selected post-reward exit margin.
6. Decrease `accountedTargetBuffer` by the target asset actually spent.
7. Reduce `deployedCrvUsd` by net crvUSD retained, capped at the deployed amount.
```

For yield backing:

```text
1. Verify keeper buyback is enabled.
2. Determine whether V3 is in the mature or young deployment state.
3. Select the normal or early exit margin accordingly.
4. Verify the keeper's requested yield-share amount is within per-call, backing, and deployed-crvUSD bounds.
5. Execute the independent yield contraction path from yield token to crvUSD. For sUSDS this may redeem to USDS and then use a configured USDS/crvUSD venue without passing through USDT.
6. Calculate gross exit profit as crvUSD received minus the trusted backing value of yield-token shares spent.
7. Calculate the keeper reward as the configured percentage of gross exit profit, clamped by `maxKeeperReward`, and pay it to `msg.sender` in crvUSD.
8. Verify the net crvUSD retained after the reward exceeds the trusted backing value spent by the selected exit margin.
9. Reduce deployedCrvUsd by the net crvUSD retained, capped at the deployed amount.
10. Keep the remaining recovered crvUSD idle.
```

A preliminary interface is:

```solidity
function contractBufferedTarget(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 crvUsdReceived, uint256 keeperReward);

function contractViaAmm(uint256 yieldShares)
    external
    returns (uint256 yieldSharesSpent, uint256 crvUsdReceived, uint256 keeperReward);
```

The keeper chooses only the exact target amount or yield-token shares. V3 calculates every route minimum, realized profit, and reward internally. The two contraction paths have separate venues, limits, and pause controls; failure of the downstream expansion route does not disable either target-buffer contraction or a healthy yield-to-crvUSD route.

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

function previewBufferedContraction(uint256 targetAmount)
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
    ExactStableConverter,
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

Downstream expansion and yield contraction paths are configured separately. V3 must not assume that the reverse path has the same venue, cost, liquidity, endpoint, or safety parameters. Target-buffer contraction uses the reverse direction of the designated target AMM and does not depend on either downstream path.

Example expansion path:

```text
USDT --CurveSwap(3pool)--> DAI
DAI --typed exact converter--> USDS
USDS --ERC4626Deposit(sUSDS)--> sUSDS
```

Example contraction path:

```text
sUSDS --ERC4626Redeem(sUSDS)--> USDS
USDS --CurveSwap(USDS/crvUSD)--> crvUSD
```

### Path validation

A path is valid only when:

1. The downstream expansion path starts with `targetAsset` and ends with `yieldToken`.
2. The yield contraction path starts with `yieldToken` and ends with `crvUSD`.
3. Every step's `tokenOut` equals the next step's `tokenIn`.
4. The expansion path has a distinguished terminal deployment step whose input is `backingAsset` and output is `yieldToken`.
5. The yield contraction path has a distinguished first unwind step whose input is `yieldToken` and output is `backingAsset`.
6. A Curve step's pool contains both configured tokens.
7. An exact stable converter is a governance-approved typed adapter with fixed input and output tokens; it accepts no caller calldata or recipient.
8. An ERC-4626 deposit step uses `vault.asset() == tokenIn` and the vault share token as `tokenOut`.
9. An ERC-4626 redeem step uses the vault share token as `tokenIn` and `vault.asset()` as `tokenOut`.
10. Execution-buffer parameters remain within governance-set maxima.
11. The path length is bounded.
12. No venue, token, or endpoint is zero.

Changing the target AMM, target asset, backing asset, or yield token requires applying a complete compatible configuration bundle. Governance cannot leave active paths, buffer accounting, or contraction endpoints mismatched.

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

Successful downstream deployment and contraction calls must consume the entire routed input except for bounded rounding dust. A failed isolated downstream expansion attempt consumes none of the target input and leaves it available for the accounted fallback branch.

## Keeper-supplied sizing

V3 does not calculate or verify the perfect maximum expansion. A keeper chooses an exact amount, while V3 retains every safety decision.

For expansion:

```text
minExpansionAmount <= crvUsdAmount

crvUsdAmount <= min(
    idleCrvUsd,
    maxExpansionPerCall,
    maxDeployedCrvUsd - deployedCrvUsd
)
```

Fallback contraction applies ordinary minimum and maximum limits to either requested target amount or requested yield shares and their trusted backing value. The contract executes every requested amount exactly or reverts; it does not silently resize the transaction. A fallback expansion can complete only if its retained target asset also fits within remaining `maxTargetBuffer` capacity.

The keeper can use `previewExpansion(amount)` or `previewKeeperBuyback(shares)` offchain to select an economically useful amount. Onchain, V3 still calculates every intermediate minimum, profit-share reward, flat reward cap, and final post-reward margin. A keeper-supplied amount can cause its own transaction to revert but cannot make an unsafe amount execute.

Under-sizing may leave a second profitable action available, and a flat per-call cap can be collected again if another complete profitable call succeeds. This is accepted: each reward is a percentage of independently realized post-route gross profit, each call leaves V3 with its configured post-reward margin, and the keeper pays additional gas. `minExpansionAmount` blocks true dust without adding quote probes or a full-path search.

`minExpansionAmount` remains important because a successful expansion resets the global contraction timer. It should be economically material and may be capacity-relative. Trade and rolling-flow caps remain protocol controls rather than keeper inputs.

## Profitability and execution controls

Realized profitability under the trusted-backing convention is the primary execution gate. V3 should not copy V2-style spot/EMA proximity checks onto the target crvUSD AMM: a sudden crvUSD price spike creates the exact expansion opportunity V3 should capture. Requiring spot to remain close to EMA would suppress the intended trade.

Expansion therefore has two authoritative realized postconditions. A fully deployed branch uses the approved underlying units represented by final yield shares after the complete downstream route and keeper reward. A fallback branch uses only the accounted target asset actually retained after its keeper reward. A downstream preview is never counted as backing. Each approved stablecoin unit is treated as one dollar without consulting the target AMM spot.

Contraction applies the inverse test to either source: crvUSD retained after paying the keeper must exceed the normalized target buffer or trusted yield value consumed by the configured margin.

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

V3 must nevertheless enforce its hard profitability condition using only assets actually received by V3. Unclaimed 3pool admin fees are not held by the PegKeeper, are not atomically available as backing, and cannot be counted toward combined `trustedBackingValue`. Otherwise V3 could pass a consolidated-profit test while leaving its own backing position short.

The fully deployed and fallback views are therefore:

```text
Gross entry profit used for keeper compensation
    = normalized backing asset received before yield deployment
    - crvUSD deployed

Fallback gross profit used for keeper compensation
    = normalized target asset received from the target AMM
    - crvUSD deployed

Fully deployed PegKeeper-local net profit
    = trusted backing value of final yield shares
    - crvUSD deployed

Fallback PegKeeper-local net profit
    = normalized accounted target asset retained after reward
    - crvUSD deployed

DAO-consolidated profit
    = selected branch PegKeeper-local net profit
    + attributable DAO admin-fee accrual
```

The local branch result is the onchain safety invariant. DAO-consolidated profit is an offchain route-selection and governance metric. Routes that return equivalent backing to V3 should prefer fees accruing to the DAO over fees retained by external LPs, but fee recapture must never weaken V3's `minOut` or final backing floor. Pool fee ownership is configuration-dependent and must be rechecked before governance installs or updates a route.

Optional depeg or venue-health checks may still protect the non-crvUSD conversion path, but they must be independent from the target AMM's crvUSD spot/EMA divergence and must not override a transaction that already proves sufficient realized final value. Caller minimums can only make execution stricter; they cannot weaken protocol minimums.

For a successful full-route expansion, V3 calculates the keeper reward from the realized backing-asset output immediately before yield deployment:

```text
require normalize(backingAssetOut) >= crvUsdSold
grossEntryProfit = normalize(backingAssetOut) - crvUsdSold

keeperRewardValue = min(
    floor(grossEntryProfit * keeperProfitShareBps / 10_000),
    maxKeeperReward
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

The fallback branch separately enforces a target-output execution floor against the target AMM quote, then applies its realized post-reward target-backing floor. The full-route share floor is not reused for fallback.

### Expansion postconditions

```text
fully deployed:
trustedBackingValue(yieldSharesReceived)
>= crvUsdSold
 + entryMargin

fallback:
normalize(targetAssetRetainedAfterReward)
>= crvUsdSold
 + fallbackEntryMargin
```

### Direct buyback postcondition

```text
crvUsdReceived
>= trustedBackingValue(backingSpent)
 + selectedExitMargin
```

### Keeper buyback postcondition

```text
grossExitProfit
    = crvUsdReceived
    - trustedBackingValue(selectedBackingSpent)

keeperReward = min(
    floor(grossExitProfit * keeperProfitShareBps / 10_000),
    maxKeeperReward
)

crvUsdReceived - keeperReward
>= trustedBackingValue(selectedBackingSpent)
 + selectedExitMargin
```

The implementation still needs an asset-specific adapter interface and exact rounding direction. Expansion must round required shares up, reward-token conversion down, and surplus calculations down.

## Asymmetric timing and carry

Entry and exit should not have symmetric urgency.

### Entry policy

Expansion should remain immediately callable with no time delay:

```text
entryMargin = crvUsdSold * entryMinProfitBps / 10_000

selectedBranchBackingRetainedAfterReward
>= crvUsdSold + entryMargin
```

`entryMinProfitBps` may be set to zero. That does not socialize route loss: the deployed branch must cover the complete downstream route and keeper reward, while the fallback branch must retain target asset covering principal after its keeper reward. Later target-to-yield conversion is optional and may spend only existing surplus. Adding a positive entry margin requires the selected branch to retain that additional amount immediately.

Expansion should not wait for a timer, EMA, accumulated yield, or downstream route recovery. If the target-AMM leg can complete into acceptable target backing, delaying it gives away the above-peg opportunity.

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

One full day earns approximately `1.10` to `1.37` basis points at those rates. A one-day minimum deployment time is therefore a reasonable initial reference for exposure that reached the yield token. Accounted target buffer does not earn this carry; its holding period is justified only by supply anti-churn and may need a separate policy after live simulation.

The timer must not be used as a solvency assumption. Yield can change, stop, or become impaired. Every contraction still has to pass its realized final-value condition. Carry only improves the economics of holding exposure through short-lived volatility.

### Material-expansion timer

A single global `lastExpansionAt` is acceptable for the initial design if only a material successful expansion can reset it. The keeper chooses the amount, but `expand()` can complete only when the sale meets `minExpansionAmount` and receives acceptable final backing after route costs and the keeper reward.

The normal-exit timer is:

```text
earlyExit =
    deployedCrvUsd > 0
    && block.timestamp < lastExpansionAt + minDeploymentTime
```

A caller can still flash-borrow liquidity, buy crvUSD to create an expansion opportunity, request the minimum accepted expansion, and sell back afterward. That can reset the timer, but it is not free. The actor pays the market round trip, AMM fees and slippage, and enough manipulated premium for at least `minExpansionAmount` of V3's selected expansion branch and keeper compensation to pass. Making the threshold capacity-relative prevents the reset cost from becoming economically negligible as the position grows.

The minimum makes timer manipulation economically self-penalizing rather than free. V3 sells the requested material amount into the price increase the actor created, so the attacker buys high, is countertraded by V3, then sells back lower while also paying pool fees. V3 captures the entry economics. This does not make manipulation cryptographically impossible: an actor with a sufficiently valuable external position may rationally pay that loss to delay normal-margin contraction. It cannot deadlock contraction because the timer never disables the exit functions; it only selects the higher early-exit margin. Genuinely distressed crvUSD can still be contracted during the timer while paying V3 that larger spread.

The global timer also means a sequence of legitimate profitable expansions extends the normal-exit delay for the whole position. That is consistent with the initial anti-churn objective and is considerably simpler than tranche accounting. Later target-buffer deployment does not reset this supply timer, so it does not guarantee that newly created yield shares accrue a full carry interval. If live behavior requires separate maturity for buffer and yield exposure, governance can migrate a later implementation to bounded maturity buckets.

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

V2's percentage caller payment is also taken from positive incremental LP-accounting profit. Its lack of a flat per-call ceiling may overpay relative to gas during an unusually favorable update, but it is not a principal-safety failure or a primary reason for V3. V3's flat cap is a modest refinement to the new realized-profit model.

## Keeper compensation

Keeper compensation is a percentage of realized gross profit, clamped by an absolute per-call maximum:

```text
keeperReward = min(
    floor(grossProfit * keeperProfitShareBps / 10_000),
    maxKeeperReward
)
```

For fully deployed expansion, `grossProfit` is normalized backing asset received immediately before terminal yield deployment minus crvUSD sold, and the keeper is paid in that backing asset. For fallback expansion, it is normalized target asset received minus crvUSD sold, and the keeper is paid in target asset before the remainder enters `accountedTargetBuffer`. `maxKeeperReward` is stored in normalized 18-decimal backing-value units and token conversion rounds down. For either keeper contraction source, `grossProfit` is crvUSD received minus trusted backing value spent, and the keeper is paid in crvUSD. Direct buyback and buffer-deployment callers receive no separate percentage reward.

The high profit-share rate supports smaller economically useful calls, while `maxKeeperReward` prevents a large dislocation from paying an excessive single reward. The cap is intentionally per call rather than split-invariant. A keeper may collect the cap more than once by executing multiple transactions, including a same-block batch, but each successful call must independently realize profit through its selected branch and leave V3 with principal plus its configured post-reward margin. Since expected entry spreads are only a few basis points and most strategy return is intended to come from holding the yield position, this is treated as bounded rent leakage rather than a solvency issue.

The reward rules are:

1. `keeperProfitShareBps` cannot exceed `10_000` and should be materially lower so the protocol normally retains immediate execution profit.
2. The reward is calculated from realized balance deltas, never a preview or caller-supplied value.
3. The reward is paid only after the route has produced positive gross profit and the complete state transition can satisfy the post-reward protocol margin.
4. The reward is paid to `msg.sender`; callers cannot supply an arbitrary beneficiary.
5. Decimal conversion rounds the reward down.
6. `maxKeeperReward` limits each individual reward but is not treated as an aggregate batch cap.
7. The reward cannot consume principal or the configured protocol margin.

No fixed stipend or time-refilling credit system is paid. A keeper decides whether its percentage reward is worth its gas and execution risk. The protocol favors simple repeated profitable execution over a reward budget that may be depleted during a clustered peg event.

## Fee receiver and surplus

Yield-token appreciation and execution spread retained in either approved backing source create protocol surplus. Fee withdrawal must not reduce combined trusted backing below outstanding deployed crvUSD and any configured reserve.

A withdrawal function should calculate the maximum withdrawable amount from combined trusted backing, rounding principal requirements against the fee receiver, and transfer no more than that amount.

```solidity
function claimYieldSurplus(uint256 maxShares)
    external
    returns (uint256 sharesTransferred);

function claimTargetSurplus(uint256 maxTargetAmount)
    external
    returns (uint256 targetTransferred);
```

These functions are permissionless to call but always pay the configured fee receiver.

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
- pause target-buffer deployment without pausing target-only expansion;
- pause direct buyback;
- pause keeper buyback;
- global shutdown;
- lower trade and deployment caps immediately;
- lower the target-buffer cap and later-deployment loss limit immediately;
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
    uint256 targetBuffered,
    bool deployedToYield,
    uint256 unlockTime
);

event TargetBufferDeployed(
    address indexed caller,
    uint256 targetSpent,
    uint256 yieldSharesReceived,
    uint256 conversionCost
);

event DirectBuyback(
    address indexed caller,
    uint256 crvUsdReceived,
    address backingToken,
    uint256 backingPaid,
    uint256 yieldSharesSpent,
    bool earlyExit
);

event KeeperBuyback(
    address indexed keeper,
    address backingToken,
    uint256 backingSpent,
    uint256 yieldSharesSpent,
    uint256 crvUsdReceived,
    uint256 grossProfit,
    uint256 keeperReward,
    bool earlyExit
);

event PathsCommitted(bytes32 expansionHash, bytes32 contractionHash, uint256 activationTime);
event PathsApplied(bytes32 expansionHash, bytes32 contractionHash);
event PathsCancelled();
event DirectionPaused(uint8 indexed direction, bool paused);
event SurplusClaimed(address indexed token, uint256 amount, uint256 trustedValue);
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
4. `accountedTargetBuffer` changes only through measured fallback retention, measured buffer spending, successful typed deployment, governance reconciliation, or surplus withdrawal.
5. Unsolicited token transfers never increase accounted backing automatically.
6. Keeper rewards equal the configured percentage of realized gross profit for the selected branch, clamped by `maxKeeperReward` per call and rounded down.
7. Keeper rewards and fee claims cannot consume required principal or the configured protocol margin.
8. Caller-supplied minimums can only make execution stricter.
9. Callers cannot choose routes, venues, output recipients, or reward recipients.
10. Active paths always connect the configured endpoints.
11. Successful downstream execution leaves no material unaccounted intermediate-token balance.
12. A failed isolated downstream attempt leaves the target input in V3 and cannot partially consume it.
13. Buffer deployment cannot consume more than available surplus or exceed its per-call loss bound.
14. Buffer deployment never changes `deployedCrvUsd` or `lastExpansionAt`.
15. Disabling expansion never disables the governance-approved contraction and offboarding paths unless global shutdown explicitly does so.
16. A path update cannot bypass its governance delay.
17. Every external conversion is non-reentrant and uses measured balance deltas.
18. Only the governance owner can execute arbitrary targets or calldata.
19. Keeper-supplied parameters cannot weaken protocol-calculated output or profit floors.
20. Combined trusted backing remaining after rewards, later deployment costs, and fee claims is never below `deployedCrvUsd` plus any required reserve.
21. Expansion is not delayed when either approved branch satisfies its entry floor.
22. `lastExpansionAt` changes only after a successful expansion of at least `minExpansionAmount`.
23. Contraction during the young deployment state always satisfies `earlyExitMinProfitBps`.
24. A failed or below-minimum expansion cannot extend the normal-exit timer.

## Risks

### Route and venue failure

Any path venue can lose liquidity, pause, change behavior, or become unsafe. The peg-critical target swap remains atomic with its selected fallback result. A failed isolated downstream attempt rolls back its own approvals and conversions while leaving the target asset in V3; path governance and directional pauses provide recovery.

### Fallback forcing and gas starvation

The fallback branch may produce a larger immediate keeper reward than the full route because it has not paid downstream conversion fees. A keeper must not be able to select that branch directly or force it by underfunding gas. The implementation needs a fixed downstream gas policy or a conservative pre-attempt gas requirement plus sufficient reserved gas to finalize target-buffer accounting. Route failure is caught only inside that controlled call boundary.

### Target-buffer accumulation

The buffer preserves peg liveness but creates persistent exposure to the AMM-facing stablecoin and may remain idle without earning yield. `maxTargetBuffer`, independent pauses, permissionless bounded deployment, direct buffer contraction, and governance migration limit that exposure. Once the buffer reaches its cap, further fallback expansion must stop unless some buffer is deployed, contracted, or migrated; the cap must therefore be large enough to serve the intended liveness purpose.

### Yield-token impairment

A yield token can lose value or become temporarily non-redeemable. V3 deliberately trusts approved backing at par for protocol accounting, so the minimum-profit check does not detect an economic depeg by itself. Governance must pause affected execution and migrate or recover the position; the owner execute escape hatch exists partly for this case.

### Stablecoin basis risk

A USDT-facing AMM combined with an sUSDS yield position crosses USDT, DAI, USDS, and sUSDS. Governance explicitly accepts the persistent USDT buffer and sUSDS underlying as dollar-par PegKeeper backing. Transient route assets do not count after a successful call. The checks prove nominal profitability under the trust convention rather than external-market dollar value.

### Oracle and preview manipulation

Target-AMM spot quotes and ERC-4626 previews can be manipulated or stale. V3 does not use the target-AMM spot as the dollar valuation source. It relies on actual balance deltas, the configured backing adapter, final nominal-profit assertions, deadlines, and transaction-size caps. Governance is responsible for approving a vault or adapter whose share-to-underlying accounting is acceptable for backing.

### MEV

Keeper swaps through the external target AMM can be surrounded by flash-liquidity trades. Internal minimums, post-trade profitability checks, and bounded size prevent protocol loss under the configured accounting but do not guarantee capture of all transient spread. This residual value leakage is accepted to preserve open keeper participation.

### Keeper under-sizing

A keeper may choose less than the maximum profitable amount and leave a second opportunity available. It may then earn another capped reward from a later independently profitable call. This can leak more execution spread than a single optimally sized call, but the keeper bears extra gas and every completed action must leave V3 with its configured post-reward margin. `minExpansionAmount`, size caps, and open competition are considered sufficient for the initial design. Under-sizing can reduce immediate peg response but cannot weaken final profitability or backing checks.

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
- whether target-buffer contraction should share the global expansion timer or use a less restrictive policy because the buffer earns no yield;
- initial `keeperProfitShareBps` and flat `maxKeeperReward`;
- initial `maxTargetBuffer`, `maxBufferDeployPerCall`, `maxBufferDeploymentLossBps`, and required backing reserve;
- exact downstream isolated-call gas policy and minimum gas reserve;
- whether a successful expansion should always attempt a separate capped buffer flush or leave flushing to `deployBufferedTarget()`;
- final direct-buyback surface for selecting target-buffer versus yield-underlying payout;
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
