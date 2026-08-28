# PegKeeper V3 specification

Status: design draft

This document records the current V3 direction. It is intentionally narrower than a complete implementation specification. Unresolved parameters and integration details are listed at the end rather than guessed.

## Summary

PegKeeper V3 is an asymmetric, protocol-owned peg module:

- **Above peg:** a permissionless keeper deploys crvUSD into a designated external crvUSD/stablecoin AMM. V3 prefers to continue through an approved yield path, but a failure after the peg-critical AMM swap leaves the target stablecoin as accounted backing instead of reverting an otherwise profitable expansion.
- **Below peg:** users can sell crvUSD directly to V3 against available approved backing.
- **Fallback below peg:** a permissionless keeper can use either the undeployed backing or an independently configured yield-unwind path to buy crvUSD if direct buyback flow does not arrive.

The target asset is an intentional fallback backing state, not merely route dust. For a USDT-facing sUSDS deployment:

```text
Preferred expansion: crvUSD -> USDT -> DAI -> USDS -> sUSDS
Fallback expansion:  crvUSD -> USDT (hold as accounted backing)

Undeployed-backing contraction:  USDT -> crvUSD
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
11. Allow expansion to be paused while contraction remains available for a slow wind-down.
12. Give the governance owner an unrestricted external-call escape hatch for urgent recovery or migration.

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
- **Undeployed backing:** target asset retained by a successful fallback expansion and explicitly included in backing accounting. Unsolicited target-asset transfers are not automatically included.
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

Governance selects the deployment's fixed token endpoints and configures debt capacity, the target AMM, paths, execution constraints, profitability thresholds, keeper fees, and the fee receiver. Approved route changes apply atomically when the governance proposal executes but cannot change those endpoints. The governance owner can also make an arbitrary external call through `execute()` when a typed path or slow wind-down is insufficient.

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
undeployedBacking
downstreamExpansionPath
yieldContractionPath

entryMinProfitPpm
normalExitMinProfitPpm
earlyExitMinProfitPpm
maxExecutionSlippageBps
keeperProfitShareBps
maxKeeperReward

minDeploymentTime
minExpansionAmount
lastExpansionAt

maxDeployedCrvUsd
minDownstreamAttemptGas

expansionPaused
backingDeploymentPaused
directBuybackPaused
undeployedContractionPaused
yieldContractionPaused
```

The exact storage representation is deferred until the implementation language and route encoding are selected.

`targetAsset`, `backingAsset`, `yieldToken`, and the yield-token accounting adapter are fixed for the lifetime of a V3 deployment. Governance may replace venues and typed paths only when they preserve those endpoints. Supporting another yield token requires a new V3 deployment rather than mutating the backing identity and accounting assumptions of the existing contract.

## Supply accounting and Factory integration

The current ControllerFactory mints the configured debt-ceiling increase to V3 upfront. It does not grant V3 a permissionless lazy-mint function.

The first implementation should therefore treat the Factory allocation as reusable inventory:

```text
Idle crvUSD
    -> expansion
Undeployed backing or yield-token position
    -> contraction
Idle crvUSD
```

`expand()` deploys idle Factory-allocated crvUSD. It does not mint directly under the current Factory interface. The initial V3 design intentionally keeps this allocation model and does not add lazy mint or burn authority.

Unused allocated crvUSD and crvUSD received during contraction remain idle in V3 rather than circulating in markets. They can be reused in a later expansion. Under the current ControllerFactory allocation pattern, governance controls the approved amount and the Factory mints that amount to the strategy.[2] In V3 supply accounting, only the portion actually sold or deposited becomes active market supply. Governance can lower the Factory ceiling when it wants idle crvUSD burned.

A burn-only timer would not prevent market churn. Reacquiring crvUSD already removes it from active circulation; waiting to destroy the idle tokens changes Factory accounting but does not postpone the economic contraction. The timer must therefore gate use of the yield position for buyback, not merely the later burn transaction. Once crvUSD has been reacquired, governance may burn it immediately by lowering the Factory ceiling.

### Trusted backing convention

The current ControllerFactory does not inspect or mark to market assets held by a debt-ceiling recipient. It mints the allocation to the approved PegKeeper address and, when lowering the ceiling, burns only crvUSD currently held by that address.[2] Solvency therefore already depends on governance admitting a PegKeeper whose deployed assets are acceptable backing.

V3 makes that trust assumption explicit and narrow:

- governance approves the AMM-facing stablecoin, yield token, vault underlying, and typed conversion paths;
- one normalized unit of an approved backing stablecoin is accounted as one dollar and one crvUSD unit;
- yield-token shares are not treated as one dollar each; they are converted into units of the approved underlying through the configured vault or adapter;
- only `undeployedBacking` and the configured yield position count toward V3 principal and surplus accounting;
- unsolicited tokens and arbitrary assets sent to V3 do not count as backing.

For an ERC-4626-style sUSDS position:

```text
trustedBackingValue(sUSDS shares)
    = normalizeTo1e18(convertToAssets(sUSDS shares))
```

The returned USDS units are then trusted at par because USDS and the sUSDS position were approved by governance as PegKeeper backing. No target-AMM spot price is used to value the final position.

This is a protocol accounting convention, not proof that every approved stablecoin can always be sold for one dollar. If an approved backing asset depegs, freezes, or becomes non-redeemable, V3 can remain nominally solvent under its configured accounting while being economically impaired. Governance must pause affected routes and use slow wind-down or owner `execute()` to recover or move the position. Continuing with a different yield token requires deploying a new V3.

For a USDT-facing sUSDS deployment:

```text
trustedBackingValue
    = normalize(undeployedBacking)
    + normalize(convertToAssets(sUsdsShares))

deployedCrvUsd <= Factory allocation
deployedCrvUsd <= trustedBackingValue
```

Expansion increases `deployedCrvUsd` by the crvUSD sold regardless of whether the action finishes in target asset or yield token. Direct buyback decreases it by crvUSD received from the user; keeper contraction decreases it by crvUSD retained after the keeper reward, always capped at the current deployed amount. Idle crvUSD backs itself; the combined trusted value of the undeployed backing and yield position must cover the portion currently deployed into the market after rewards, later conversion costs, and fee claims.

## Expansion lifecycle

Expansion is keeper-driven. V3 does not offer a separate direct upward-price quote in the initial design.

