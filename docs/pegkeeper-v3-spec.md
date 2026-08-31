# PegKeeper V3 specification

Status: implementation-complete release candidate; not deployed.

This document records the implemented V3 architecture and its remaining deployment-specific governance decisions. The release package does not broadcast deployment or activation transactions.

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
6. Pay keepers a governance-set percentage of realized profit.
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
- **Backing asset:** the approved stablecoin denomination returned by the yield token's `asset()` and `convertToAssets()` accounting interface, such as USDS for sUSDS or frxUSD for sfrxUSD.
- **Yield token:** the fixed yield-bearing token that every successful downstream expansion path must leave in V3, such as sUSDS or sfrxUSD.
- **Downstream expansion path:** the updatable sequence from the target asset to the yield token.
- **Yield contraction path:** an independently configured sequence from the yield token to crvUSD, such as sUSDS redemption followed by a USDS/crvUSD swap.
- **Mature deployment state:** the configured minimum market time has elapsed since the latest successful material expansion.
- **Young deployment state:** V3 remains inside the minimum market-time window following the latest successful material expansion.
- **Deployed crvUSD:** Factory-allocated crvUSD that V3 has sold and has not yet reacquired.
- **Idle crvUSD:** crvUSD held by V3 and therefore available for a later expansion or Factory debt reduction.

## Actors

### Governance

Governance selects the deployment's fixed token endpoints and configures debt capacity, the target AMM, paths, execution constraints, profitability thresholds, and keeper fees. PegKeeper authorization resolves dynamically through `PegKeeperV3Factory.admin()`, and the crvUSD surplus recipient resolves through `PegKeeperV3Factory.fee_receiver()`. Approved route changes apply atomically when the governance proposal executes but cannot change fixed token endpoints. The current factory admin can also make an arbitrary external call through `execute()` when a typed path or slow wind-down is insufficient.

### Deployment factory owner

The owner of `PegKeeperV3Factory` is the only account that can deploy a factory-managed PegKeeper, update shared roles and deployment defaults, or nominate a replacement factory owner. The factory's implementation is immutable. Every keeper is a non-upgradeable EIP-1167 minimal proxy whose runtime embeds that implementation address; there is no proxy admin, implementation setter, or mutable implementation slot. The factory owner and shared PegKeeper admin remain separate roles; changing the factory's admin, emergency admin, or fee receiver is intentionally visible to every V3 that resolves those values from the factory.

### Emergency admin

The current `PegKeeperV3Factory.emergency_admin()` can immediately disable expansion, direct buyback, keeper buyback, or all execution across individual V3 instances. It cannot install a new path or move funds to an arbitrary address. The factory requires it to differ from `admin()` so the pause-only role cannot inherit owner execution authority or interfere with admin unpause semantics.

### Keeper

Any account can call the expansion and fallback contraction functions. V3 does not rely on a keeper whitelist or private order flow. Keeper rewards are paid to `msg.sender`, take a configured share of realized profit, and are paid only after a successful profitable transaction. The keeper chooses the exact amount, but cannot weaken protocol bounds, paths, minimum outputs, or profitability conditions.

### Arbitrageur or user

Any account can sell crvUSD directly to V3 through the buyback function while that direction is enabled. The caller receives only the fixed yield token and pays the direct transaction gas; no route executes. No additional keeper reward is paid for this direct trade.

### Fee receiver

V3 reads the surplus recipient dynamically from `PegKeeperV3Factory.fee_receiver()`. It stores no local receiver and exposes no per-PegKeeper receiver setter. This remains independent of `regulator.fee_receiver()`: live V2 PegKeepers may continue using the shared regulator's generic `FeeCollector`, while every V3 created by the deployment factory pays crvUSD to the factory's current receiver. Because the V3 profit token is always crvUSD, one shared receiver is sufficient. The receiver gets idle crvUSD only against realized surplus above the amount required to support outstanding externalized crvUSD and pending obligations. Backing tokens and principal yield-token units are never withdrawn as fees.

## State model

A minimal implementation needs the following state:

```text
factory
controllerFactory
name
keeperIndex
targetAmm
targetAmmExecutionBufferBps
targetAsset
backingAsset
yieldToken

deployedCrvUsd
undeployedBacking
accountedYieldTokenUnits
downstreamExpansionPath
yieldContractionPath

entryMinProfitPpm
normalExitMinProfitPpm
earlyExitMinProfitPpm
keeperProfitShareBps

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

The production implementation and stateless preview module use Vyper `0.3.10` with the `codesize` optimizer. The keeper core runtime is `21,298` bytes; deployment appends the immutable shared preview-module address for an authoritative `21,330`-byte implementation runtime, `3,246` bytes below EIP-170. The keeper-identity-bound Vyper preview module is `6,680` bytes. Each EIP-1167 instance uses 55-byte initcode and a 45-byte runtime. Executable runtime/initcode, proxy-target, implementation-lock, unified deployment, and ABI-parity checks live in `test/PegKeeperV3RuntimeSize.t.sol`, `test/PegKeeperV3UnifiedDeployment.t.sol`, `scripts/check-vyper-solidity-abi.py`, and the release manifest verifier.

The implementation keeps economic actions separate while centralizing repeated invariants. `_remaining_exposure_capacity()` is the sole local-cap and Factory-allocation calculation used by expansion and surplus claims; velocity remains an independent bound. `_target_amm_swap_exact_in()` owns target-AMM quoting, approval reset, minimum output, and exact input/output balance deltas. `_transfer_exact_to()` owns recipient balance-delta verification for protocol payouts. `_settle_keeper_contraction_and_reduce_exposure()` owns realized profit, keeper reward, exit margin, and capped exposure reduction for both keeper-triggered contraction paths, while each caller visibly retains its own target/yield inventory update and final solvency checks. `_checked_route_conversion_cost()` owns the configured route-loss ceiling. Expansion, direct buyback, undeployed-backing deployment, and the two contraction front halves remain distinct because their authorization, valuation, routing, inventory, and fallback semantics differ.

Vyper `0.3.10` emits disproportionately large runtime sequences for assertion reason strings. V3 therefore uses bare assertions for contract-owned guards rather than splitting custody, accounting, or route execution across extra modules solely to carry diagnostic text. This size remediation removes only V3's revert strings: every predicate, authorization boundary, atomic rollback, measured-delta check, state transition, return value, and event remains unchanged. A revert returned by the target of governance `execute()` is still bubbled verbatim. Offchain integrations must not branch on V3 revert text.

`targetAsset`, `backingAsset`, and `yieldToken` are fixed for the lifetime of a V3 deployment. The initial implementation requires the final yield token to expose the read-only ERC-4626 accounting methods `asset()`, `convertToAssets()`, and `convertToShares()`, with `yieldToken.asset() == backingAsset` at construction. It does not require the yield token itself to accept `deposit()` or `withdraw()`. Governance may replace venues and typed paths only when they preserve those endpoints. Supporting another yield token or accounting model requires a new V3 deployment rather than mutating the backing identity and accounting assumptions of the existing contract.

### Deployment factory and non-upgradeable minimal proxies

The canonical deployment factory stores one immutable implementation, the shared PegKeeper admin, distinct emergency admin, fee receiver, and deployment defaults for maximum deployed crvUSD, target-AMM execution buffer, downstream attempt gas, fallback reserve, and expansion route-loss bound. Only the factory owner can change policy values or deploy. Existing V3 instances read the three shared addresses dynamically; all accounting, endpoints, routes, pause state, oracle configuration, and velocity state live in each proxy's storage.

The owner supplies six deployment-specific values: `targetAmm`, `yieldToken`, mandatory `targetOracle` and `yieldOracle` adapters, `expansionSteps`, and `contractionSteps`. The factory discovers crvUSD from the fixed ControllerFactory, derives `targetAsset` from the two-coin target AMM, reads `backingAsset = yieldToken.asset()`, assigns `keeperIndex = keeperCount + 1`, and passes all configuration into one-time initialization. The resulting getters expose the numeric index and `name = "Pegkeeper " + uint2str(index)`.

Initialization is atomic. The factory performs exactly one `CREATE` for the minimal proxy and initializes it in the same transaction. The proxy marks itself initialized before external validation, accepts initialization only from its immutable factory binding, validates and stores both routes and all defaults, and rejects reinitialization. Any failure reverts creation and nonce consumption. The implementation is locked at construction and cannot be initialized for operational use. Every proxy starts fully paused.

The proxy fallback delegates only to the implementation address embedded in its runtime. There is no upgrade hook or implementation storage slot. Capacity and execution defaults are copied only into later deployments. Shared `admin`, `emergency_admin`, and `fee_receiver` changes intentionally apply to every existing V3 through factory getters; V3 exposes no local setters for those values. Existing proxies otherwise retain their independent capacity, identity, endpoints, routes, oracle addresses, balances, accounting, and velocity state.

## Supply accounting and Factory integration

The current ControllerFactory mints the configured debt-ceiling increase to V3 upfront. It does not grant V3 a permissionless lazy-mint function. The `debt()` compatibility getter returns `deployedCrvUsd` exactly so existing crvUSD aggregate monetary policies can include V3 exposure without counting idle allocation, backing value, or capacity.

The first implementation should therefore treat the Factory allocation as reusable inventory:

```text
Idle crvUSD
    -> expansion
Undeployed backing or yield-token position
    -> contraction
Idle crvUSD

Idle crvUSD
    -> surplus claim
