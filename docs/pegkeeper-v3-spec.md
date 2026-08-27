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
6. Pay bounded keeper fees rather than an open-ended percentage of profit.
7. Keep expansion and fallback contraction open to any keeper without a whitelist or private-submission requirement.
8. Allow governance to replace broken or obsolete swap paths without replacing V3.
9. Include first-class directional pauses, shutdown, and migration controls.
10. Give the governance owner an unrestricted external-call escape hatch for urgent recovery and migration.

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
- **Yield token:** the final token held after the expansion path, such as sUSDe.
- **Expansion path:** the updatable sequence from the target asset to the yield token.
- **Contraction path:** the updatable sequence from the yield token back to the target asset.
- **Deployed crvUSD:** Factory-allocated crvUSD that V3 has sold and has not yet reacquired.
- **Idle crvUSD:** crvUSD held by V3 and therefore available for a later expansion or Factory debt reduction.

## Actors

### Governance

Governance configures debt capacity, the target AMM, route endpoints, paths, execution constraints, profitability thresholds, trade caps, keeper fees, and the fee receiver. Route changes are delayed. The governance owner can also make an arbitrary external call through `execute()` when a typed path or normal migration flow is insufficient.

### Emergency admin

The emergency admin can immediately disable expansion, direct buyback, keeper buyback, or all execution. It cannot install a new path or move funds to an arbitrary address.

### Keeper

Any account can call the expansion and fallback contraction functions. V3 does not rely on a keeper whitelist or private order flow. Keeper rewards are paid to `msg.sender`, are capped, and are paid only after a successful profitable transaction. Keeper inputs can bound the amount attempted but cannot weaken any protocol-calculated minimum output or profitability condition.

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
yieldToken
feeReceiver

deployedCrvUsd
expansionPath
contractionPath

expansionMinProfitBps
buybackMinProfitBps
maxExecutionSlippageBps
expansionKeeperFee
contractionKeeperFee
maxKeeperFee

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

Expansion increases `deployedCrvUsd` by the crvUSD sold. Contraction decreases it by the crvUSD reacquired, capped at the current deployed amount. Idle crvUSD backs itself; the trusted backing value of the yield position must cover the portion currently deployed into the market after keeper rewards and fee claims.

## Expansion lifecycle

Expansion is keeper-driven. V3 does not offer a separate direct upward-price quote in the initial design.

```text
1. Verify expansion is enabled.
2. Do not require the target AMM spot price to remain close to its EMA. A sharp upward move in crvUSD is the opportunity V3 is meant to act on.
3. Bound the requested amount by idle crvUSD, per-call limits, and max deployed crvUSD.
4. Sell crvUSD into the designated target AMM.
5. Receive the target asset.
6. Execute the full expansion path from target asset to yield token.
7. Measure actual yield-token shares received by balance delta.
8. Convert the received yield shares into approved underlying units and verify they satisfy both the protocol profit floor and the internally calculated execution-quality floor.
9. Increase deployedCrvUsd.
10. Pay the capped keeper reward to msg.sender from realized surplus.
11. Emit the complete execution result.
```

A preliminary interface is:

```solidity
function expand(
    uint256 maxCrvUsdAmount
) external returns (
    uint256 crvUsdSold,
    uint256 yieldSharesReceived,
    uint256 keeperReward
);
```

The keeper supplies only an amount cap. V3 calculates the actual amount and every intermediate and final minimum internally. A zero or dust-sized result reverts. The keeper cannot choose the target AMM, path, output token, fee receiver, reward recipient, or minimum output.

## Direct buyback lifecycle

Direct buyback provides one-sided downward liquidity.

```text
1. Verify direct buyback is enabled.
2. Transfer crvUSD from the caller to V3.
3. Bound the transaction by deployed crvUSD and the per-call buyback limit.
4. Determine the maximum yield-token shares that may be spent while preserving the configured minimum profit.
5. Execute the contraction path atomically from yield token to target asset.
6. Measure actual target asset received.
7. Verify the crvUSD received exceeds the trusted backing value of yield-token shares spent by the configured minimum profit.
8. Transfer the target asset to the caller.
9. Reduce deployedCrvUsd by the crvUSD reacquired.
10. Retain the crvUSD as idle inventory.
11. Emit the shares spent, target asset paid, and crvUSD reacquired.
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
    returns (uint256 expectedTargetOut, uint256 maxYieldShares);
```