Expansion has no time cooldown. The target-AMM sale is the peg-critical leg; downstream yield deployment is preferred but best effort. The initial `0.5 bps` entry margin requires whichever branch completes to retain principal plus that margin after its realized route costs, terminal rounding, and keeper reward.

```text
1. Verify expansion is enabled.
2. Do not require the target AMM spot price to remain close to its EMA. A sharp upward move in crvUSD is the opportunity V3 is meant to act on.
3. Verify the keeper's requested amount is at least `minExpansionAmount`, no greater than idle crvUSD, and within the remaining `maxDeployedCrvUsd` capacity.
4. Sell crvUSD into the designated target AMM.
5. Receive the target asset.
6. Attempt the configured target-to-yield path in an isolated, typed, `onlySelf` call with protocol-calculated minima. That subcall includes full-route balance measurement, keeper payment in the backing asset, terminal yield deployment, and the final yield-backing floor.
7. Treat the downstream branch as successful only if the isolated call completes all of those operations and returns consistent measured deltas.
8. If the downstream call reverts, roll back only that subcall, calculate fallback gross profit from the target asset actually received, pay the keeper in target asset, and retain the remainder as `undeployedBacking`.
9. Require the selected branch to leave principal plus its configured entry margin after reward. A failure of both branches reverts the complete expansion, including the target-AMM swap.
10. Increase `deployedCrvUsd` and set `lastExpansionAt` to the current timestamp.
11. Emit the branch, complete execution result, gross profit, keeper reward, undeployed backing retained, and maturity time.
```

The downstream call must not be an arbitrary keeper-controlled call. It uses the active typed path, exact temporary approvals, fixed recipients, and an implementation-level gas reserve or fixed forwarded-gas policy so a keeper cannot deliberately starve the downstream attempt and force the more favorable fallback branch. Any route, reward, deposit, or full-route economic failure reverts the isolated call and selects fallback with the original target asset still held by V3. If the isolated call returns success but its returned deltas are inconsistent with outer balance checks, the outer expansion reverts entirely rather than accepting fallback after state has committed.

This gas policy is not a reward for deploying `undeployedBacking`. It is a transaction-safety rule for the downstream attempt inside `expand()`. Immediately before the isolated subcall, V3 requires `gasleft() >= minDownstreamAttemptGas`, where `minDownstreamAttemptGas` is governance-changeable. Its initial value is selected only after implementation benchmarks and should include ample headroom over the measured worst-case full route, call overhead, failed-attempt handling, fallback accounting, token payment, storage writes, and event emission. Expansion cannot be enabled with an uninitialized zero threshold, and a materially different downstream path must be activated with a compatible threshold.

A minimum `gasleft()` check alone is insufficient if the downstream subcall can consume everything after the check. V3 must also bound forwarded gas or preserve a non-forwarded `fallbackSettlementGasReserve` so it can catch failure, calculate the fallback reward, record `undeployedBacking`, and finish the outer call. The expected threshold may be on the order of several hundred thousand gas, but the specification does not assign a number before measurement. Governance should update the threshold when activating a materially different downstream path. Neither the minimum nor the reserve is paid to the caller.

### No aggregate crvUSD trigger

The initial design does not require a separate aggregate crvUSD oracle trigger. Expansion acceptance is determined by exact amount bounds, protocol-calculated route minima, realized post-reward profitability for the selected terminal branch, final trusted-backing checks, and configured exposure limits.

An aggregate trigger could reject a locally profitable sale because a broader oracle is stale, slow, or reports crvUSD near one dollar. That recreates an oracle-coupled liveness condition without uniquely improving the nominal backing invariant. A keeper can manufacture a local target-AMM opportunity even when broader crvUSD markets are balanced, but the manipulation must still leave V3 with the configured realized margin after reward and pay the attacker's round-trip costs. The remaining concern is bounded rent leakage or unwanted supply cycling, not an unaccounted principal loss.

This decision should be revisited only if simulation or live operation identifies a concrete cross-market externality that realized final profitability and the total deployed-exposure bound do not contain. Aggregate crvUSD observations may still be useful for monitoring and governance alerts without gating the core transaction.

A preliminary interface is:

```solidity
function expand(uint256 crvUsdAmount) external returns (
    uint256 crvUsdSold,
    uint256 backingRetained,
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
    = crvUsdSold * entryMinProfitPpm / 1_000_000

normalize(targetAssetRetained)
    >= crvUsdSold + fallbackEntryMargin
```

The target asset is a valid terminal backing state. V3 does not deduct a hypothetical future yield-route fee before paying this reward because future deployment is optional: `undeployedBacking` may instead be used directly for contraction. With the initial `30%` keeper share, V3 retains principal plus at least `70%` of this branch's realized gross profit before normalization rounding when the flat cap does not bind, and more when it does.

### Later undeployed backing deployment

Undeployed backing may be converted later through the same fixed downstream path:

```solidity
function deployUndeployedBacking(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 yieldSharesReceived);
```

This is a separate maintenance action, not another crvUSD expansion. It does not increase `deployedCrvUsd`, reset `lastExpansionAt`, or pay a percentage reward on pre-existing protocol assets. It uses only `undeployedBacking`; unsolicited target tokens are excluded unless governance explicitly reconciles them. The caller chooses an exact `targetAmount` no greater than `undeployedBacking`. There is no separate maintenance action-size maximum: an amount whose quote, route-loss, surplus, or final-backing checks fail simply reverts.

Later route fees are paid only from existing protocol surplus:

```text
trustedBackingBefore
    = normalize(undeployedBackingBefore)
    + trustedYieldValueBefore

availableDeploymentSurplus
    = max(
        trustedBackingBefore
        - deployedCrvUsd,
        0
      )

conversionCost = max(
    normalize(targetSpent) - trustedValue(yieldSharesReceived),
    0
)

conversionCost <= availableDeploymentSurplus
conversionCost <= normalize(targetSpent)
    * downstreamExpansionPath.maxRouteLossBps / 10_000

trustedBackingAfter
    >= deployedCrvUsd
```

`maxRouteLossBps` belongs to the governance-approved downstream path configuration rather than a standalone strategy-wide deployment-loss parameter. The same path quote, step minima, execution-quality floor, final measured output, and route-level accounting-loss limit determine whether both an expansion's downstream attempt and a later `deployUndeployedBacking()` call are executable. Quote-relative slippage protection remains distinct from the accounting-loss limit: a route can execute exactly at a bad quote and still be rejected for losing too much normalized backing value.