FeeSplitter
```

`expand()` deploys idle Factory-allocated crvUSD. It does not mint directly under the current Factory interface. The initial V3 design intentionally keeps this allocation model and does not add lazy mint or burn authority.

Unused allocated crvUSD and crvUSD received during contraction remain idle in V3 rather than circulating in markets. They can be reused in a later expansion or, to the extent supported by realized surplus, transferred to the FeeSplitter. Under the current ControllerFactory allocation pattern, governance controls the approved amount and the Factory mints that amount to the strategy.[2] In V3 supply accounting, only the portion sold through expansion or distributed as crvUSD fees becomes active externalized supply. Governance can lower the Factory ceiling when it wants idle crvUSD burned.

A burn-only timer would not prevent market churn. Reacquiring crvUSD already removes it from active circulation; waiting to destroy the idle tokens changes Factory accounting but does not postpone the economic contraction. The timer must therefore gate use of the yield position for buyback, not merely the later burn transaction. Once crvUSD has been reacquired, governance may burn it immediately by lowering the Factory ceiling.

### Trusted backing convention

The current ControllerFactory does not inspect or mark to market assets held by a debt-ceiling recipient. It mints the allocation to the approved PegKeeper address and, when lowering the ceiling, burns only crvUSD currently held by that address.[2] Solvency therefore already depends on governance admitting a PegKeeper whose deployed assets are acceptable backing.

V3 makes that trust assumption explicit and narrow:

- governance approves the AMM-facing stablecoin, final yield token, accounting backing asset, typed conversion paths, and two mandatory independent oracle adapters;
- `address(0)` cannot disable oracle checking;
- target and downstream prices are normalized to `1e18`, launch with `0.9997e18` floors before increasing exposure, and receive at most par credit through `min(price, 1e18)`; governance may replace code-bearing adapters or change nonzero floors up to par without resetting pressure;
- yield-token units are converted into backing-asset units through `convertToAssets()` before the downstream oracle haircut is applied;
- only `undeployedBacking` and the configured yield position count toward V3 principal and surplus accounting;
- unsolicited tokens and arbitrary assets sent to V3 do not count as backing.

For any supported final yield token:

```text
trustedYieldValue(yieldTokenAmount)
    = normalizeDown(yieldToken.convertToAssets(yieldTokenAmount))
```

The returned backing-asset units are valued through the mandatory downstream adapter. The launch Curve adapters read rate-provider-normalized StableSwap-NG EMAs, so the sUSDS/frxUSD observation represents the underlying USDS economic comparison rather than raw share count. V3 performs `convertToAssets()` once, then applies the capped adapter price. The target AMM is never used as the backing-quality reference.

The minimal read-only accounting interface is:

```solidity
interface IYieldTokenAccounting {
    function asset() external view returns (address);
    function convertToAssets(uint256 yieldTokenAmount)
        external
        view
        returns (uint256 backingAssetAmount);
    function convertToShares(uint256 backingAssetAmount)
        external
        view
        returns (uint256 yieldTokenAmount);
}
```

Acquisition and unwind are deliberately not part of that accounting interface. They are typed route steps. The terminal expansion step may deposit into an ERC-4626 vault, swap through a Curve pool, or use another explicitly supported typed adapter, but its measured `tokenOut` must be the fixed `yieldToken`. The first yield-unwind step is independently encoded in `yieldContractionPath`.

V3 applies these accounting rules regardless of how the route acquired the final token:

```text
trusted assets for held yield-token units
    = yieldToken.convertToAssets(accountedYieldTokenUnits)

trusted normalized value
    = normalizeDown(trusted assets)

trusted value added when yield-token units enter V3
    = normalizeDown(yieldToken.convertToAssets(actualYieldTokenReceived))

trusted value removed when yield-token units leave V3
    = trustedBackingBefore - trustedBackingAfter
```

ERC-4626 requires its conversion methods to round down. Where a route actually uses a vault deposit, it also requires `previewDeposit()` to return no more than the shares minted by a same-transaction deposit.[12] V3 therefore uses:

- `convertToAssets(accountedYieldTokenUnits)` with downward normalization for principal and surplus valuation;
- `convertToShares(backingAssetAmount)` only as a downward-rounded sizing primitive, never as proof of assets actually realized;
- the terminal route step's own quote method—such as Curve `get_dy()` or ERC-4626 `previewDeposit()`—followed by the measured yield-token balance delta;
- conservative standalone valuation of newly received yield-token units so pre-existing yield appreciation cannot be attributed to the new action;
- pre/post total-position valuation when yield-token units are spent, rather than assuming `convertToAssets(total - spent) + convertToAssets(spent) == convertToAssets(total)`;
- actual token deltas as the final authority for every state change.

`accountedYieldTokenUnits` increases only by measured final-token receipts from successful typed routes and decreases by measured yield-token spending or direct transfers. The actual ERC-20 balance must never be below the accounted units. Unsolicited yield-token transfers may make the raw balance larger but do not become trusted backing automatically.

After the complete acquisition route, V3 applies `convertToAssets()` to the actual final yield-token units received and uses the rounded-down result for the action's trusted-asset profit floor before increasing `accountedYieldTokenUnits` by that measured amount. For an increasing position this standalone value is conservative under downward rounding and does not credit existing yield to the new action. For a decreasing position V3 instead recomputes the complete pre/post accounted position because conversion floors are not additive.

This separation is necessary for sfrxUSD. At Ethereum block `25,851,930`, sfrxUSD returned a valid frxUSD `asset()`, `convertToAssets()`, and `convertToShares()` result while both `maxDeposit()` and `previewDeposit()` returned zero.[13] A frxUSD-facing PegKeeper must therefore acquire sfrxUSD through the configured route—such as a frxUSD/sfrxUSD swap—rather than assuming the final token is directly depositable.

This is a protocol accounting convention, not proof that every approved stablecoin can always be sold for one dollar. If an approved backing asset depegs, freezes, or becomes non-redeemable, V3 can remain nominally solvent under its configured accounting while being economically impaired. Governance must pause affected routes and use slow wind-down or owner `execute()` to recover or move the position. Continuing with a different yield token requires deploying a new V3.

For a USDT-facing sUSDS deployment:

```text
trustedBackingValue
    = normalize(undeployedBacking)
    + normalize(convertToAssets(sUsdsShares))

deployedCrvUsd <= Factory allocation
deployedCrvUsd <= trustedBackingValue
```

`deployedCrvUsd` is the amount of V3's accounted crvUSD allocation that has been externalized from V3 and therefore requires the approved backing portfolio. It is broader than only crvUSD sold through an AMM. Expansion increases it by crvUSD sold; a surplus claim increases it by crvUSD transferred to the FeeSplitter. Direct buyback decreases it by crvUSD received from the user, and keeper contraction decreases it by crvUSD retained after the keeper reward, always capped at the current deployed amount. Idle crvUSD backs itself; the combined trusted value of undeployed backing and the yield position must cover all externalized crvUSD after rewards, later conversion costs, and fee claims.

## Expansion lifecycle

Expansion is keeper-driven. V3 does not offer a separate direct upward-price quote in the initial design.

Expansion has no time cooldown, but every exposure increase is bounded by the keeper-local velocity bucket. The target-AMM sale is the peg-critical leg; downstream yield deployment is allowed only when its independent adapter is healthy. The initial `0.1 bps` entry margin requires whichever branch completes to retain principal plus that margin after realized costs and reward.

```text
1. Verify expansion is enabled.
2. Read the mandatory target adapter; revert on failure or a value below 0.9997e18.
3. Verify the requested amount against minExpansionAmount, idle crvUSD, remaining local capacity, and available keeper-local velocity.
4. Consume velocity pressure; a later revert rolls this state back.
5. Sell crvUSD into the designated target AMM and measure target received.
6. Read the mandatory downstream adapter.
7. If the downstream adapter fails or is below 0.9997e18, skip downstream execution and use the target-retention fallback.
8. Otherwise attempt the configured target-to-yield path in an isolated, typed, onlySelf call with protocol-calculated minima.
9. Treat the downstream branch as successful only if the isolated call completes and returns consistent measured deltas.
10. If downstream execution fails, roll back only that subcall, pay reward only from realized fallback profit, and retain the remainder as undeployedBacking.
11. Require the selected branch to satisfy the entry floor and complete backing invariant. A failure of both branches reverts the full transaction and pressure consumption.
12. Increase deployedCrvUsd, update lastExpansionAt, and emit the branch and measured execution result.
```

The downstream call is not an arbitrary keeper-controlled call. `expand()` invokes the ABI-visible `executeExpansionPath(targetAmount, crvUsdSold, keeper)` entry point only through a call to itself; every external caller is rejected. The helper uses the active typed path, exact temporary approvals, the original expansion caller as the fixed reward recipient, and a bounded forwarded-gas amount. Any route, reward, terminal yield-acquisition, or full-route economic failure reverts the isolated call and selects fallback with the original target asset still held by V3. If the isolated call returns success but its returned target or yield-token deltas are inconsistent with the outer snapshots, the outer expansion reverts entirely rather than accepting fallback after state has committed.

This gas policy is not a reward for deploying `undeployedBacking`. It is a transaction-safety rule for the downstream attempt inside `expand()`. Immediately before the isolated subcall, V3 requires `gasleft() >= minDownstreamAttemptGas`, where `minDownstreamAttemptGas` is governance-changeable. Its initial value is selected only after implementation benchmarks and should include ample headroom over the measured worst-case full route, call overhead, failed-attempt handling, fallback accounting, token payment, storage writes, and event emission. Expansion cannot be enabled with an uninitialized zero threshold, and a materially different downstream path must be activated with a compatible threshold.

A minimum `gasleft()` check alone is insufficient if the downstream subcall can consume everything after the check. V3 therefore forwards at most the available attempt gas minus `fallbackSettlementGasReserve`; an out-of-gas downstream call returns failure while the preserved outer gas remains available to calculate the fallback reward, record `undeployedBacking`, and finish the outer call. The expected threshold may be on the order of several hundred thousand gas, but the specification does not assign a number before measurement. Governance should update the threshold when activating a materially different downstream path. Neither the minimum nor the reserve is paid to the caller.

### No aggregate crvUSD trigger

The initial design does not require a separate aggregate crvUSD oracle trigger. Expansion acceptance is determined by exact amount bounds, protocol-calculated route minima, realized post-reward profitability for the selected terminal branch, final trusted-backing checks, and configured exposure limits.

An aggregate trigger could reject a locally profitable sale because a broader oracle is stale, slow, or reports crvUSD near one dollar. That recreates an oracle-coupled liveness condition without uniquely improving the nominal backing invariant. A keeper can manufacture a local target-AMM opportunity even when broader crvUSD markets are balanced, but the manipulation must still leave V3 with the configured realized margin after reward and pay the attacker's round-trip costs. The remaining concern is bounded rent leakage or unwanted supply cycling, not an unaccounted principal loss.

This decision should be revisited only if simulation or live operation identifies a concrete cross-market externality that realized final profitability and the total deployed-exposure bound do not contain. Aggregate crvUSD observations may still be useful for monitoring and governance alerts without gating the core transaction.

The implemented public keeper interface is:

```solidity
function expand(uint256 crvUsdAmount) external returns (
    uint256 crvUsdSold,
    uint256 backingRetained,
    uint256 yieldTokenReceived,
    uint256 keeperReward,
    bool deployedToYield
);
```

The keeper chooses only the exact crvUSD amount. V3 validates its bounds and calculates gross profit, reward, and every intermediate and final minimum internally. The keeper cannot choose the target AMM, path, output token, fee receiver, reward recipient, fee percentage, or minimum output.

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
        uint256 expectedYieldToken,
        bool expectedToDeploy
    );
```