The preview is advisory. Execution uses balance deltas and post-transaction profitability checks.

`minTargetOut` is retained here because the direct buyback caller receives the target asset and may require stricter personal slippage protection. The effective minimum is the greater of the user's minimum and V3's internally calculated protocol minimum. Passing zero cannot weaken V3's floor.

## Keeper buyback fallback

If no direct buyback flow arrives, a keeper can contract supply through the target AMM:

```text
1. Verify keeper buyback is enabled.
2. Execute the contraction path from yield token to target asset.
3. Swap the target asset for crvUSD in the designated target AMM.
4. Verify crvUSD received exceeds the trusted backing value of yield-token shares spent, protocol minimum profit, and capped keeper reward.
5. Reduce deployedCrvUsd.
6. Keep the recovered crvUSD idle.
7. Pay the capped reward to msg.sender.
```

A preliminary interface is:

```solidity
function contractViaAmm(
    uint256 maxYieldShares
) external returns (uint256 crvUsdReceived, uint256 keeperReward);
```

The keeper supplies only the maximum yield-token shares it is willing to trigger. V3 calculates target-asset and crvUSD minimum outputs internally.

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
4. A Curve step's pool contains both configured tokens.
5. An ERC-4626 deposit step uses `vault.asset() == tokenIn` and the vault share token as `tokenOut`.
6. An ERC-4626 redeem step uses the vault share token as `tokenIn` and `vault.asset()` as `tokenOut`.
7. Execution-buffer parameters remain within governance-set maxima.
8. The path length is bounded.
9. No venue, token, or endpoint is zero.

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

## Profitability and execution controls

Realized profitability under the trusted-backing convention is the primary execution gate. V3 should not copy V2-style spot/EMA proximity checks onto the target crvUSD AMM: a sudden crvUSD price spike creates the exact expansion opportunity V3 should capture. Requiring spot to remain close to EMA would suppress the intended trade.

Expansion therefore succeeds only when the approved underlying units represented by the final yield-token shares received are greater than the crvUSD sold by at least the configured protocol margin and keeper reward. Intermediate USDT or USDe quotes are not sufficient; the check uses the end of the atomic path. The approved underlying unit is treated as one dollar without consulting the target AMM spot.

Contraction applies the inverse test: the crvUSD reacquired must exceed the trusted backing value consumed from the yield-token position by the configured margin and any keeper reward.

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
PegKeeper-local profit
    = trusted backing received
    - crvUSD deployed
    - keeper reward

DAO-consolidated profit
    = PegKeeper-local profit
    + attributable DAO admin-fee accrual
```

The first is the onchain safety invariant. The second is an offchain route-selection and governance metric. Routes that return equivalent backing to V3 should prefer fees accruing to the DAO over fees retained by external LPs, but fee recapture must never weaken V3's `minOut` or final backing floor. Pool fee ownership is configuration-dependent and must be rechecked before governance installs or updates a route.

Optional depeg or venue-health checks may still protect the non-crvUSD conversion path, but they must be independent from the target AMM's crvUSD spot/EMA divergence and must not override a transaction that already proves sufficient realized final value. Caller minimums can only make execution stricter; they cannot weaken protocol minimums.

For expansion, V3 calculates the final minimum as:

```text
profitFloor = sharesRequiredForTrustedAssets(
    crvUsdSold + minimumProtocolProfit + keeperReward
)

executionFloor = expectedFinalShares
    * (1 - maxExecutionSlippageBps)

protocolMinShares = max(profitFloor, executionFloor)
```

`expectedFinalShares` comes from the configured target AMM quote, each typed path preview, and the final ERC-4626 `previewDeposit`. Actual shares are measured by balance delta. Share count is not compared directly with deposited underlying because an ERC-4626 share price need not equal one. `sharesRequiredForTrustedAssets` converts the required approved-underlying units into shares through the configured vault or adapter; it does not derive a dollar price from the crvUSD target AMM.

### Expansion postcondition

```text
trustedBackingValue(yieldSharesReceived)
>= crvUsdSold
 + minimumProtocolProfit
 + keeperReward