If the route is unavailable or those checks fail, the maintenance call reverts and `undeployedBacking` remains intact. This means later deployment can reduce the protocol's retained execution spread, but cannot consume the principal backing deployed crvUSD.

The initial design does not combine old `undeployedBacking` with a newly rewarded expansion or automatically flush it afterward. That would contaminate current-call profit attribution and could make a healthy small conversion fail from excessive combined size. Existing undeployed backing is handled only through a separate explicit `deployUndeployedBacking(targetAmount)` call with independent snapshots and checks.

## Direct buyback lifecycle

Direct buyback provides one-sided downward liquidity through a deterministic backing waterfall. The caller chooses only the crvUSD amount and token-specific minimum outputs; V3 always pays `undeployedBacking` first and redeems yield backing only for the remaining trusted value. The caller cannot select a backing source, route, venue, recipient, or accounting value.

```text
1. Verify direct buyback is enabled.
2. Verify the requested crvUSD amount does not exceed `deployedCrvUsd` or available trusted backing.
3. Determine whether V3 is in the mature or young deployment state.
4. Select the normal exit margin in the mature state or the higher early exit margin in the young state.
5. Calculate the maximum trusted backing value payable while preserving that margin.
6. Transfer crvUSD from the caller to V3.
7. Allocate as much payout value as possible from `undeployedBacking` and decrease its accounting by the exact target amount paid.
8. If value remains, use the fixed ERC-4626 vault's exact-asset `withdraw()` operation to obtain that underlying remainder, rounding the maximum share burn up and measuring the actual share delta.
9. Transfer the target asset, underlying asset, or both to the caller.
10. Enforce the caller's token-specific minimums and measure actual backing outputs by balance delta.
11. Verify the received crvUSD exceeds total trusted backing value paid by the selected margin.
12. Reduce `deployedCrvUsd` by the crvUSD received and retain it as idle inventory.
13. Emit both payout amounts, yield shares spent, and whether early exit was used.
```

A preliminary interface is:

```solidity
function buyback(
    uint256 crvUsdAmount,
    uint256 minTargetOut,
    uint256 minUnderlyingOut
) external returns (
    uint256 targetOut,
    uint256 underlyingOut,
    uint256 yieldSharesSpent
);
```

If `undeployedBacking` can satisfy the complete quote, `underlyingOut` and `yieldSharesSpent` are zero. If it can satisfy only part, V3 pays all applicable undeployed backing first and withdraws the exact remaining underlying amount from the yield vault. If no undeployed backing exists, the complete payout comes from yield underlying. The call reverts unless combined trusted output and each caller minimum pass.

Direct buyback retains its exit spread as additional protocol surplus. Let `C` be crvUSD received and `P` be the trusted value of USDT plus yield underlying paid to the caller:

```text
surplusBefore = trustedBackingBefore - deployedCrvUsdBefore

trustedBackingAfter = trustedBackingBefore - P
deployedCrvUsdAfter  = deployedCrvUsdBefore - C

surplusAfter - surplusBefore
    = C - P
    = directBuybackProfit
```

The exit condition requires `C >= P + selectedExitMargin`. With the configured positive normal or early margin, `C > P`, so a successful direct buyback increases surplus by at least that margin; a future zero-margin setting would permit break-even but never reduce surplus. Because the payout waterfall spends USDT first, the residual assets will often be sUSDS shares, but those particular shares are not a separate profit bucket. They support any remaining `deployedCrvUsd`; only combined trusted backing above the remaining deployed amount is surplus. Once `deployedCrvUsd == 0`, all remaining trusted backing is surplus, subject to no other obligations.

The direct quote should be previewable:

```solidity
function previewBuyback(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedTargetOut,
        uint256 expectedUnderlyingOut,
        uint256 expectedYieldSharesSpent,
        uint256 requiredExitProfit,
        bool earlyExit
    );
```

The preview is advisory. Execution uses balance deltas and post-transaction profitability checks.

Caller minimums are retained because the direct buyback caller supplies crvUSD and may receive two different backing tokens. The effective minimums are the caller's token-specific floors combined with V3's internally calculated total trusted-value floor. Passing zero for either token cannot weaken V3's floor.

## Keeper buyback fallback

If no direct buyback flow arrives, a keeper can contract supply from either backing source.

For undeployed backing:

```text
1. Spend an exact bounded amount of undeployed backing.
2. Swap target asset for crvUSD through the target AMM.
3. Calculate gross exit profit as crvUSD received minus normalized target asset spent.
4. Pay the percentage-plus-flat-cap keeper reward in crvUSD.
5. Enforce the selected post-reward exit margin.
6. Decrease `undeployedBacking` by the target asset actually spent.
7. Reduce `deployedCrvUsd` by net crvUSD retained, capped at the deployed amount.
```

For yield backing:

```text
1. Verify keeper buyback is enabled.
2. Determine whether V3 is in the mature or young deployment state.
3. Select the normal or early exit margin accordingly.
4. Verify the keeper's requested yield-share amount is within the available yield backing and cannot reduce more than the current `deployedCrvUsd` exposure.
5. Execute the independent yield contraction path from yield token to crvUSD. For sUSDS this may redeem to USDS and then use a configured USDS/crvUSD venue without passing through USDT.
6. Calculate gross exit profit as crvUSD received minus the trusted backing value of yield-token shares spent.
7. Calculate the keeper reward as the configured percentage of gross exit profit, clamped by `maxKeeperReward`, and pay it to `msg.sender` in crvUSD.
8. Verify the net crvUSD retained after the reward exceeds the trusted backing value spent by the selected exit margin.
9. Reduce deployedCrvUsd by the net crvUSD retained, capped at the deployed amount.
10. Keep the remaining recovered crvUSD idle.
```

A preliminary interface is:

```solidity
function contractUndeployedBacking(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 crvUsdReceived, uint256 keeperReward);

function contractViaAmm(uint256 yieldShares)
    external
    returns (uint256 yieldSharesSpent, uint256 crvUsdReceived, uint256 keeperReward);
```

The keeper chooses only the exact target amount or yield-token shares. V3 calculates every route minimum, realized profit, and reward internally. The two contraction paths have separate venues, limits, and pause controls; failure of the downstream expansion route does not disable either undeployed backing contraction or a healthy yield-to-crvUSD route.

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