The preview is advisory. It enforces the same requested-amount, idle-inventory, local-capacity, and Factory-allocation bounds as `expand()`, but it remains callable while execution is paused so keepers and governance can inspect the configured economics. `expectedTargetOut` is the current target-AMM quote. When the configured downstream quotes satisfy route-loss and final-entry-margin checks, `expectedBackingAssetOut` is the gross backing amount immediately before the terminal step, `expectedKeeperReward` is in backing-asset native units, `expectedYieldToken` is the terminal quote after that reward, and `expectedToDeploy` is true. Otherwise the return describes the target-only fallback: `expectedBackingAssetOut` and `expectedYieldToken` are zero, profit is target-denominated, reward is in target-asset native units, and `expectedToDeploy` is false. A route quote call itself may revert rather than manufacture a fallback estimate.

A downstream quote can become stale or the route can revert during execution; the state-changing call therefore selects the branch only from actual call success and realized balance deltas. Preview output never supplies execution minima and cannot weaken any onchain check.

For a completed downstream attempt, the keeper reward is calculated from the measured backing asset present immediately before the terminal yield-acquisition step. The reward is transferred in backing-asset native units before that final step. The route-loss check excludes that deliberate reward from conversion loss while still requiring the final yield position to satisfy the entry floor and the complete state to remain globally backed:

```text
completedRouteValue
    = trustedYieldValue(yieldTokenReceived)
    + min(yieldOraclePrice, 1e18) * normalize(actualBackingRewardPaid) / 1e18

sourceTargetValue
    = min(targetOraclePrice, 1e18) * normalize(targetReceived) / 1e18

conversionCost
    = max(sourceTargetValue - completedRouteValue, 0)

conversionCost
    <= sourceTargetValue
       * downstreamExpansionPath.maxRouteLossBps / 10_000

trustedYieldValue(yieldTokenReceived)
    >= crvUsdSold
       + crvUsdSold * entryMinProfitPpm / 1_000_000
```

The outer call accounts only the exact final yield-token balance increase returned by the successful helper. Pre-existing target, intermediate, backing, and yield-token donations remain outside current-call accounting. Existing `undeployedBacking` is never combined with the new target receipt.

### Fallback profit and keeper payment

For a target-only fallback:

```text
fallbackGrossProfit
    = min(targetOraclePrice, 1e18) * normalize(targetAssetReceived) / 1e18
    - crvUsdSold

fallbackKeeperRewardValue
    = floor(fallbackGrossProfit * keeperProfitShareBps / 10_000)

targetAssetRetained
    = targetAssetReceived
    - denormalizeDown(fallbackKeeperRewardValue)

min(targetOraclePrice, 1e18) * normalize(targetAssetRetained) / 1e18
    >= crvUsdSold
       + crvUsdSold * entryMinProfitPpm / 1_000_000
```

The target asset is a valid terminal backing state. V3 does not deduct a hypothetical future yield-route fee before paying this reward because future deployment is optional: `undeployedBacking` may instead be used directly for contraction. With the initial `30%` keeper share, V3 retains principal plus at least `70%` of this branch's realized gross profit before normalization rounding.

### Later undeployed backing deployment

Undeployed backing may be converted later through the same fixed downstream path:

```solidity
function deployUndeployedBacking(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 yieldTokenReceived);
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
    normalize(targetSpent) - trustedYieldValue(yieldTokenReceived),
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

Direct buyback provides one-sided downward liquidity through one fixed routing edge:

```text
crvUSD -> yieldToken
```

A direct-buyback call always transfers the deployment's fixed final `yieldToken`; it never returns `targetAsset`, never returns two tokens, and never executes the acquisition or contraction route. The caller chooses only the crvUSD input amount and a minimum yield-token output. It cannot select the backing source, payout token, recipient, route, or accounting value.

```text
1. Verify direct buyback is enabled.
2. Verify the requested crvUSD amount does not exceed `deployedCrvUsd`, the trusted capacity of `accountedYieldTokenUnits`, or available trusted backing.
3. Determine whether V3 is in the mature or young deployment state and select the corresponding exit margin.
4. Calculate the maximum trusted payout value that preserves that margin.
5. Use `convertToShares()` only to derive a downward-rounded `yieldTokenOut` whose measured trusted value cannot exceed the payout budget.
6. Transfer crvUSD from the caller to V3 and transfer exactly `yieldTokenOut` to the caller. V3 performs no withdrawal, redemption, or swap.
7. Enforce `minYieldTokenOut`, measure actual yield-token spending and caller receipt by balance delta, and decrease `accountedYieldTokenUnits` by the measured amount spent.
8. Recompute trusted value removed from the complete pre/post accounted yield position.
9. Verify crvUSD received exceeds trusted backing spent by the selected margin and that remaining trusted backing covers remaining `deployedCrvUsd`.
10. Reduce `deployedCrvUsd` by crvUSD received, retain it as idle inventory, and emit the yield-token amount paid.
```

The implemented interface is:

```solidity
function buyback(
    uint256 crvUsdAmount,
    uint256 minYieldTokenOut
) external returns (uint256 yieldTokenOut);
```

The caller receives sUSDS, sfrxUSD, or the deployment's other fixed yield-bearing token and may unwrap or swap it independently. Direct buyback does not depend on target inventory or acquisition-route or contraction-route availability. If insufficient accounted yield tokens exist, the quote is unavailable; V3 does not fall through to target-asset payment.

No binary search, exact-output adapter, or yield unwind is required. V3 derives `yieldTokenOut` conservatively from the trusted payout budget. The initial candidate uses `convertToShares(max(denormalizeDown(payoutBudget) - 1, 0))`; the one-native-unit haircut covers the possible non-additive floor increment, and the final measured pre/post trusted-value check remains authoritative. If that check would still exceed the budget, the call reverts rather than overpaying from principal.

The payout is priced only through the fixed trusted accounting interface:

```text
preYieldValue
    = normalizeDown(
        yieldToken.convertToAssets(preAccountedYieldTokenUnits)
      )

postYieldValue
    = normalizeDown(
        yieldToken.convertToAssets(postAccountedYieldTokenUnits)
      )

P = preYieldValue - postYieldValue
```

`convertToShares()` is only a conservative sizing helper. The whole accounted-position pre/post `convertToAssets()` difference is authoritative because floor-rounded conversions are not necessarily additive. No AMM quote, ERC-4626 withdrawal preview, or market price is used to value the direct payout.

Direct buyback retains its exit spread as additional protocol surplus. Let `C` be crvUSD received and `P` be the trusted value of yield tokens paid:

```text
surplusBefore = trustedBackingBefore - deployedCrvUsdBefore

trustedBackingAfter = trustedBackingBefore - P
deployedCrvUsdAfter  = deployedCrvUsdBefore - C

surplusAfter - surplusBefore
    = C - P
    = directBuybackProfit
```

The exit condition requires `C >= P + selectedExitMargin`. With the configured positive normal or early margin, `C > P`, so a successful direct buyback increases surplus by at least that margin; a future zero-margin setting would permit break-even but never reduce surplus.

The direct quote is fixed-token and previewable:

```solidity
function previewBuyback(uint256 crvUsdAmount)
    external
    view
    returns (
        uint256 expectedYieldTokenOut,
        uint256 requiredExitProfit,
        bool earlyExit
    );
```

The preview is advisory. Execution uses measured deltas and post-transaction profitability checks. The caller's `minYieldTokenOut` can only make execution stricter.

The Vyper `0.3.10` implementation solves the selected-margin payout budget without overflow-prone full-width multiplication, denormalizes it downward into backing-asset native units, subtracts the specified one-native-unit haircut, and passes that amount to `convertToShares()`. Execution measures exact crvUSD spending/receipt and exact yield-token spending/receipt on both sides of each transfer. It snapshots the complete accounted yield position before either token call and values the remaining accounted position after the yield transfer, so any conversion-rate change triggered during transfer is included in the realized payout value. A stale or non-standard token behavior that violates the quoted margin, exact deltas, or final principal invariant reverts the complete transaction.

### Routing integration

A buyback that returns two unrelated ERC-20 outputs is a poor fit for ordinary routing infrastructure, and a state-changing `coins()` list is also unsafe because route graphs, indexers, and cached integrations treat an edge's tokens as fixed. Yield-only direct buyback avoids both problems.

If V3 exposes or is wrapped by a Curve-style routing surface, the pair is immutable for the deployment:

```text
coins(0) = crvUSD
coins(1) = yieldToken
```

A change from sUSDS to sfrxUSD still requires a new V3 deployment. A quote can become stale in amount, but it cannot become stale in output-token identity.

### Undeployed target cleanup

`undeployedBacking` is never paid through direct buyback and never changes its advertised routing pair. It remains ordinary trusted backing and can be handled by either existing permissionless keeper path:

- `contractUndeployedBacking(targetAmount)` swaps target asset to crvUSD and earns the configured keeper share only from realized contraction profit; or
- `deployUndeployedBacking(targetAmount)` sends target asset through the configured expansion route to the fixed yield token, pays no percentage reward, and executes only when route-loss, surplus, and final principal checks pass.

Small target dust may remain accounted indefinitely without blocking yield-token buybacks. It can accumulate into an economical keeper action or be handled during wind-down or owner recovery. No dust threshold, dynamic coin list, or direct-buyback source switch is required.

## Keeper buyback fallback

If no direct buyback flow arrives, a keeper can contract supply from either backing source.

For undeployed backing:

```text
1. Spend an exact bounded amount of undeployed backing.
2. Swap target asset for crvUSD through the target AMM.
3. Calculate the principal-recovery basis as the greater of normalized target asset spent and the crvUSD recovery needed to keep remaining trusted backing solvent. Calculate gross exit profit as crvUSD received above that basis.
4. Pay the configured percentage of realized gross profit to the keeper in crvUSD.
5. Enforce the selected post-reward exit margin.
6. Decrease `undeployedBacking` by the target asset actually spent.
7. Reduce `deployedCrvUsd` by net crvUSD retained, capped at the deployed amount.
```

For yield backing:

```text
1. Verify keeper buyback is enabled.
2. Determine whether V3 is in the mature or young deployment state.
3. Select the normal or early exit margin accordingly.
4. Verify the keeper's requested yield-token amount is within the available yield backing and cannot reduce more than the current `deployedCrvUsd` exposure.
5. Execute the independent yield contraction path from yield token to crvUSD. For sUSDS this may redeem to USDS, convert through DAI and a stablecoin venue, and then use the designated target AMM; for sfrxUSD it may first swap to frxUSD.
6. Calculate the principal-recovery basis as the greater of the trusted backing value removed and the crvUSD recovery needed to keep remaining trusted backing at least equal to remaining deployed exposure. Calculate gross exit profit as crvUSD received above that basis. This prevents recovery of an existing backing deficit from becoming rewardable profit.
7. Calculate the keeper reward as the configured percentage of gross exit profit and pay it to `msg.sender` in crvUSD.
8. Verify the net crvUSD retained after the reward exceeds the trusted backing value spent by the selected exit margin.
9. Reduce deployedCrvUsd by the net crvUSD retained, capped at the deployed amount.
10. Keep the remaining recovered crvUSD idle.
```

The implemented keeper-contraction interface is:

```solidity
function contractUndeployedBacking(uint256 targetAmount)
    external
    returns (uint256 targetSpent, uint256 crvUsdReceived, uint256 keeperReward);