```

### Direct buyback postcondition

```text
crvUsdReceived
>= trustedBackingValue(yieldSharesSpent)
 + minimumProtocolProfit
```

### Keeper buyback postcondition

```text
crvUsdReceived
>= trustedBackingValue(yieldSharesSpent)
 + minimumProtocolProfit
 + keeperReward
```

The implementation still needs an asset-specific adapter interface and exact rounding direction. Expansion must round required shares up; surplus calculations must round backing value down.

## Open keeper and flash-liquidity model

Open keepers are an explicit design choice. V3 cannot prevent an account from using flash liquidity to move the target AMM, call `expand()` or `contractViaAmm()`, and reverse the market trade afterward.

The minimum-profit postcondition does not prevent that behavior and does not guarantee V3 captures every available basis point of market spread. It guarantees that any completed action leaves V3 with at least the configured nominal profit after the keeper reward under the approved-backing-at-par convention. A manipulator may capture residual spread, but cannot force V3 to complete below its own floor unless the configured vault or adapter accounting itself is compromised. A real depeg of an approved backing asset is governance collateral risk rather than target-AMM price manipulation.

The execution-quality floor prevents the configured route from performing materially worse than the quote visible when V3 executes. It cannot detect a malicious keeper that moved the AMM before the V3 transaction and restores it afterward. Preventing that completely would require a trusted price reference, auction, private order flow, or keeper whitelist. Those mechanisms are outside the current open-keeper design.

The practical V3 policy is therefore:

1. Accept that open execution can leak some transient market spread.
2. Require positive protocol profit on every completed transaction.
3. Include the keeper reward inside the profit requirement.
4. Bound transaction size and reject dust-sized reward farming.
5. Never trust keeper-provided minimum outputs.

### V2 comparison

V2 is not unprotected. Its regulator checks pool spot against the pool oracle for spam-attack protection, checks the aggregate crvUSD price and other registered pools, and can disable either direction. `PegKeeperV2` also uses a 12-second action delay, adjusts only one fifth of the observed imbalance per update, and reverts unless LP-accounting profit increases with `peg unprofitable`.

Those controls reduce simple one-block manipulation and prevent an immediately unprofitable V2 update. They do not prove that V2 captures all available spread or eliminate multi-transaction market manipulation. V3 keeps the economically necessary post-trade profit condition but does not copy a target-AMM spot/EMA proximity check that would suppress the upward price spike V3 is meant to monetize.

## Keeper compensation

Keeper compensation follows these rules:

1. The reward has an absolute governance-set maximum.
2. The reward is paid only after a successful profitable state transition.
3. The reward is paid to `msg.sender`.
4. Callers cannot supply an arbitrary beneficiary.
5. The reward cannot consume principal needed to support deployed crvUSD.
6. Direct buyback callers receive no separate keeper reward.

Whether the reward is fixed, gas-aware, or tiered below the cap remains open.

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
    uint256 yieldSharesReceived,
    uint256 keeperReward
);

event DirectBuyback(
    address indexed caller,
    uint256 crvUsdReceived,
    uint256 targetPaid,
    uint256 yieldSharesSpent
);

event KeeperBuyback(
    address indexed keeper,
    uint256 yieldSharesSpent,
    uint256 targetReceived,
    uint256 crvUsdReceived,
    uint256 keeperReward
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
4. Keeper rewards never exceed the absolute cap.
5. Keeper rewards and fee claims cannot consume required principal.
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

### Governance route power

An updatable path can direct all future flows into a malicious venue. Typed steps, endpoint validation, delayed activation, exact approvals, and emergency cancellation limit this risk.

### Governance execute power

The owner can intentionally bypass typed routes and move or approve assets through `execute()`. This is an explicit trust assumption, not a permissionless surface. A compromised owner can drain V3, but the designated DAO already controls crvUSD minting and the protocol configuration that determines V3's capacity. Ownership must not be delegated to a weaker hot-key or keeper role.

## Deferred decisions

The following are deliberately unresolved:

- whether any aggregate crvUSD trigger is needed beyond realized final profitability;
- whether any separate target-asset or yield-token depeg guard is desirable despite the approved-backing-at-par convention;
- whether V3 eventually receives lazy mint/burn authority;
- exact keeper fee formula and payment asset;
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