function previewUndeployedContraction(uint256 targetAmount)
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

struct DownstreamPathConfig {
    RouteStep[] steps;
    uint16 maxRouteLossBps;
}
```

No normal route step accepts arbitrary calldata. Additional venue types require a code change or a separately audited typed adapter. This restriction applies to permissionless execution paths, not the governance owner's separate `execute()` escape hatch.

### Separate directional paths

Downstream expansion and yield contraction paths are configured separately. V3 must not assume that the reverse path has the same venue, cost, liquidity, endpoint, or safety parameters. Undeployed-backing contraction uses the reverse direction of the designated target AMM and does not depend on either downstream path.

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
11. The downstream path's `maxRouteLossBps` is no greater than `10_000` and is committed with the path.
12. No venue, token, or endpoint is zero.

The target AMM and route venues may be replaced, but `targetAsset`, `backingAsset`, `yieldToken`, and the yield-accounting adapter cannot change. Every updated path must preserve the deployment's fixed endpoints, so governance cannot leave active paths, `undeployedBacking` accounting, or contraction endpoints mismatched.

There is no protocol-level maximum path length. Governance is trusted to configure an executable typed path; transaction gas and `minDownstreamAttemptGas` provide the practical bound. An excessively long or expensive downstream path can make the downstream branch unusable, but it cannot compromise fallback accounting: the isolated branch fails and expansion retains the target asset. Route review and gas-threshold benchmarking remain governance responsibilities.

### Path governance

Path replacement is a privileged operation capable of directing the protocol's full conversion flow. The DAO's seven-day voting period already supplies the public review window, so V3 does not add a second contract-level timelock:

```solidity
function setPaths(
    DownstreamPathConfig calldata newExpansionPath,
    RouteStep[] calldata newContractionPath
) external;
```

`setPaths` validates and replaces both active paths atomically in the governance execution transaction. It cannot migrate endpoints or make another token count as trusted backing.

The emergency admin may disable a path immediately but cannot apply a new one. Only the governance owner can install or replace routes.

There is deliberately no pending-path state, activation timestamp, or cancellation lifecycle inside V3. Duplicating the seven-day governance process would add state and defer an already approved repair without creating a new trust boundary.

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

After a target-to-yield route completes, V3 compares normalized target input with the trusted underlying value of measured yield shares and enforces `downstreamExpansionPath.maxRouteLossBps`. In a new expansion, failure of that check reverts the isolated branch and selects target-only fallback. In `deployUndeployedBacking()`, it reverts the maintenance call and leaves the target backing unchanged.

### Exact-input routing and direct exact-asset withdrawal

The configurable swap paths are exact-input. Expansion routes the keeper's exact crvUSD amount, later deployment routes an exact target amount, and keeper contraction routes an exact target amount or yield-share amount. Each step measures output and enforces a protocol-calculated `minOut`; none needs a generic exact-output swap adapter.

Direct buyback is the only action that needs a fixed underlying remainder after exhausting `undeployedBacking`. The ERC-4626 vault already provides the required primitive through `previewWithdraw(assets)`, `maxWithdraw(owner)`, and `withdraw(assets, receiver, owner)`. V3 verifies the remainder is withdrawable, calculates a conservative maximum share burn rounded up, calls `withdraw()` for the exact underlying amount, and checks actual asset and share deltas. This is vault rounding discipline, not a reason to add arbitrary exact-output Curve or converter adapters. A future route that genuinely requires a fixed swap output would need a separately typed and audited adapter for that venue.

## Keeper-supplied sizing

V3 does not calculate or verify the perfect maximum expansion. A keeper chooses an exact amount, while V3 retains every safety decision.

For expansion:

```text
minExpansionAmount <= crvUsdAmount

crvUsdAmount <= min(
    idleCrvUsd,
    maxDeployedCrvUsd - deployedCrvUsd
)
```

Fallback contraction applies ordinary minimum and maximum limits to either requested target amount or requested yield shares and their trusted backing value. The contract executes every requested amount exactly or reverts; it does not silently resize the transaction. Fallback expansion has no separate undeployed-backing cap: total target exposure remains bounded by `maxDeployedCrvUsd`, available Factory inventory, and the amount actually deployed.

The keeper can use `previewExpansion(amount)` or `previewKeeperBuyback(shares)` offchain to select an economically useful amount. Onchain, V3 still calculates every intermediate minimum, profit-share reward, flat reward cap, and final post-reward margin. A keeper-supplied amount can cause its own transaction to revert but cannot make an unsafe amount execute.

Under-sizing may leave a second profitable action available, and a flat per-call cap can be collected again if another complete profitable call succeeds. This is accepted: each reward is a percentage of independently realized post-route gross profit, each call leaves V3 with its configured post-reward margin, and the keeper pays additional gas. `minExpansionAmount` blocks true dust without adding quote probes or a full-path search.

`minExpansionAmount` remains important because a successful expansion resets the global contraction timer. Its initial value is `10_000e18` crvUSD. Governance can update it as capacity and observed execution behavior change. There is no separate per-call action-size maximum or rolling-flow throttle: idle inventory, available backing, and `maxDeployedCrvUsd` are the actual exposure bounds. This does not remove the independent per-call cap on keeper compensation.

## Profitability and execution controls

Realized profitability under the trusted-backing convention is the primary execution gate. V3 should not copy V2-style spot/EMA proximity checks onto the target crvUSD AMM: a sudden crvUSD price spike creates the exact expansion opportunity V3 should capture. Requiring spot to remain close to EMA would suppress the intended trade.

Expansion therefore has two authoritative realized postconditions. A fully deployed branch uses the approved underlying units represented by final yield shares after the complete downstream route and keeper reward. A fallback branch uses only the accounted target asset actually retained after its keeper reward. A downstream preview is never counted as backing. Each approved stablecoin unit is treated as one dollar without consulting the target AMM spot.

Contraction applies the inverse test to either source: crvUSD retained after paying the keeper must exceed the normalized undeployed backing or trusted yield value consumed by the configured margin.

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

Optional depeg or venue-health checks may later protect the non-crvUSD conversion path, but they must be independent from the target AMM's crvUSD spot/EMA divergence. A configured backing-quality guard may veto an action that would increase exposure despite nominal final value, while contraction, redemption, slow wind-down, and owner recovery actions that reduce exposure remain available. Caller minimums can only make execution stricter; they cannot weaken protocol minimums.

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

`backingAssetOut` is the actual balance delta after the crvUSD-to-target AMM swap and every successful downstream stablecoin conversion. Target-AMM fees, downstream pool fees, converter loss, and slippage are therefore already deducted before `grossEntryProfit` and the reward are calculated. The terminal yield deposit is then checked from the actual share delta and cannot weaken the final backing floor.

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
entryMargin = crvUsdSold * entryMinProfitPpm / 1_000_000

selectedBranchBackingRetainedAfterReward
>= crvUsdSold + entryMargin
```