function contractViaAmm(uint256 yieldTokenAmount)
    external
    returns (uint256 yieldTokenSpent, uint256 crvUsdReceived, uint256 keeperReward);
```

The keeper chooses only the exact target amount or yield-token units. V3 calculates every route minimum, realized profit, and reward internally. The two contraction paths have separate venues, limits, and pause controls; failure of the downstream expansion route does not disable either undeployed backing contraction or a healthy yield-to-crvUSD route.

Yield-token contraction values units leaving from the complete accounted position rather than treating `convertToAssets()` as additive:

```text
preYieldValue = normalizeDown(yieldToken.convertToAssets(accountedYieldTokenUnitsBefore))
postYieldValue = normalizeDown(yieldToken.convertToAssets(accountedYieldTokenUnitsAfter))
trustedValueRemoved = preYieldValue - postYieldValue
```

This pre/post difference is authoritative for the exposure bound, realized gross profit, selected post-reward margin, and final principal check. `convertToAssets(yieldTokenSpent)` is not interchangeable because ERC-4626 floor rounding can make it differ from the whole-position value change. Execution snapshots the pre-route position and re-reads the remaining position after route execution, so a conversion-rate update triggered by the unwind is included in realized accounting. It spends exactly the requested accounted units, measures final crvUSD by V3's balance delta, pays the keeper only from realized gross profit, reduces `deployedCrvUsd` by net retained crvUSD capped at the current exposure, and leaves `lastExpansionAt` unchanged. The yield branch emits `KeeperBuyback` with `backingToken = backingAsset`, `backingSpent = 0`, and the measured `yieldTokenSpent`.

The keeper fallback is previewable:

```solidity
function previewKeeperBuyback(uint256 yieldTokenAmount)
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

The production route executor supports only typed operations:

```solidity
enum StepKind {
    CurveSwap,
    DaiUsdsConverter,
    ERC4626Deposit,
    ERC4626Redeem,
    FrxUsdMint
}

interface IFrxUsdMinter {
    function asset() external view returns (address);
    function frxUSD() external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

interface IDaiUsds {
    function dai() external view returns (address);
    function usds() external view returns (address);
    function daiToUsds(address receiver, uint256 amount) external;
    function usdsToDai(address receiver, uint256 amount) external;
}

struct RouteStep {
    StepKind kind;
    address venue;
    address tokenIn;
    address tokenOut;
    int128 poolIndexIn;
    int128 poolIndexOut;
    uint256 executionBufferBps;
}

struct DownstreamPathConfig {
    RouteStep[] steps;
    uint256 maxRouteLossBps;
}
```

`DaiUsdsConverter` calls Sky's canonical converter directly; it is not a generic arbitrary-call adapter. The live contract exposes DAI and USDS getters and these no-return conversion methods:[14]

```solidity
function daiToUsds(address receiver, uint256 amount) external;
function usdsToDai(address receiver, uint256 amount) external;
```

For a DAI-to-USDS step, V3:

1. verifies `IDaiUsds(venue).dai() == tokenIn` and `IDaiUsds(venue).usds() == tokenOut`;
2. approves exactly `amountIn` DAI to `venue`;
3. calls `daiToUsds(address(this), amountIn)`;
4. resets approval to zero;
5. calculates USDS output solely from V3's balance delta.

The USDS-to-DAI direction performs the symmetric checks and calls `usdsToDai(address(this), amountIn)`. The converter pulls exactly `amountIn` from the caller and exits the same `wad` to the hardcoded receiver; it returns no amount.[14] Both canonical tokens use 18-decimal units, so the protocol quote is `quotedOut = amountIn`, `executionBufferBps` must be zero, and measured output must equal `amountIn`. A mismatched getter, nonzero buffer, failed transfer, or non-1:1 balance delta reverts the route step.

`FrxUsdMint` is a mint-only adapter for Frax's external-share USDC custodian. It exists because the custodian exposes ERC-4626-like `previewDeposit()` and `deposit()` methods but mints a separate frxUSD token rather than making the venue itself the share token. For each step V3 verifies `venue.asset() == tokenIn` and `venue.frxUSD() == tokenOut`, requires zero pool indices, quotes through `previewDeposit(amountIn)`, approves and deposits the exact input with V3 as receiver, resets the approval, and accepts only the measured frxUSD balance increase above the quote-relative minimum.[15] The preview includes the custodian's governance-configurable mint fee and its 6-decimal USDC to 18-decimal frxUSD conversion. Cap exhaustion, a fee change, proxy behavior change, or any external revert fails atomically. This operation cannot be reversed into redemption by swapping its token endpoints; contraction must use an independently approved liquid route.

No normal route step accepts arbitrary calldata. Additional venue types require a code change or a separately audited typed adapter. This restriction applies to permissionless execution paths, not the governance owner's separate `execute()` escape hatch.

### Separate directional paths

Downstream expansion and yield contraction paths are configured separately. V3 must not assume that the reverse path has the same venue, cost, liquidity, endpoint, or safety parameters. Undeployed-backing contraction uses the reverse direction of the designated target AMM and does not depend on either downstream path.

Example expansion path:

```text
USDT --CurveSwap(3pool)--> DAI
DAI --DaiUsdsConverter(0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A)--> USDS
USDS --ERC4626Deposit(sUSDS)--> sUSDS
```

The terminal action is route data, not a hardcoded deposit performed after the route. A frxUSD-facing deployment may instead use:

```text
frxUSD --CurveSwap(frxUSD/sfrxUSD)--> sfrxUSD
```

In both cases the complete downstream route ends in the deployment's fixed yield-bearing token. For sUSDS the terminal adapter is an ERC-4626 deposit; for sfrxUSD it is a swap because direct deposits are disabled.[13]

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
4. The expansion path has a distinguished terminal yield-acquisition step whose input is `backingAsset` and measured output is exactly `yieldToken`; its `kind` and `venue` are encoded in the route.
5. The yield contraction path has a distinguished first unwind step whose input is `yieldToken` and output is `backingAsset`; its action is independently encoded and need not be the inverse call type of the acquisition step.
6. A Curve step's pool contains both configured tokens.
7. A `DaiUsdsConverter` step is exactly DAI-to-USDS or USDS-to-DAI according to the venue's `dai()` and `usds()` getters, uses V3 as receiver, has `executionBufferBps == 0`, and must produce a measured 1:1 native-unit output.
8. An ERC-4626 deposit step uses `vault.asset() == tokenIn` and the vault share token as `tokenOut`.
9. An ERC-4626 redeem step uses the vault share token as `tokenIn` and `vault.asset()` as `tokenOut`.
10. A `FrxUsdMint` step uses zero indices, `venue.asset() == tokenIn`, and `venue.frxUSD() == tokenOut`; only the USDC-to-frxUSD mint direction is represented.
11. Every `executionBufferBps` is no greater than `10_000`.
12. The downstream path's `maxRouteLossBps` is no greater than `10_000` and is committed with the path.
13. No venue, token, or endpoint is zero.

Curve steps also carry explicit signed pool indices. Governance supplies them and V3 validates `coins(poolIndexIn) == tokenIn` and `coins(poolIndexOut) == tokenOut`; the indices must be distinct and non-negative. Non-Curve steps require both index fields to be zero. The wire-level `kind` field is encoded as a `uint256` constrained to the five listed `StepKind` values because the Vyper implementation does not expose a Solidity enum type in its ABI.

The target AMM and route venues may be replaced, but `targetAsset`, `backingAsset`, and `yieldToken` cannot change. Every updated path must preserve the deployment's fixed endpoints, so governance cannot leave active paths, `undeployedBacking` accounting, or contraction endpoints mismatched. V3 does not append an implicit vault deposit after the configured expansion path: successful execution is complete only when the route itself has delivered measured `yieldToken` units to V3.

Vyper `0.3.10` requires a compile-time bound for dynamic arrays and loops. Each directional path is therefore limited to `16` typed steps. This is an implementation-safety bound rather than an economic throttle; it keeps validation and execution statically bounded while leaving ample room for the intended three-step USDT-to-sUSDS route. Governance remains responsible for configuring a path whose actual gas cost fits `minDownstreamAttemptGas`. An expensive downstream path can make the downstream branch unusable, but it cannot compromise fallback accounting: the isolated branch fails and expansion retains the target asset.

### Path governance

Path replacement is a privileged operation capable of directing the protocol's full conversion flow. The DAO's seven-day voting period already supplies the public review window, so V3 does not add a second contract-level timelock:

```solidity
function setPaths(
    RouteStep[] calldata newExpansionSteps,
    uint256 newExpansionMaxRouteLossBps,
    RouteStep[] calldata newContractionSteps
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

`contractViaAmm()` executes the stored contraction path through the same bounded typed executor. Its first measured step consumes the fixed yield token and its last measured step produces crvUSD. Curve steps enforce `get_dy()`-relative minima, the canonical converter requires exact one-for-one native-unit output, and ERC-4626 deposit/redeem or frxUSD mint steps enforce their respective preview-relative minima. Any failed step, non-exact top-level yield spend, incorrect final crvUSD delta, insufficient post-reward margin, or principal-invariant failure reverts the complete transaction and all temporary approvals.

After a target-to-yield route completes, V3 compares the capped target-oracle value of the normalized target input with the trusted backing-asset value of measured final yield-token units and enforces `downstreamExpansionPath.maxRouteLossBps`. Preview and execution use the same source valuation. In a new expansion, failure of that check reverts the isolated branch and selects target-only fallback. In `deployUndeployedBacking()`, which deploys already-accounted target backing rather than a newly oracle-gated expansion receipt, the maintenance accounting remains nominal; failure reverts the call and leaves the target backing unchanged.

### Exact-input routing and route-defined yield handling

The configurable paths are exact-input. Expansion routes the keeper's exact crvUSD amount, later deployment routes an exact target amount, and keeper contraction routes an exact target amount or yield-token amount. Each route step measures output and enforces a protocol-calculated `minOut`; none needs a generic exact-output swap adapter. Direct buyback executes no route and always transfers a protocol-sized amount of the fixed `yieldToken` directly to the caller; it never consumes `undeployedBacking`.

Yield acquisition and keeper unwind follow their configured step kinds. An ERC-4626 deployment may use `deposit()` and `redeem()`. A non-depositable token such as sfrxUSD may instead be acquired and unwound through typed Curve swaps while still using its read-only conversion interface for trusted accounting. Direct buyback avoids both cases by returning the fixed final yield-bearing token itself.

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

Fallback contraction applies ordinary minimum and maximum limits to either requested target amount or requested yield-token units and their trusted backing value. The contract executes every requested amount exactly or reverts; it does not silently resize the transaction. Fallback expansion has no separate undeployed-backing cap: total target exposure remains bounded by `maxDeployedCrvUsd`, available Factory inventory, and the amount actually deployed.

The keeper can use `previewExpansion(amount)` or `previewKeeperBuyback(yieldTokenAmount)` offchain to select an economically useful amount. Onchain, V3 still calculates every intermediate minimum, profit-share reward, and final post-reward margin. A keeper-supplied amount can cause its own transaction to revert but cannot make an unsafe amount execute.

Under-sizing may leave a second profitable action available, but percentage-only compensation does not increase the aggregate configured share merely because one opportunity is split across calls. Token rounding and changing AMM execution can alter exact results, and each call must independently leave V3 with its configured post-reward margin and pay its own gas. `minExpansionAmount` blocks true dust without adding quote probes or a full-path search.

`minExpansionAmount` remains important because a successful expansion resets the global contraction timer. Its initial value is `10_000e18` crvUSD. Independently, one global leaky bucket per keeper covers every increase to `deployedCrvUsd`, including `expand()` and `claimSurplus()`. Maximum pressure is `5%` of `maxDeployedCrvUsd`; pressure refills linearly to zero over `300` seconds. All calls and callers share it, transaction splitting cannot bypass it, contraction does not refund it, and a reverted transaction consumes no pressure. Updating policy, ceilings, factory defaults, oracle adapters, or floors does not reset pressure.

## Profitability and execution controls

Realized profitability under the trusted-backing convention is the primary execution gate. V3 should not copy V2-style spot/EMA proximity checks onto the target crvUSD AMM: a sudden crvUSD price spike creates the exact expansion opportunity V3 should capture. Requiring spot to remain close to EMA would suppress the intended trade.

Expansion therefore has two authoritative realized postconditions. A fully deployed branch uses the approved backing-asset units represented by the final yield token after the complete downstream route and keeper reward. A fallback branch uses only the accounted target asset actually retained after its keeper reward. A downstream preview is never counted as backing. Each approved stablecoin unit is treated as one dollar without consulting the target AMM spot.

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
-> USDS through the canonical DaiUsds converter
-> sUSDS deposit
```

more attractive at the consolidated protocol level than its gross output haircut suggests. The DAI-to-USDS conversion and USDS-to-sUSDS deposit do not add percentage swap fees, so most of the explicit route fee is recycled to the DAO.

V3 must nevertheless enforce its hard profitability condition using only assets actually received by V3. Unclaimed 3pool admin fees are not held by the PegKeeper, are not atomically available as backing, and cannot be counted toward combined `trustedBackingValue`. Otherwise V3 could pass a consolidated-profit test while leaving its own backing position short.

The fully deployed and fallback views are therefore:

```text
Gross entry profit used for keeper compensation
    = normalized backing asset received before terminal yield acquisition
    - crvUSD deployed

Fallback gross profit used for keeper compensation
    = normalized target asset received from the target AMM
    - crvUSD deployed

Fully deployed PegKeeper-local net profit
    = trusted backing value of final yield-token units
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

For a successful full-route expansion, V3 calculates the keeper reward from the realized backing-asset output immediately before the terminal yield-acquisition step:

```text
require normalize(backingAssetOut) >= crvUsdSold
grossEntryProfit = normalize(backingAssetOut) - crvUsdSold

keeperRewardValue
    = floor(grossEntryProfit * keeperProfitShareBps / 10_000)

keeperRewardTokens = denormalizeDown(keeperRewardValue)
backingAssetToRoute = backingAssetOut - keeperRewardTokens
```

`backingAssetOut` is the actual balance delta after the crvUSD-to-target AMM swap and every successful downstream conversion before the terminal yield-acquisition step. Target-AMM fees and all preceding route fees, converter loss, and slippage are therefore already deducted before `grossEntryProfit` and the reward are calculated. The configured terminal step then consumes `backingAssetToRoute`; its own fee, loss, slippage, and rounding are captured by the measured yield-token delta, valued through `convertToAssets()`, and cannot weaken the final backing floor.

If normalized backing output does not exceed crvUSD sold, gross entry profit and keeper compensation are zero and the transaction cannot pass any positive entry margin. Reward conversion rounds down so decimal normalization cannot overpay the keeper.

V3 applies an execution-quality floor separately from the hard trusted-profit floor. For every typed route step, it quotes the actual measured step input immediately before execution through that venue's canonical view method:

```text
quotedOut = quote(step, actualStepInput)

stepMinOut = floor(
    quotedOut * (10_000 - step.executionBufferBps) / 10_000
)

actualStepOut >= stepMinOut
```

Examples are Curve `get_dy()` for any swap—including a terminal frxUSD-to-sfrxUSD swap—the canonical DaiUsds converter's fixed `amountIn` quote, and ERC-4626 `previewDeposit()` when the configured terminal step is a vault deposit. Actual output is always measured by balance delta. Governance configures `executionBufferBps` per step, bounded only by the `10_000` bps denominator; DaiUsds conversion and standards-compliant same-transaction ERC-4626 deposits use zero, while swap steps receive a benchmarked nonzero allowance. The separately stored target AMM configuration carries its own `executionBufferBps` and uses the same quote/minimum equation for the initial crvUSD-to-target swap.

After all steps, V3 independently enforces:

```text
normalizeDown(yieldToken.convertToAssets(actualYieldTokenReceived))
    >= crvUsdSold
       + crvUsdSold * entryMinProfitPpm / 1_000_000
```

The quote-relative step floor prevents a favorable upstream spread from masking unnecessarily poor downstream execution. The final trusted-value floor prevents local route economics from consuming principal, while the separate global backing invariant protects the complete position. `downstreamExpansionPath.maxRouteLossBps` separately limits normalized route-wide conversion loss. These checks protect different failure modes and do not require a duplicate global `maxExecutionSlippageBps` parameter.

The fallback branch separately enforces the target AMM's quote-relative output floor, then applies its realized post-reward target-backing floor. The full-route trusted-value postcondition is not reused for fallback.

### Expansion postconditions

```text
fully deployed:
normalizeDown(yieldToken.convertToAssets(yieldTokenReceived))
>= crvUsdSold + crvUsdSold * entryMinProfitPpm / 1_000_000

fallback:
normalize(targetAssetRetainedAfterReward)
>= crvUsdSold + crvUsdSold * entryMinProfitPpm / 1_000_000

complete state:
trustedBackingValue >= deployedCrvUsd
```

### Direct buyback postcondition

```text
crvUsdReceived
>= trustedYieldValuePaid
 + selectedExitMargin
```

### Keeper buyback postcondition

```text
trustedValueRemoved
    = trustedBackingValue(selectedBackingSpent)

trustedBackingAfter
    = trustedBackingBefore - trustedValueRemoved

solvencyRecovery
    = max(deployedCrvUsdBefore - trustedBackingAfter, 0)

principalRecovery
    = max(trustedValueRemoved, solvencyRecovery)

grossExitProfit
    = max(crvUsdReceived - principalRecovery, 0)

keeperReward
    = floor(grossExitProfit * keeperProfitShareBps / 10_000)

crvUsdReceived - keeperReward
>= trustedValueRemoved
 + selectedExitMargin

trustedBackingValueAfter >= deployedCrvUsdAfter
```

Reward-token conversion and every trusted-value normalization round down. Direct buyback sizes the yield-token payout downward through `convertToShares()` and transfers it directly, while expansion and surplus solvency value explicitly accounted post-action yield-token units downward through `convertToAssets()`.

## Asymmetric timing and carry

Entry and exit should not have symmetric urgency.

### Entry policy

Expansion should remain immediately callable with no time delay:

```text
selectedBranchBackingRetainedAfterReward
    >= crvUsdSold
       + crvUsdSold * entryMinProfitPpm / 1_000_000
```

The initial configuration is `entryMinProfitPpm = 10`, equal to `0.1 bps`. The parameter is an unsigned integer bounded by `normalExitMinProfitPpm`; zero permits local break-even after realized route costs, terminal rounding, and keeper reward, but no value can authorize a local loss. Every completed expansion also requires total `trustedBackingValue >= deployedCrvUsd`. Later target-to-yield conversion remains optional and may spend only existing surplus.

Expansion should not wait for a timer, EMA, accumulated yield, or downstream route recovery. If the target-AMM leg can complete into acceptable target backing, delaying it gives away the above-peg opportunity.

### Exit policy

Routine contraction in the mature deployment state requires a governance-set `normalExitMinProfitPpm`. While V3 remains in the young deployment state, contraction must instead satisfy the larger `earlyExitMinProfitPpm`:

```text
selectedExitMarginPpm =
    block.timestamp < lastExpansionAt + minDeploymentTime
        ? earlyExitMinProfitPpm
        : normalExitMinProfitPpm