The initial configuration is `entryMinProfitPpm = 50`, equal to `0.5 bps`. The ppm unit is deliberate because an integer basis-point parameter cannot represent half a basis point. Governance may reduce this parameter as low as `0`, but V3 does not support a negative entry margin. At zero, the selected branch must still break even after realized route costs, terminal rounding, and keeper reward. At the initial setting, the deployed branch must complete the downstream route while the fallback branch must retain target asset covering principal; either branch must then retain the additional `0.5 bps` margin. Later target-to-yield conversion remains optional and may spend only existing surplus.

Expansion should not wait for a timer, EMA, accumulated yield, or downstream route recovery. If the target-AMM leg can complete into acceptable target backing, delaying it gives away the above-peg opportunity.

### Exit policy

Routine contraction in the mature deployment state requires a governance-set `normalExitMinProfitPpm`. While V3 remains in the young deployment state, contraction must instead satisfy the larger `earlyExitMinProfitPpm`:

```text
selectedExitMarginPpm =
    block.timestamp < lastExpansionAt + minDeploymentTime
        ? earlyExitMinProfitPpm
        : normalExitMinProfitPpm

earlyExitMinProfitPpm > normalExitMinProfitPpm >= entryMinProfitPpm

selectedExitMargin
    = trustedBackingValue(selectedBackingSpent)
    * selectedExitMarginPpm / 1_000_000
```

The initial exit settings are:

```text
normalExitMinProfitPpm = 1_000  // 10 bps
earlyExitMinProfitPpm  = 5_000  // 50 bps
```

Ignoring swap fees, slippage, and keeper reward solely for price intuition, a `10 bps` retained-profit requirement corresponds to buying crvUSD at no more than approximately `0.999001` backing units, conventionally summarized as a `0.999` price. A `50 bps` requirement corresponds to approximately `0.995025`, summarized as `0.995`. The executable AMM price must normally be more favorable because the final post-reward condition includes route costs and keeper compensation.

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

The initial `minDeploymentTime` is `2 days` (`172_800` seconds). At those illustrative rates, two days earn approximately `2.19` to `2.74` basis points for exposure that reached the yield token. Undeployed backing does not earn this carry, but the same global timer applies to both backing sources because its core purpose is supply anti-churn rather than per-position yield attribution. Governance can update the duration.

The timer must not be used as a solvency assumption. Yield can change, stop, or become impaired. Every contraction still has to pass its realized final-value condition. Carry only improves the economics of holding exposure through short-lived volatility.

### Material-expansion timer

The design uses one global `lastExpansionAt`; it does not use tranches or maturity buckets. Only a material successful expansion can reset it. The keeper chooses the amount, but `expand()` can complete only when the sale meets the initial `10_000e18` crvUSD `minExpansionAmount` and receives acceptable final backing after route costs and the keeper reward.

The normal-exit timer is:

```text
earlyExit =
    deployedCrvUsd > 0
    && block.timestamp < lastExpansionAt + minDeploymentTime

minDeploymentTime = 2 days  // initial value; governance-changeable
```

A caller can still flash-borrow liquidity, buy crvUSD to create an expansion opportunity, request the minimum accepted expansion, and sell back afterward. That can reset the timer, but it is not free. The actor pays the market round trip, AMM fees and slippage, and enough manipulated premium for at least `10,000` crvUSD of V3's selected expansion branch and keeper compensation to pass.

The minimum makes timer manipulation economically self-penalizing rather than free. V3 sells the requested material amount into the price increase the actor created, so the attacker buys high, is countertraded by V3, then sells back lower while also paying pool fees. V3 captures the entry economics. This does not make manipulation cryptographically impossible: an actor with a sufficiently valuable external position may rationally pay that loss to delay normal-margin contraction. It cannot deadlock contraction because the timer never disables the exit functions; it only selects the higher early-exit margin. Genuinely distressed crvUSD can still be contracted during the timer while paying V3 that larger spread.

The global timer also means a sequence of legitimate profitable expansions extends the normal-exit delay for the whole position. That is accepted as part of the anti-churn policy. Later undeployed backing deployment does not reset this supply timer, so newly created yield shares are not guaranteed a separate carry interval.

At `10,000` crvUSD and the initial `0.5 bps` entry margin, the minimum guaranteed retained protocol margin is only `0.50` normalized dollar units. The attacker's total cost is higher because it also bears AMM fees, slippage, and the manipulated round trip, but the absolute threshold does not make timer resets expensive by itself. The higher early-exit margin prevents a hard lock. Governance should monitor reset behavior and can raise `minExpansionAmount` if repeated resets become too cheap relative to deployed capacity.

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

The initial governance-changeable settings are:

```text
keeperProfitShareBps = 3_000  // 30%
maxKeeperReward      = 20e18  // $20 normalized backing value
```

The raw percentage reward reaches the cap when realized gross profit reaches:

```text
$20 / 30% = $66.6667
```

There is no single cap-triggering notional because gross profit depends on the realized spread. Representative notionals are:

| Realized gross-profit rate | Notional that produces `$66.6667` gross profit |
|---:|---:|
| `0.5 bps` | `$1,333,333` |
| `1 bps` | `$666,667` |
| `2 bps` | `$333,333` |
| `5 bps` | `$133,333` |
| `10 bps` | `$66,667` |
| `50 bps` | `$13,333` |

At the initial entry floor, V3 must retain `0.5 bps` after the uncapped `30%` reward. The minimum gross-profit rate is therefore `0.5 / 70% = 0.714286 bps`, which reaches the `$20` cap at approximately `$933,333` notional. An action with a larger realized gross spread reaches the cap at a smaller notional.

For the initial `10,000 crvUSD` minimum expansion, a branch executing at exactly that floor realizes approximately `$0.7143` gross profit, pays approximately `$0.2143` to the keeper, and retains `$0.50` for V3. The minimum action size is therefore an anti-dust and timer-reset bound, not a guarantee that the reward covers mainnet gas; keepers act only when actual size and spread make the capped reward worthwhile.

For fully deployed expansion, `grossProfit` is normalized backing asset received immediately before terminal yield deployment minus crvUSD sold, and the keeper is paid in that backing asset. For fallback expansion, it is normalized target asset actually received after target-AMM fees and slippage minus crvUSD sold, and the keeper is paid in target asset before the remainder enters `undeployedBacking`. A failed downstream subcall rolls back its token conversions, so it changes caller gas cost but does not leave partial downstream route loss in V3. `maxKeeperReward` is stored in normalized 18-decimal backing-value units and token conversion rounds down. For either keeper contraction source, `grossProfit` is crvUSD received minus trusted backing value spent, and the keeper is paid in crvUSD.

One `expand()` call pays one branch reward. It does not pay separate rewards for the first crvUSD-to-target swap and the downstream target-to-yield conversion. Direct buyback and `deployUndeployedBacking()` callers receive no percentage reward. No explicit gas reimbursement is added to any branch; a keeper decides whether the realized reward, capped at `$20`, covers transaction gas and execution risk.

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

V3 uses one fungible surplus value rather than separate onchain buckets for yield and execution spread:

```text
protocolSurplus
    = max(trustedBackingValue - deployedCrvUsd, 0)
```

Here `trustedBackingValue` is the normalized value of accounted undeployed USDT plus the current underlying-equivalent value represented by the fixed sUSDS position. It uses current `convertToAssets()` value, not merely the historical USDS amount deposited, so accrued vault yield is included.

Yield-token appreciation, retained expansion or contraction profit, and route costs all change the same combined trusted-backing value. Tracking their provenance separately would require persistent cost-basis accounting across mixed backing, later deployment, buyback waterfalls, share-price appreciation, and fee claims, without strengthening the principal invariant.

A fee withdrawal transfers source backing rather than performing another V3 conversion. Each claim calculates the maximum withdrawable amount from combined trusted backing, rounds principal requirements against the fee receiver, and must leave `trustedBackingValue >= deployedCrvUsd`. Existing action events provide enough data for offchain reporting to estimate retained execution profit and yield carry without adding consensus-critical surplus buckets.

```solidity
function claimSurplus(uint256 maxTrustedValue)
    external
    returns (uint256 targetTransferred, uint256 yieldSharesTransferred);
```

The caller selects only a maximum normalized value; it cannot select the asset source or recipient. V3 uses this deterministic waterfall:

```text
claimValue = min(maxTrustedValue, protocolSurplus)

1. Transfer as much claim value as possible from accounted USDT.
2. If claim value remains, transfer sUSDS shares whose trusted value is
   no greater than the remainder, rounding the share amount down.
3. Leave any terminal rounding dust in V3.
4. Recompute trusted backing and require trustedBackingValue >= deployedCrvUsd.
```

USDT goes first because it is idle, earns no vault carry, and can be removed without a vault call. The remaining sUSDS keeps earning while it supports outstanding principal. This mirrors direct buyback's source order, but a surplus claim transfers sUSDS shares directly rather than redeeming them because the fee receiver—not the V3 core—owns fee conversion policy.

Share calculations must use the trusted value of the **remaining** post-transfer share balance rather than assuming `convertToAssets(totalShares - sharesTransferred) + convertToAssets(sharesTransferred) == convertToAssets(totalShares)`. ERC-4626 floor rounding need not be additive. The candidate share amount is rounded down, the actual share delta is measured, and `trustedValue` in `SurplusClaimed` is the observed `trustedBackingBefore - trustedBackingAfter`; the final principal check catches any remaining rounding edge.

The initial `feeReceiver` should be Curve's current `FeeCollector`, not the crvUSD mint-market `FeeSplitter`. V2's `withdraw_profit()` transfers pool LP tokens directly to `regulator.fee_receiver()` rather than converting them inside the PegKeeper.[8] The current `FeeCollector` is designed to collect arbitrary ERC-20 fee assets and has crvUSD as its target token.[9] Its current CowSwap burner creates sell orders for each supplied fee token into that target, so USDT and sUSDS can remain source assets when V3 claims profit.[11]

At Ethereum block `25,851,076`, all five live V2 PegKeepers referenced by this repository used regulator `0x36a04CAffc681fa179558B2Aaba30395CDdd855f`, whose `fee_receiver()` was the `FeeCollector` at `0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00`. The collector's live `target()` was crvUSD and its `burner()` was the generic CowSwap burner at `0xC0fC3dDfec95ca45A0D2393F518D3EA1ccF44f8b`.[9][11]

The separate mint-market `FeeSplitter` is crvUSD-specific: it claims controller fees, reads its crvUSD balance, and distributes that token by receiver weights.[10] Pointing V3 directly at it would therefore require V3 to convert surplus to crvUSD first. That would duplicate the `FeeCollector` burner, add route and market-price dependencies to fee claiming, and couple profit extraction to contraction execution. V3 instead transfers USDT first and then sUSDS to the configured `FeeCollector`; conversion to crvUSD occurs in the existing fee infrastructure.

At Ethereum block `25,851,058`, ControllerFactory's `fee_receiver()` was the `FeeSplitter` at `0x2dFd89449faff8a532790667baB21cF733C064f2`. Its two configured receiver weights were `5,000` each: `0xE8d1E2531761406Af1615A6764B0d5fF52736F56` and the `FeeCollector`; the latter was also the excess receiver.[10] This confirms the two contracts serve different layers: mint-market fees reach the splitter already as crvUSD, whereas PegKeeper profit can reach the collector in its source token.

`claimSurplus()` is permissionless to call but always pays the configured receiver. A future receiver update must point to a contract capable of handling both fixed backing tokens or governance must stop fee claims until it is.

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
- pause undeployed backing deployment without pausing target-only expansion;
- pause direct buyback;
- pause keeper buyback;
- lower `maxDeployedCrvUsd` to stop further exposure growth;
- governance updates to `maxDeployedCrvUsd`;
- atomic governance replacement of the target AMM and paths while preserving fixed token endpoints;
- fee-receiver update;
- governance updates to `minDeploymentTime`, `minExpansionAmount`, the entry and exit margin parameters, `keeperProfitShareBps`, `maxKeeperReward`, and `minDownstreamAttemptGas`;
- approval revocation for retired venues;
- owner-only arbitrary external execution for urgent recovery;
- expansion pause for contraction-only slow wind-down.