earlyExitMinProfitPpm > normalExitMinProfitPpm
normalExitMinProfitPpm >= entryMinProfitPpm

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

The global timer also means a sequence of legitimate profitable expansions extends the normal-exit delay for the whole position. That is accepted as part of the anti-churn policy. Later undeployed backing deployment does not reset this supply timer, so newly created yield-token units are not guaranteed a separate carry interval.

At `10,000` crvUSD and the initial `0.1 bps` entry margin, the minimum guaranteed retained protocol margin is only `0.10` normalized dollar units. The attacker's total cost is higher because it also bears AMM fees, slippage, and the manipulated round trip, but the absolute threshold does not make timer resets expensive by itself. The higher early-exit margin prevents a hard lock. Governance should monitor reset behavior and can raise `minExpansionAmount` if repeated resets become too cheap relative to deployed capacity.

## Open keeper and flash-liquidity model

Open keepers are an explicit design choice. V3 cannot prevent an account from using flash liquidity to move the target AMM, call `expand()` or `contractViaAmm()`, and reverse the market trade afterward.

The entry-floor and exit-profit postconditions do not prevent that behavior and do not guarantee V3 captures every available basis point of market spread. They guarantee that any completed action satisfies its configured post-reward floor under the approved-backing-at-par convention, while every expansion still preserves `trustedBackingValue >= deployedCrvUsd`. A manipulator may capture residual spread, but cannot force V3 to complete below those checks unless the fixed yield token's accounting interface itself is compromised. A real depeg of an approved backing asset remains outside nominal accounting.

The execution-quality floor prevents the configured route from performing materially worse than the quote visible when V3 executes. It cannot detect a malicious keeper that moved the AMM before the V3 transaction and restores it afterward. Preventing that completely would require a trusted price reference, auction, private order flow, or keeper whitelist. Those mechanisms are outside the current open-keeper design.

The practical V3 policy is therefore:

1. Accept that open execution can leak some transient market spread.
2. Require expansion to satisfy the configured unsigned entry floor after route costs and keeper reward, while preserving the global backing invariant.
3. Require contraction to achieve the selected normal or early exit margin after any keeper reward.
4. Bound transaction size and reject dust-sized reward farming.
5. Never trust keeper-provided minimum outputs.

### V2 comparison

V2 is not unprotected. Its regulator checks pool spot against the pool oracle for spam-attack protection, checks the aggregate crvUSD price and other registered pools, and can disable either direction. `PegKeeperV2` also uses a 12-second action delay, adjusts only one fifth of the observed imbalance per update, and reverts unless LP-accounting profit increases with `peg unprofitable`.

Those controls reduce simple one-block manipulation and prevent an immediately unprofitable V2 update. They do not prove that V2 captures all available spread or eliminate multi-transaction market manipulation. V3 keeps the economically necessary post-trade profit condition but does not copy a target-AMM spot/EMA proximity check that would suppress the upward price spike V3 is meant to monetize.

V2's percentage caller payment is also taken from positive incremental LP-accounting profit. It may pay materially more than gas cost during an unusually favorable update, but that is not a principal-safety failure or a primary reason for V3. V3 retains percentage-only compensation while replacing LP-accounting deltas with realized branch profit and complete post-reward principal and margin checks.

## Keeper compensation

Keeper compensation is a percentage of realized gross profit:

```text
keeperReward
    = floor(grossProfit * keeperProfitShareBps / 10_000)
```

The initial governance-changeable setting is:

```text
keeperProfitShareBps = 3_000  // 30%
```

At the initial entry floor, V3 must retain `0.1 bps` after the `30%` reward. The minimum gross-profit rate is therefore `0.1 / 70% = 0.142857 bps`.

For the initial `10,000 crvUSD` minimum expansion, a profitable branch executing at exactly that floor realizes approximately `$0.142857` gross profit, pays approximately `$0.042857` to the keeper, and retains `$0.10` for V3. The minimum action size is therefore an anti-dust and timer-reset bound, not a guarantee that the reward covers mainnet gas; keepers act only when actual size and spread make the percentage reward worthwhile.

For fully deployed expansion, `grossProfit` used to size the keeper reward is normalized backing asset received immediately before the terminal yield-acquisition step minus crvUSD sold, and the keeper is paid in that backing asset. The terminal step's economics are then included in the authoritative post-reward final-yield backing floor. For fallback expansion, gross profit is normalized target asset actually received after target-AMM fees and slippage minus crvUSD sold, and the keeper is paid in target asset before the remainder enters `undeployedBacking`. A failed downstream subcall rolls back its token conversions, so it changes caller gas cost but does not leave partial downstream route loss in V3. Reward-token conversion rounds down.

For either keeper contraction source:

```text
principalRecovery
    = max(
        trustedValueRemoved,
        max(deployedCrvUsdBefore - trustedBackingAfter, 0)
    )

grossProfit
    = max(crvUsdReceived - principalRecovery, 0)
```

The second principal term matters only when backing is impaired. It prevents deficit repair from being labeled rewardable profit. The keeper receives the configured percentage of this realized `grossProfit` in crvUSD.

One `expand()` call pays one branch reward. It does not pay separate rewards for the first crvUSD-to-target swap and the downstream target-to-yield conversion. Direct buyback and `deployUndeployedBacking()` callers receive no percentage reward. No explicit gas reimbursement is added to any branch; a keeper decides whether the realized percentage reward covers transaction gas and execution risk.

There is no flat reward ceiling. A per-call ceiling would not bound one economic opportunity because a keeper can split it across multiple transactions. It would instead penalize efficient large actions and encourage extra calls. Percentage-only compensation is split-invariant before token rounding, changing AMM execution, or a changing solvency-recovery basis: the keeper receives the configured share of aggregate realized gross profit, while each successful call independently leaves V3 with principal plus its configured post-reward margin. Governance controls keeper rent directly through `keeperProfitShareBps`.

The reward rules are:

1. `keeperProfitShareBps` cannot exceed `10_000` and should be materially lower so the protocol normally retains immediate execution profit.
2. The reward is calculated from realized balance deltas, never a preview or caller-supplied value.
3. The reward is paid only after the route has produced positive gross profit and the complete state transition can satisfy the post-reward protocol margin.
4. The reward is paid to `msg.sender`; callers cannot supply an arbitrary beneficiary.
5. Decimal conversion rounds the reward down.
6. The reward cannot consume principal or the configured protocol margin.

No fixed stipend or time-refilling credit system is paid. A keeper decides whether its percentage reward is worth its gas and execution risk. The protocol favors simple repeated profitable execution over a reward budget that may be depleted during a clustered peg event.

## Fee receiver and surplus

V3 uses one fungible surplus value rather than separate onchain buckets for yield and execution spread:

```text
protocolSurplus
    = max(trustedBackingValue - deployedCrvUsd, 0)
```

Here `trustedBackingValue` is the normalized value of accounted `targetAsset` plus the current `backingAsset`-equivalent value represented by `accountedYieldTokenUnits`. It uses the fixed yield token's current `convertToAssets()` value, not merely historical acquisition cost, so accrued yield is included. For the USDT/sUSDS example, those two components are accounted USDT and the current USDS-equivalent value of accounted sUSDS units.

Yield-token appreciation, retained expansion or contraction profit, and route costs all change the same combined trusted-backing value. Tracking their provenance separately would require persistent cost-basis accounting across mixed backing, later deployment, independent backing-source outflows, yield-token exchange-rate appreciation, and fee claims, without strengthening the principal invariant.

V3 realizes that surplus for governance by transferring idle crvUSD to the configured FeeSplitter and increasing `deployedCrvUsd` by exactly the amount transferred. It does not remove the configured target asset, backing asset, or yield token from the backing portfolio. Let `F` be the crvUSD fee payment:

```text
trustedBackingAfter = trustedBackingBefore
deployedCrvUsdAfter = deployedCrvUsdBefore + F

surplusAfter
    = trustedBackingAfter - deployedCrvUsdAfter
    = surplusBefore - F
```

The fee payment therefore converts fungible backing surplus into additional fully backed externalized crvUSD. It leaves the backing invested while consuming the same amount of surplus through the liability side of the accounting.

```solidity
function claimSurplus(uint256 maxCrvUsdAmount)
    external
    returns (uint256 crvUsdTransferred);
```

The function is permissionless, but the caller selects only a maximum amount. The recipient is fixed by governance and the function uses no swap route. V3 calculates:

```text
eligibleIdleCrvUsd
    = min(
        actual crvUSD balance,
        max(Factory allocation - deployedCrvUsd, 0)
      )

crvUsdTransferred
    = min(
        maxCrvUsdAmount,
        protocolSurplus,
        eligibleIdleCrvUsd,
        maxDeployedCrvUsd - deployedCrvUsd
      )
```

Execution then:

```text
1. Require allExecutionPaused == false and expansionPaused == false.
2. Snapshot trustedBackingValue and deployedCrvUsd.
3. Calculate crvUsdTransferred from protocol state and revert if it is zero.
4. Increase deployedCrvUsd by crvUsdTransferred.
5. Transfer that exact idle crvUSD amount to the configured FeeSplitter.
6. Require deployedCrvUsd <= Factory allocation and maxDeployedCrvUsd.
7. Require trustedBackingValue >= deployedCrvUsd.
8. Verify the actual crvUSD balance delta equals crvUsdTransferred.
```

`deployedCrvUsd` consequently means all accounted crvUSD externalized from V3 and requiring external backing, not only crvUSD sold in expansion. The amount increases through either an AMM expansion or a FeeSplitter payout and decreases when direct buyback or keeper contraction returns crvUSD to V3. The sum of eligible idle inventory and externalized exposure is conserved by the fee transfer; arbitrary crvUSD donations cannot increase the Factory-allocation or exposure-cap bounds.

The fee claim does not reset `lastExpansionAt`. Resetting the global maturity timer for a fee transfer would let permissionless dust claims delay normal contraction. The claim is nevertheless disabled by `expansionPaused` because it increases externalized crvUSD exposure. This preserves `expansionPaused = true` as the complete contraction-only wind-down switch.