Setting `expansionPaused = true` is the complete slow-wind-down switch. It blocks new crvUSD sales but does not disable direct buyback or either keeper contraction path. Reacquired crvUSD remains idle and governance may lower the Factory ceiling to burn it. V3 does not need a separate global-shutdown state or a prescribed migration state machine.

## Owner execute escape hatch

The governance owner must be able to call an arbitrary target with arbitrary calldata:

```solidity
function execute(address target, uint256 value, bytes calldata data)
    external
    onlyOwner
    returns (bytes memory result);
```

This function exists for failures that typed routes and slow wind-down cannot handle directly. It is also the one-off recovery or migration-out mechanism. Examples include:

- loss of confidence in the current yield token or one of its underlying stablecoins;
- a vault, pool, or route changing behavior;
- an urgent transfer or conversion out of an impaired token or venue;
- recovery of tokens or approvals not anticipated by the original implementation;
- interacting with a one-off rescue contract approved by the DAO.

V3 applies no additional delay or migration-state precondition to `execute()`: once the governance owner invokes it, the ordinary external call executes in that transaction.

Using `execute()` to acquire a replacement token does not make that token part of normal V3 backing accounting. Continued operation with another yield token requires a new V3 deployment.

`execute()` performs a normal external `call`, not `delegatecall`. It bubbles the target's revert data and returns the target's return data. It has no target allowlist because an allowlist would defeat its role as a general recovery mechanism.

The owner is expected to be the same DAO or governance executor that already controls crvUSD minting, debt capacity, and protocol configuration. Within that governance trust model, `execute()` does not add a new trusted actor or materially expand the DAO's ultimate authority. It does increase the immediate blast radius of an owner compromise or governance mistake at this contract, so it must never be callable by keepers, public operators, or the emergency admin.

Governance should pause affected directions before using `execute()` where practical. If the call moves principal outside the fixed backing set, the existing V3 remains paused and is wound down or retired; it does not reconcile a new yield token into normal accounting. Calls that preserve the fixed endpoints may resume only after balances, accounting, approvals, and active paths are consistent.

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
    uint256 backingRetained,
    bool deployedToYield,
    uint256 unlockTime
);

event UndeployedBackingDeployed(
    address indexed caller,
    uint256 targetSpent,
    uint256 yieldSharesReceived,
    uint256 conversionCost
);

event DirectBuyback(
    address indexed caller,
    uint256 crvUsdReceived,
    uint256 targetPaid,
    uint256 underlyingPaid,
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

event PathsUpdated(bytes32 expansionHash, bytes32 contractionHash);
event DirectionPaused(uint8 indexed direction, bool paused);
event SurplusClaimed(
    address indexed receiver,
    uint256 targetTransferred,
    uint256 yieldSharesTransferred,
    uint256 trustedValue
);
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
4. `undeployedBacking` changes only through measured fallback retention, measured spending, successful typed deployment, governance reconciliation, or surplus withdrawal.
5. Unsolicited token transfers never increase accounted backing automatically.
6. Keeper rewards equal the configured percentage of realized gross profit for the selected branch, clamped by `maxKeeperReward` per call and rounded down.
7. Keeper rewards and fee claims cannot consume required principal or the configured protocol margin.
8. Caller-supplied minimums can only make execution stricter.
9. Callers cannot choose routes, venues, output recipients, or reward recipients.
10. Active paths always connect the configured endpoints.
11. Successful downstream execution leaves no material unaccounted intermediate-token balance.
12. A failed isolated downstream attempt leaves the target input in V3 and cannot partially consume it.
13. Deployment of undeployed backing cannot consume more than available surplus or exceed its path-configured loss bound.
14. Deployment of undeployed backing never changes `deployedCrvUsd` or `lastExpansionAt`.
15. Disabling expansion never disables direct buyback or the governance-approved contraction paths.
16. A path update preserves the deployment's fixed target asset, backing asset, yield token, and accounting adapter.
17. Every external conversion is non-reentrant and uses measured balance deltas.
18. Only the governance owner can execute arbitrary targets or calldata.
19. Keeper-supplied parameters cannot weaken protocol-calculated output or profit floors.
20. Combined trusted backing remaining after rewards, later deployment costs, and fee claims is never below `deployedCrvUsd`.
21. Expansion is not delayed when either approved branch satisfies its entry floor.
22. `lastExpansionAt` changes only after a successful expansion of at least `minExpansionAmount`.
23. Contraction during the young deployment state always satisfies `earlyExitMinProfitPpm`.
24. A failed or below-minimum expansion cannot extend the normal-exit timer.
25. Direct buyback never redeems yield shares for payout value that available `undeployedBacking` can satisfy.

## Risks

### Route and venue failure

Any path venue can lose liquidity, pause, change behavior, or become unsafe. The peg-critical target swap remains atomic with its selected fallback result. A failed isolated downstream attempt rolls back its own approvals and conversions while leaving the target asset in V3; path governance and directional pauses provide recovery.

### Fallback forcing and gas starvation

The fallback branch may produce a larger immediate keeper reward than the full route because it has not paid downstream conversion fees. A keeper must not be able to select that branch directly or force it by underfunding gas. `minDownstreamAttemptGas` must exceed the benchmarked route requirement with ample safety margin, and the subcall must preserve enough outer gas to finalize `undeployedBacking` accounting. Setting the threshold too low reopens forced fallback; setting it unnecessarily high rejects otherwise valid expansion calls. Route activation and material route changes should therefore include a compatible gas-threshold review.

### Undeployed backing accumulation

Undeployed backing preserves peg liveness but creates persistent exposure to the AMM-facing stablecoin and may remain idle without earning yield. V3 deliberately has no separate `maxUndeployedBacking`: if the target asset remains approved backing, downstream failure must not disable otherwise profitable peg support. Exposure is still bounded by `maxDeployedCrvUsd` and the Factory allocation, but in the worst case the entire deployed backing composition can remain in the target asset. Governance approval, directional pauses, direct undeployed-backing contraction, path recovery, and migration are the controls for that concentration risk.

### Yield-token impairment

A yield token can lose value or become temporarily non-redeemable. V3 deliberately trusts approved backing at par for protocol accounting, so the minimum-profit check does not detect an economic depeg by itself. Governance must pause affected execution and migrate or recover the position; the owner execute escape hatch exists partly for this case.

### Stablecoin basis risk

A USDT-facing AMM combined with an sUSDS yield position crosses USDT, DAI, USDS, and sUSDS. Governance explicitly accepts the persistent undeployed USDT backing and sUSDS underlying as dollar-par PegKeeper backing. Transient route assets do not count after a successful call. The checks prove nominal profitability under the trust convention rather than external-market dollar value.

### Oracle and preview manipulation

Target-AMM spot quotes and ERC-4626 previews can be manipulated or stale. V3 does not use the target-AMM spot as the dollar valuation source. It relies on actual balance deltas, the configured backing adapter, final nominal-profit assertions, deadlines, available inventory, and the total deployed-exposure bound. Governance is responsible for approving a vault or adapter whose share-to-underlying accounting is acceptable for backing.

### MEV

Keeper swaps through the external target AMM can be surrounded by flash-liquidity trades. Internal minimums, post-trade profitability checks, available inventory, and `maxDeployedCrvUsd` prevent principal loss under the configured accounting but do not guarantee capture of all transient spread. This residual value leakage is accepted to preserve open keeper participation.

### Keeper under-sizing

A keeper may choose less than the maximum profitable amount and leave a second opportunity available. It may then earn another capped reward from a later independently profitable call. This can leak more execution spread than a single optimally sized call, but the keeper bears extra gas and every completed action must leave V3 with its configured post-reward margin. `minExpansionAmount`, the total deployment bound, and open competition are considered sufficient for the initial design. Under-sizing can reduce immediate peg effect, but it cannot make an uneconomic action pass.

### Exit-delay liveness

A strict holding period could deadlock downward peg support during an actual crisis. V3 therefore does not impose an absolute lock: the timer selects a higher early-exit margin instead of disabling contraction. The global timer can be reset only by a successful minimum-sized expansion that pays its own execution economics, and a sufficiently distressed realized exit remains executable during the timer. Emergency governance and owner recovery remain separate last-resort paths.

### Governance route power

An updatable path can direct all future flows into a malicious venue. The DAO's seven-day vote, typed steps, endpoint validation, atomic compatible-bundle updates, exact approvals, and emergency directional pauses limit this risk. V3 deliberately does not duplicate the DAO review period with another contract-level delay.

### Governance execute power

The owner can intentionally bypass typed routes and move or approve assets through `execute()`. This is an explicit trust assumption, not a permissionless surface. A compromised owner can drain V3, but the designated DAO already controls crvUSD minting and the protocol configuration that determines V3's capacity. Ownership must not be delegated to a weaker hot-key or keeper role.

## Future considerations

### Optional backing-depeg guard

A backing-depeg guard is a possible later risk-control layer, not core V3 accounting or initial execution logic. If added, it should evaluate the target asset, yield-token underlying, or redemption health against references independent of crvUSD. A cheap crvUSD is exactly when contraction should buy it, and an expensive crvUSD is exactly when expansion should sell it; using crvUSD itself as the depeg reference would confuse the desired action signal with backing quality.

For a USDT-facing deployment, candidate observations include a robust USDT/USD oracle and time-weighted USDT/USDC or USDT/USDS markets that are independent of the designated crvUSD/USDT execution AMM. A production design would need explicit staleness rules, minimum liquidity and observation windows, treatment of disagreement between references, and protection against correlated stablecoin failures. No single comparison to another governance-approved stablecoin proves dollar parity.

Any later guard should be directional. It may stop expansion or downstream deployment from increasing exposure to an impaired target or underlying while preserving contraction, redemption, slow wind-down, and owner recovery actions that reduce that exposure. For a yield token, the relevant checks are the approved underlying's external value and the vault's actual redemption behavior; an illiquid share-market quote or `convertToAssets()` alone is not a complete depeg test.

## Remaining deferred decisions

The following are deliberately unresolved:

- initial downstream-path `maxRouteLossBps`;
- initial benchmarked numeric `minDownstreamAttemptGas` and `fallbackSettlementGasReserve` for the implemented downstream attempt;
- the execution-quality benchmark used in addition to the hard profit floor;
- exact adapter interface and rounding rules for converting supported yield shares into trusted underlying units;
- whether the direct buyback interface should be registered in Curve routing infrastructure;

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
[8] https://github.com/curvefi/curve-stablecoin/blob/cf1d05fb6bf7c608973cc41786b2e1fd81dc3a6a/curve_stablecoin/stabilizer/PegKeeperV2.vy — PegKeeperV2 profit withdrawal
    > "lp_amount: uint256 = self._calc_profit()
        POOL.transfer(self.regulator.fee_receiver(), lp_amount)"
[9] https://eth.blockscout.com/address/0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00?tab=contract — Curve FeeCollector verified source
    > "@notice Collects fees and delegates to burner for exchange"
    > "target: public(ERC20)  # coin swapped into"
    > "Ethereum block: 25851076
All five live PegKeeperV2 regulators: 0x36a04CAffc681fa179558B2Aaba30395CDdd855f
regulator fee_receiver: 0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00
FeeCollector target: 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
FeeCollector burner: 0xC0fC3dDfec95ca45A0D2393F518D3EA1ccF44f8b"
[10] https://eth.blockscout.com/address/0x2dFd89449faff8a532790667baB21cF733C064f2?tab=contract — Curve FeeSplitter verified source
    > "balance: uint256 = staticcall crvusd.balanceOf(self)"
    > "extcall crvusd.transfer(r.addr, balance * weight // MAX_BPS)"
    > "Ethereum block: 25851058
ControllerFactory fee_receiver: 0x2dFd89449faff8a532790667baB21cF733C064f2
FeeSplitter receiver 0: 0xE8d1E2531761406Af1615A6764B0d5fF52736F56, weight 5000
FeeSplitter receiver 1: 0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00, weight 5000
FeeSplitter excess_receiver: 0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00"
[11] https://eth.blockscout.com/address/0xC0fC3dDfec95ca45A0D2393F518D3EA1ccF44f8b?tab=contract — Curve CowSwapBurner verified source
    > "sellToken: sell_token"
    > "buyToken: buy_token"