The configured initial receiver is Curve's crvUSD `FeeSplitter`. Its dispatch logic reads and distributes its crvUSD balance, so directly transferred V3 fees join the same crvUSD-denominated revenue flow as ControllerFactory mint-market fees.[10] At Ethereum block `25,851,058`, ControllerFactory's `fee_receiver()` was the FeeSplitter at `0x2dFd89449faff8a532790667baB21cF733C064f2`. Its two configured receiver weights were `5,000` each: `0xE8d1E2531761406Af1615A6764B0d5fF52736F56` and `0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00`; the latter FeeCollector was also the excess receiver.[10]

V2 uses a different revenue path despite being part of the crvUSD system. Its `withdraw_profit()` transfers pool LP tokens directly to `regulator.fee_receiver()` rather than converting or sending crvUSD.[8] At Ethereum block `25,851,076`, all five live V2 PegKeepers referenced by this repository used regulator `0x36a04CAffc681fa179558B2Aaba30395CDdd855f`, whose receiver was the generic FeeCollector at `0xa2Bcd1a4Efbd04B63cd03f5aFf2561106ebCCE00`; the collector's CowSwap burner converts source fee tokens toward its crvUSD target.[9][11] V2 therefore bypasses the FeeSplitter, while V3 deliberately reaches it by paying crvUSD directly. Governance must not change the shared regulator receiver to the FeeSplitter merely to serve V3: that would also redirect remaining V2 LP-token profit into a receiver whose normal distribution path expects crvUSD.

The receiver update surface exists only on `PegKeeperV3Factory` through its validated shared-default update. V3 itself has no receiver storage, setter, or receiver-update event. The factory rejects a zero receiver. Normal surplus claims always transfer crvUSD, so governance must point the factory to a contract whose accounting and distribution flow accept direct crvUSD transfers. Changing the shared receiver does not change the exposure or backing equations.

## Curve compatibility

V3 is asymmetric. The first version does not need a full StableSwap invariant or LP token.

The direct buyback side may expose Curve-style two-coin methods where useful for routing:

```solidity
function coins(uint256 index) external view returns (address);
function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
```

Only the crvUSD-to-yield-token direction is directly executable. The advertised pair is fixed for the V3 deployment even while target asset remains in `undeployedBacking`. Upward expansion and target-asset cleanup remain keeper-driven through their designated routes. Unsupported directions must return no quote or revert consistently; exact router compatibility requires targeted integration testing before this surface is finalized.

V3 should not publish fake LP balances, virtual prices, or TVL merely to resemble StableSwap.

## Governance and emergency controls

Required controls:

- pause expansion;
- pause undeployed backing deployment without pausing target-only expansion;
- pause direct buyback;
- pause keeper buyback;
- lower `maxDeployedCrvUsd` to stop further exposure growth;
- governance updates to `maxDeployedCrvUsd`;
- governance replacement of the target AMM and atomic replacement of both paths while preserving fixed token endpoints;
- shared `PegKeeperV3Factory.fee_receiver()` updates independent of any regulator receiver;
- governance updates to `minDeploymentTime`, `minExpansionAmount`, the entry and exit margin parameters, `keeperProfitShareBps`, `targetAmmExecutionBufferBps`, `minDownstreamAttemptGas`, and `fallbackSettlementGasReserve`;
- approval revocation for retired venues;
- owner-only arbitrary external execution for urgent recovery;
- expansion pause for contraction-only slow wind-down.

Setting `expansionPaused = true` is the complete slow-wind-down switch. It blocks new crvUSD sales and crvUSD surplus claims because both increase externalized exposure, but it does not disable direct buyback or either keeper contraction path. Reacquired crvUSD remains idle and governance may lower the Factory ceiling to burn it. V3 does not need a separate global-shutdown state or a prescribed migration state machine.

The target AMM is a replaceable venue while its token endpoints remain fixed:

```solidity
function set_target_amm(address newTargetAmm, uint256 executionBufferBps) external;
```

The owner-only call requires the replacement's two `coins()` entries to be exactly `crvUSD` and `targetAsset`, discovers either valid index order, bounds the target-AMM execution buffer to `10_000 bps`, and updates the venue, indices, and buffer atomically. It cannot change either token. Expansion and undeployed-backing contraction both read the current venue and discovered indices. The directional typed paths do not store or depend on the target-AMM address, so replacing this fixed-pair venue separately from `setPaths()` cannot create a token-endpoint mismatch; a governance proposal may still invoke both setters in one execution when changing the whole venue bundle.

The implemented mutable policy surface is one atomic owner call rather than seven independent setters:

```solidity
function set_policy(
    uint256 entryMinProfitPpm,
    uint256 normalExitMinProfitPpm,
    uint256 earlyExitMinProfitPpm,
    uint256 keeperProfitShareBps,
    uint256 minDeploymentTime,
    uint256 minExpansionAmount,
    uint256 maxDeployedCrvUsd
) external;
```

It requires `earlyExitMinProfitPpm > normalExitMinProfitPpm >= entryMinProfitPpm`, bounds both unsigned exit margins to at most `1_000_000 ppm`, bounds the keeper share to `10_000 bps`, and rejects zero minimum expansion or zero configured exposure capacity. Zero entry margin, zero keeper compensation, and zero maturity delay remain valid governance policies. `trustedBackingValue >= deployedCrvUsd` remains mandatory. Governance may lower `maxDeployedCrvUsd` below current exposure to stop growth immediately; this does not rewrite existing exposure and does not disable contraction.

Governance and the distinct pause-only emergency role are managed only by `PegKeeperV3Factory`. A validated factory update rejects zero or overlapping roles and takes effect immediately for every V3 that reads the factory getters. V3 contains no role storage, role setter, or role-update event. Venue approvals are exact and normally reset to zero in the same conversion. If a non-standard venue leaves an approval requiring manual cleanup, the owner can revoke it through the existing bounded `execute()` escape hatch; no redundant approval-management surface is required.

## Owner execute escape hatch

The governance owner must be able to call any target with owner-selected calldata, subject only to the implementation's explicit dynamic-bytes bound:

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

`execute()` performs a normal external `call`, not `delegatecall`. It bubbles the target's revert data and returns the target's return data. It has no target allowlist because an allowlist would defeat its role as a general recovery mechanism. The Vyper implementation accepts at most `65,535` calldata bytes and captures at most `65,535` return-data bytes per call; a larger successful return is truncated to that capture bound. This explicit representation bound is large enough for recovery payloads while preserving a finite worst case; a larger input operation must use a governance-approved helper contract or multiple calls.

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
    uint256 yieldTokenReceived,
    uint256 grossProfit,
    uint256 keeperReward,
    uint256 backingRetained,
    bool deployedToYield,
    uint256 unlockTime
);

event UndeployedBackingDeployed(
    address indexed caller,
    uint256 targetSpent,
    uint256 yieldTokenReceived,
    uint256 trustedValueReceived,
    uint256 conversionCost
);

event DirectBuyback(
    address indexed caller,
    uint256 crvUsdReceived,
    uint256 yieldTokenPaid,
    bool earlyExit
);

event KeeperBuyback(
    address indexed keeper,
    address backingToken,
    uint256 backingSpent,
    uint256 yieldTokenSpent,
    uint256 crvUsdReceived,
    uint256 grossProfit,
    uint256 keeperReward,
    bool earlyExit
);

event PathsUpdated(
    bytes32 indexed expansionPathHash,
    bytes32 indexed contractionPathHash,
    uint256 expansionMaxRouteLossBps
);
event ExpansionConfigUpdated(
    uint256 targetAmmExecutionBufferBps,
    uint256 minDownstreamAttemptGas,
    uint256 fallbackSettlementGasReserve
);
event TargetAmmUpdated(
    address indexed oldTargetAmm,
    address indexed newTargetAmm,
    uint256 crvUsdIndex,
    uint256 targetIndex,
    uint256 executionBufferBps
);
event DirectionPaused(uint256 indexed direction, bool paused);
event SurplusClaimed(
    address indexed caller,
    address indexed receiver,
    uint256 crvUsdTransferred,
    uint256 deployedCrvUsdAfter
);
event Executed(
    address indexed target,
    uint256 value,
    bytes4 indexed selector,
    bytes32 dataHash
);
```

## Invariants

1. Expansion and surplus claims cannot increase `deployedCrvUsd` above the then-current Factory allocation or configured capacity. Governance may lower either ceiling below existing exposure without rewriting `deployedCrvUsd`; while that condition persists, exposure growth remains blocked and contraction paths remain available to reduce it.
2. Expansion and surplus claims cannot spend more eligible idle crvUSD than V3 owns.
3. Contraction cannot reacquire more than the amount counted as deployed without explicit surplus accounting.
4. `undeployedBacking` changes only through measured fallback retention, measured spending, successful typed deployment, or governance reconciliation.
5. Unsolicited token transfers never increase accounted backing automatically.
6. Keeper rewards equal the configured percentage of realized gross profit for the selected branch and are rounded down.
7. Keeper rewards and fee claims cannot consume required principal; a fee claim increases `deployedCrvUsd` only by an equal or smaller amount of protocol surplus.
8. Caller-supplied minimums can only make execution stricter.
9. Callers cannot choose routes, venues, output recipients, or reward recipients.
10. A V3 surplus claim always uses its deployment factory's current `fee_receiver()`; changing the V2 regulator receiver cannot redirect it.
11. Active paths always connect the configured endpoints.
12. Successful downstream execution leaves no material unaccounted intermediate-token balance.
13. A failed isolated downstream attempt leaves the target input in V3 and cannot partially consume it.
14. Deployment of undeployed backing cannot consume more than available surplus or exceed its path-configured loss bound.
15. Deployment of undeployed backing never changes `deployedCrvUsd` or `lastExpansionAt`.
16. Disabling expansion also disables surplus claims but never disables direct buyback or the governance-approved contraction paths.
17. A path update preserves the deployment's fixed target asset, backing asset, and final yield token.
18. Every external conversion is non-reentrant and uses measured balance deltas.
19. Only the governance owner can execute arbitrary targets or calldata.
20. Keeper-supplied parameters cannot weaken protocol-calculated output or profit floors.
21. Combined trusted backing remaining after rewards, later deployment costs, and crvUSD fee claims is never below `deployedCrvUsd`.
22. Expansion is not delayed when either approved branch satisfies its entry floor.
23. `lastExpansionAt` changes only after a successful expansion of at least `minExpansionAmount`.
24. Contraction during the young deployment state always satisfies `earlyExitMinProfitPpm`.
25. A failed or below-minimum expansion cannot extend the normal-exit timer.
26. Direct buyback transfers only the fixed `yieldToken`; it never consumes `undeployedBacking`, changes output-token identity, or executes a yield-unwind route.
27. Trusted yield valuation uses the fixed yield token's `convertToAssets()` and downward normalization; it never rounds backing upward.
28. Any action that removes yield-token units computes trusted value spent from the complete pre/post accounted positions and actual deltas.
29. A fully deployed expansion succeeds only when the configured route itself ends with a measured balance increase in the fixed `yieldToken`; V3 performs no implicit post-route deposit.
30. The terminal yield-acquisition step and first yield-unwind step are typed route data with fixed tokens, venues, protocol minima, and V3 as recipient.
31. `accountedYieldTokenUnits` changes only by measured protocol receipts and outflows, never exceeds V3's actual yield-token balance, and excludes unsolicited transfers.
32. Yield-token contraction spends exactly the requested accounted units, values the outflow from the complete pre/post accounted positions, and cannot remove trusted value greater than current deployed exposure.
33. Successful yield-token contraction reduces `deployedCrvUsd` only by net retained crvUSD, capped at current exposure, and never changes `lastExpansionAt`.

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

Target-AMM spot quotes, route previews, and yield-token conversion functions can be manipulated or stale. V3 does not use the target-AMM spot as the dollar valuation source. It relies on actual balance deltas, the fixed yield token's conversion functions, final nominal-profit assertions, deadlines, available inventory, and the total deployed-exposure bound. Governance is responsible for approving a final yield token whose unit-to-backing accounting is acceptable.

### MEV

Keeper swaps through the external target AMM can be surrounded by flash-liquidity trades. Internal minimums, post-trade profitability checks, available inventory, and `maxDeployedCrvUsd` prevent principal loss under the configured accounting but do not guarantee capture of all transient spread. This residual value leakage is accepted to preserve open keeper participation.

### Keeper under-sizing

A keeper may choose less than the maximum profitable amount and leave a second opportunity available. Percentage-only compensation does not increase its aggregate configured share merely because the opportunity is split, although token rounding and changing AMM execution can alter exact results. The keeper bears extra gas, and every completed action must leave V3 with its configured post-reward margin. `minExpansionAmount`, the total deployment bound, and open competition are considered sufficient for the initial design. Under-sizing can reduce immediate peg effect, but it cannot make an uneconomic action pass.

### Exit-delay liveness

A strict holding period could deadlock downward peg support during an actual crisis. V3 therefore does not impose an absolute lock: the timer selects a higher early-exit margin instead of disabling contraction. The global timer can be reset only by a successful minimum-sized expansion that pays its own execution economics, and a sufficiently distressed realized exit remains executable during the timer. Emergency governance and owner recovery remain separate last-resort paths.

### Governance route power

An updatable path can direct all future flows into a malicious venue. The DAO's seven-day vote, typed steps, endpoint validation, atomic compatible-bundle updates, exact approvals, and emergency directional pauses limit this risk. V3 deliberately does not duplicate the DAO review period with another contract-level delay.

### Governance execute power

The owner can intentionally bypass typed routes and move or approve assets through `execute()`. This is an explicit trust assumption, not a permissionless surface. A compromised owner can drain V3, but the designated DAO already controls crvUSD minting and the protocol configuration that determines V3's capacity. Ownership must not be delegated to a weaker hot-key or keeper role.

## Independent backing safety

### Mandatory independent backing adapters

Backing-quality checks are part of initial execution. Target and downstream adapters are mandatory, independent of the designated crvUSD execution AMM, and directional: target failure blocks expansion, while downstream failure selects target retention. Exposure-reducing contraction, slow wind-down, and owner recovery do not depend on successful oracle reads.

The launch Curve configuration uses opposite orientations of the USDC/USDT EMA for the USDC and USDT target checks. It uses frxUSD/sUSDS for frxUSD target health, the deeper sfrxUSD/frxUSD EMA for the frxUSD keeper's downstream share-health check, and the reverse sUSDS/frxUSD orientation of frxUSD/sUSDS for sUSDS backing health. These are contagion checks against governance-trusted stable assets, not mathematical proof of absolute USD parity. Governance must monitor pool liquidity, EMA behavior, reference-asset health, and correlated failures.

For either yield token, V3 converts held shares into underlying units with `convertToAssets()` and then applies the adapter's capped health multiplier. Favorable values are capped at par, preventing a share-price premium from being counted twice; an unfavorable share relationship applies a haircut. Typed-route slippage and measured-output guards remain independent of these oracle gates.

An alternative Chainlink adapter binds one canonical proxy feed, its decimals, and a mandatory maximum delay. Separate deployments directly wrap `frxusd-usd.data.eth` (`0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83`) and `usds-usd.data.eth` (`0xfF30586cD0F29eD462364C7e81375FC0C71219b1`). The proxy address stays immutable while Chainlink may rotate its underlying aggregator. The adapter rejects non-positive answers, zero or future timestamps, stale rounds, and `answeredInRound < roundId`. Chainlink lists a 0.5% deviation threshold and 24-hour heartbeat for frxUSD/USD, and a 0.3% deviation threshold and 24-hour heartbeat for USDS/USD. The adapter's provisional 26-hour maximum delay is a separate heartbeat-plus-grace policy that still requires governance approval. This alternative is not selected by the current proposal; governance must choose between Curve EMA and direct Chainlink proxy sources for the frxUSD and USDS checks.

## Remaining deployment decisions

The code and fixed route representation are complete. Governance still must approve deployment-specific numeric values:

- initial downstream-path `maxRouteLossBps` plus target-AMM and per-step `executionBufferBps` values, calibrated against the implemented venues;
- initial benchmarked numeric `minDownstreamAttemptGas` and `fallbackSettlementGasReserve` for the implemented downstream attempt;
- initial local maximum deployment capacity and Factory debt ceiling/allocation.

The initial release does not register a Curve-router adapter for the fixed `crvUSD`/`yieldToken` buyback edge. Direct buyback remains available only through the explicit `buyback()` interface, which returns the fixed yield token and preserves measured accounting. Router compatibility may be proposed later without expanding the initial release surface.

The release manifest, current-mainnet canary, reproducible deployment script, and ordered activation procedure are maintained in `deployments/mainnet/PegKeeperV3-release.json` and `docs/pegkeeper-v3-release-checklist.md`. Current target-pool choices, fixed yield endpoints, deterministic route candidates, fee layers, and pinned executable path-cost ladders are maintained separately in `docs/pegkeeper-v3-routing-and-path-costs.md`; those measurements are operational snapshots, not protocol invariants. Deployment and activation remain explicit governance/operator actions; the release package does not broadcast them.

## Sources

[1] https://github.com/resupplyfi/resupply/blob/3fcd20e8ce6bda0225b1f7424f8e25e76884020d/src/dao/TreasuryStableDiversification.sol — Resupply TreasuryStableDiversification path configuration
    > "function setTargets(Target[] calldata newTargets) external onlyOwner {"
    > "inputToken.forceApprove(target.swapPool, inputAmount);
        ICurveStableSwapPool(target.swapPool).exchange(assetIndex, targetIndex, inputAmount, minOut);
        inputToken.forceApprove(target.swapPool, 0);"
    > "uint256 received = target.token == inputToken
                ? swapInputAmount
                : _swapViaCurve(IERC20(inputToken), inputToken, target, swapInputAmount, minOut);"
    > "shares = _returnOrDeposit(target.token, target.vault, targetAmount);"
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
[12] https://eips.ethereum.org/EIPS/eip-4626 — ERC-4626 Tokenized Vaults standard
    > "MUST round down towards 0"
    > "MUST return as close to and no more than the exact amount of Vault shares that would be minted in a deposit call in the same transaction"
    > "MUST return as close to and no fewer than the exact amount of Vault shares that would be burned in a withdraw call in the same transaction"
[13] https://etherscan.io/address/0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6 — sfrxUSD live read-only conversion and disabled deposit state
    > "Ethereum block: 25851930
sfrxUSD proxy: 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6
asset()(address)=0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
convertToAssets(1e18)(uint256)=1207846223556964914
convertToShares(1e18)(uint256)=827919962406404468
maxDeposit(0x0000000000000000000000000000000000000001)(uint256)=0
previewDeposit(1e18)(uint256)=0"
[14] https://eth.blockscout.com/address/0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A?tab=contract — Sky DaiUsds canonical DAI/USDS converter
    > "function daiToUsds(address usr, uint256 wad) external {
        dai.transferFrom(msg.sender, address(this), wad);
        daiJoin.join(address(this), wad);
        usdsJoin.exit(usr, wad);
        emit DaiToUsds(msg.sender, usr, wad);
    }"
    > "function usdsToDai(address usr, uint256 wad) external {
        usds.transferFrom(msg.sender, address(this), wad);
        usdsJoin.join(address(this), wad);
        daiJoin.exit(usr, wad);
        emit UsdsToDai(msg.sender, usr, wad);
    }"
    > "Ethereum block: 25851930
DaiUsds converter: 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A
dai()(address)=0x6B175474E89094C44Da98b954EedeAC495271d0F
usds()(address)=0xdC035D45d973E3EC169d2276DDab16f1e407384F
daiJoin()(address)=0x9759A6Ac90977b93B58547b4A71c78317f391A28
usdsJoin()(address)=0x3C0f895007CA717Aa01c8693e59DF1e8C3777FEB
daiDecimals=18
usdsDecimals=18"
[15] https://eth.blockscout.com/address/0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c?tab=contract — Frax frxUSD USDC custodian proxy and verified implementation
    > "Ethereum block: 25857270
asset()(address)=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
frxUSD()(address)=0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
custodianTknDecimals()(uint8)=6
frxUSDDecimals()(uint8)=18
mintFee()(uint256)=0
mintCap()(uint256)=400000000000000000000000000
frxUSDMinted()(uint256)=255359360150313908124343598
maxDeposit(address)(uint256)=144640639849687"
    > "function previewDeposit(uint256 _assetsIn) public view returns (uint256 _sharesOut)"
    > "function deposit(uint256 _assetsIn, address _receiver) public virtual returns (uint256 _sharesOut)"
