# PegKeeper V3 direct-liquidity specification

Status: unreleased `3.0.0` candidate on branch `main`. Not deployed. Nothing in this document authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## 1. Scope

PegKeeperV3 owns and accounts for liquidity in exactly one Curve two-coin pool containing crvUSD and one paired token. The shared implementation binds crvUSD once as a public immutable. Every minimal proxy reads that code-bound value, and initialization requires the creating Factory's ControllerFactory to report the same stablecoin.

Each proxy fixes:

- `pool`: the pool and its LP token;
- `paired_token`: the non-crvUSD pool coin;
- `pool_uses_dynamic_arrays`: whether liquidity quotes/deposits use `uint256[]` or `uint256[2]`;
- `backing_asset`: `paired_token`, or `paired_token.asset()` in ERC-4626 mode;
- `backing_oracle`: an independent USD oracle for retained backing;
- local capacity, intervention, profit, velocity, role, and pause state.

The core contains no target AMM, swap operation, route struct, path storage, route loss bound, DAI/USDS adapter, ERC-4626 route operation, Frax minter operation, or detached preview module.

The AMM must:

- contain exactly crvUSD and `paired_token`;
- expose its 18-decimal LP token at the pool address;
- implement the initialization-selected liquidity ABI: either dynamic-array `calc_token_amount(uint256[],bool)` and `add_liquidity(uint256[],uint256)`, or fixed-array `calc_token_amount(uint256[2],bool)` and `add_liquidity(uint256[2],uint256)`;
- implement `balances(uint256)`, `get_virtual_price()`, `calc_withdraw_one_coin(uint256,int128)`, and `remove_liquidity_one_coin(uint256,int128,uint256)`.

The selected mode is exposed by `pool_uses_dynamic_arrays()`. Initialization does not probe selectors and execution does not retry the other selector after a revert. A wrong mode therefore fails closed instead of interpreting an arbitrary pool failure as evidence that another ABI should be attempted.

## 2. Shared contracts

### 2.1 PegKeeperV3Factory

The Factory is responsible for:

- the immutable ControllerFactory and locked implementation;
- dynamic `admin`, `emergency_admin`, and `fee_receiver` roles;
- deployment defaults;
- the active policy pointer exposed as `policy()`;
- deploying EIP-1167 proxies;
- an indexed active-keeper list and `is_active(address)` membership;
- owner-controlled keeper activation/deactivation and policy replacement.

It does not own the aggregate oracle or expansion-direction logic.

The public active registry is:

```solidity
function activePegKeeperCount() external view returns (uint256);
function activePegKeeperAt(uint256 index) external view returns (address);
function is_active(address keeper) external view returns (bool);
```

Deactivation uses pop-and-swap list removal and updates the moved keeper's index. A previously deployed keeper can be reactivated exactly once without duplicate list entries.

Deployment is blocked until `policy.factory() == address(factory)`. Factory policy replacement requires the replacement to contain code and already be bound to this Factory.

### 2.2 PegKeeperPolicy

`PegKeeperPolicy` owns configurable cross-keeper admission rules:

- aggregate crvUSD oracle;
- shared priority-utilization threshold;
- one global keeper profit share;
- one primary;
- multiple indexed secondaries;
- multiple indexed tertiaries;
- `can_allocate`, `can_expand`, `can_contract`, and `expansion_regime` decisions.

It binds to one Factory once. Its owner and the Factory owner are independently transferable through two-step ownership.

The policy may be replaced without redeploying keepers because each keeper reads `factory.policy()` dynamically.

Every reward path calls `policy.keeper_profit_share_bps(keeper)`. The current policy returns one owner-managed value for every address and bounds it to `10_000 bps`; the address argument permits later keeper-aware policy without changing keeper ABI. Policy updates and policy replacement apply immediately to all existing keepers.

## 3. Expansion admission

A keeper exposes `can_expand_without_policy()`. This is a non-recursive local probe covering:

- global and expansion pauses;
- shared intervention delay;
- normalized local pool deficit;
- canonical expansion amount;
- idle crvUSD;
- local and ControllerFactory capacity;
- velocity availability;
- retained-backing oracle floor;
- direct AMM quote, entry-profit floor, reward, and final solvency preview.

Expected economic failure returns `false`. A malformed or reverting external dependency may revert; policy calls the candidate probe with a low-level static call and treats failure as candidate non-executability. That result never releases a higher tier's priority.

`policy.can_expand(keeper)` requires:

1. a valid aggregate crvUSD price at least `1e18`;
2. Factory active membership;
3. a configured tier and satisfied priority rule;
4. a successful local keeper probe.

### 3.1 Priority rules

Tier values are:

```text
0 none
1 primary
2 secondary
3 tertiary
```

Primary:

```text
candidate must be active and locally expandable
```

Secondary:

```text
candidate must be active and locally expandable
AND
primary does not retain priority
```

Tertiary:

```text
candidate must be active and locally expandable
AND primary does not retain priority
AND every configured secondary does not retain priority
```

A higher-tier keeper retains priority exactly when it is active and bound to this Factory,
neither globally nor expansion-paused, has a valid retained-backing oracle price at or above
its configured floor, has nonzero effective capacity, and remains below the shared priority
utilization threshold. Policy checks those facts directly.

Temporary local non-executability does not release priority. In particular, pool imbalance,
intervention delay, velocity pressure, loose crvUSD, AMM quote, and entry-profit viability are
candidate execution checks rather than predecessor-priority checks. This prevents one
same-block transaction from expanding a primary, consuming its immediate local capacity, and
then cascading through secondary and tertiary keepers.

An unset primary counts as unavailable, not as a global expansion stop. A configured secondary
may therefore expand without a primary; a tertiary still waits until every funded, healthy,
unpaused secondary reaches the same utilization threshold or otherwise stops retaining priority.

The shared `80%` priority-utilization check uses independently for each higher-tier keeper:

```text
used = keeper.debt()
cap  = min(
    keeper.max_deployed_crvusd(),
    ControllerFactory.debt_ceiling(keeper)
)
require used >= ceil(cap * 8_000 / 10_000)
```

Raw crvUSD token balance is excluded. Reconstructing capacity as `balance + debt` would allow direct token donations to raise the denominator and delay lower tiers.

The policy permits at most 256 configured secondaries. Tertiary admission loops over exactly that bounded set, so no configured secondary can sit beyond the checked iteration range.

No priority logic is hard-coded in the Factory or keeper.

### 3.2 Allocation admission

`can_allocate(keeper)` applies active membership and tier ordering without requiring the candidate's direct AMM probe. This is used for debt-increasing donation matches. A lower-priority keeper may always settle a donation one-sided, but it may increase crvUSD debt only when allocation priority allows.

## 4. Aggregate direction

The policy reads the aggregate oracle with exact 32-byte returndata checks.

```text
aggregate price < 1e18: can_expand = false; can_contract = true
aggregate price = 1e18: can_expand = true;  can_contract = true
aggregate price > 1e18: can_expand = true;  can_contract = false
```

Aggregate-oracle failure fails closed. Contraction verifies that the caller keeper belongs to the bound Factory but deliberately does not require active membership. Offboarding must not trap unwind.

## 5. Direct expansion

For canonical crvUSD amount `X` and selected donated paired-token value `D`:

```text
crvUSD deposited = X + D
paired token deposited = loose paired-token balance
recorded debt increase = X + D
```

With no donation, expansion is a one-sided `X` crvUSD deposit into the keeper's own pool.

The call:

1. checks pauses, `policy.can_expand(self)`, intervention delay, and local deficit share;
2. checks retained-backing oracle health;
3. values loose paired tokens;
4. checks idle balance, local/Factory cap, and velocity for total matched crvUSD;
5. quotes and performs direct `add_liquidity` with one AMM execution buffer;
6. measures exact crvUSD, paired-token, and LP deltas;
7. computes gross action profit before caller reward;
8. pays the configured reward in LP;
9. increases `deployed_crvusd` by actual matched crvUSD;
10. checks final retained backing and records intervention time.

`preview_expansion()` executes the same canonical direct accounting and safety predicates without state changes. No ordinary expansion function accepts a caller-selected amount. `update()` dispatches to the same canonical expansion when the normalized local pool balance calls for expansion.

## 6. LP and ERC-4626 valuation

Persistent backing is the complete held LP balance:

```text
lpValue = floor(pool.balanceOf(keeper) * get_virtual_price() / 1e18)
```

For an ERC-4626 paired token:

- loose share balances and pool-balance normalization use `convertToAssets()`;
- persistent LP uses only `get_virtual_price()`;
- the ERC-4626 rate must not be applied again to LP value.

This is valid only for certified pools whose rates and virtual price coherently represent the underlying assets.

The retained-backing oracle is independent of pool virtual price and caps its valuation contribution at `$1`. The proposed floor is `0.999e18`.

## 7. Donations and profit attribution

A paired-token donation is protocol property, not caller-created profit.

```text
accounting baseline = LP value before + normalized donated token value
principal           = crvUSD deposited
realized gross       = max(LP value after - baseline - principal, 0)
```

The configured entry floor applies to realized gross profit before caller compensation. Caller reward is calculated only after that floor passes, and the retained LP must still cover resulting debt. With the global `3_000 bps` caller share, the launch `0.1 bp` preferred entry floor splits into `0.03 bp` for the caller and `0.07 bp` retained by the protocol; the `3 bp` tertiary entry floor splits into `0.9 bp` and `2.1 bp`, respectively.

Expansion velocity is keeper-local configuration. `set_velocity_policy(maxExpansionBurstBps, expansionRefillPeriod)` is restricted to the Factory's dynamic admin, allows a zero burst to disable new capacity, requires burst at most `10_000 bps`, and requires a nonzero refill period. The launch rule is `1_000 bps` (`10%`) of local maximum exposure with a `36 second` full linear refill. This buys roughly three blocks for independent backing oracles to react while the separately configurable `20%` local-imbalance action limits each intervention. Velocity parameters and local-cap updates first checkpoint pressure under the old rule, preventing retroactive decay at a newly selected rate.

`sweep_donated_paired_token(maxAmount)`:

- settles selected loose paired tokens into the AMM;
- requires oracle health and a positive selected donation amount;
- matches crvUSD only when `policy.can_allocate(self)`;
- at/above aggregate `$1`, targets a full value match;
- below aggregate `$1`, matches only the amount needed to avoid overshooting normalized pool balance;
- consumes capacity and velocity only for actual crvUSD matched;
- does not update the monetary-intervention timestamp.

`withdraw_profit()` performs the same donation settlement before transferring all claimable idle crvUSD to the live Factory fee receiver. `withdraw_profit(maxCrvUsdAmount)` runs the same path with a caller-supplied transfer bound.

## 8. Canonical exact-output contraction

`contract_supply()` has one path:

```text
held LP
  -> quote LP burn for the canonical crvUSD amount
  -> remove_liquidity_imbalance([exact crvUSD, 0], maxLpBurn)
  -> exact crvUSD
```

It requires:

- contraction/global pauses open;
- `policy.can_contract(self)`;
- shared intervention delay;
- canonical output equal to the configured `20%` normalized local crvUSD excess share, bounded by available LP backing;
- quoted and measured LP burn within the quote-derived maximum-burn buffer;
- measured crvUSD receipt exactly equal to the canonical requested output;
- positive value removed;
- strictly positive gross exit profit before reward, even when the configured floor is zero;
- configured gross exit profit before reward;
- final retained LP backing at least remaining debt.

The advisory preview uses the expected production-pool burn, `calc_token_amount(..., false) + 1 LP wei`, to calculate gross profit, caller reward, and expected post-action backing. The larger buffered maximum LP burn is only the execution slippage bound. Execution measures the actual burn and independently rechecks strict-positive profit, the configured floor, debt reduction, and final solvency; tolerated LP-burn slippage cannot turn an unprofitable action into a successful transaction.

Contraction reduces debt by crvUSD retained after reward. Any amount above remaining debt is terminal surplus transferred to the fee receiver.

`preview_contraction()` returns that exact canonical crvUSD output, gross profit, and caller reward. `available_contraction()` reports the same output cap. `update()` selects contraction when the normalized local pool balance has excess crvUSD and returns zero if the intervention delay was already consumed, matching V2's race behavior. `update(address beneficiary)` executes the identical action while routing the physical expansion LP reward or contraction crvUSD reward to the selected nonzero beneficiary. `estimate_caller_profit()` tries the canonical preview and returns zero when neither direction is executable; expansion LP reward is normalized through virtual price so its return is in crvUSD-value terms. `calc_profit()` aliases current protocol surplus in crvUSD-value terms for V2 tooling compatibility.

Entry and normal-contraction profit floors both apply to gross realized profit before caller compensation and remain independent; `normalExitMinProfitPpm` may be below `entryMinProfitPpm`. The candidate USDC/USDT keepers deliberately use that ordering so last-resort exposure is expensive to enter and cheaper to unwind.

## 9. Policy-gated external draw

The Factory admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The function requires:

- nonzero amount and receiver;
- expansion/global pauses open and the intervention delay elapsed;
- amount within the current normalized local imbalance bound;
- a healthy retained-backing oracle;
- `factory.policy().can_expand(address(this))`;
- resulting debt within the local cap and ControllerFactory ceiling;
- sufficient idle crvUSD;
- sufficient velocity.

It increments `deployed_crvusd`, updates the intervention timestamp, transfers exactly `amount`, and emits `CrvUsdBorrowed`.

This enables an external arbitrage/liquidity module without restoring routing to the keeper. The draw itself cannot verify the LP or other backing returned later by that module. Production use must make draw, external execution, LP delivery, and postconditions atomic at the caller/module transaction layer. Governance must not split that workflow across transactions.

`reduce_deployed_crvusd(amount)` remains the admin-only inverse bookkeeping operation.

## 10. Pauses and roles

Directions:

```text
0 expansion
1 exact-crvUSD contraction
2 all execution
```

Factory `admin()` may pause or unpause. `emergency_admin()` may only pause. Every Factory-created keeper starts unpaused and with no ControllerFactory allocation; a zero ceiling is the launch-time exposure gate.

`execute(target,value,data)` remains an admin-only arbitrary execution/recovery hook with bubbled revert data. It is not permissionless and does not silently modify debt.

## 11. Capacity and velocity

Expansion, donation matching, surplus claims, and `borrow_crvusd` consume velocity by actual crvUSD debt increase.

Default bucket:

```text
max burst = 10% of max_deployed_crvusd
full refill = 36 seconds
```

`available_expansion()` returns zero unless policy admission passes. Otherwise it reports the sole canonical amount: the minimum of the `20%` local imbalance allowance, idle crvUSD after reserving any donation match, local/Factory capacity, and velocity. `available_contraction()` reports the sole exact crvUSD output allowed by the `20%` local excess and available LP backing.

## 12. Factory deployment and active lifecycle

Factory deployment:

```solidity
deployPegKeeper(
    address amm,
    bool pairedTokenIsErc4626,
    bool poolUsesDynamicArrays,
    address backingOracle
)
```

The Factory derives the non-crvUSD coin, derives ERC-4626 backing when requested, creates one minimal proxy, initializes it with the immutable pool-liquidity ABI mode, applies roles/defaults, adds it to the active list, and emits `PegKeeperDeployed`. Initialization grants the ControllerFactory unlimited crvUSD allowance; this is required for ControllerFactory ceiling reductions and `rug_debt_ceiling()` to burn idle or returned allocation through `crvUSD.burnFrom`.

Historical deployment membership is private. The public policy-facing registry contains only active keepers.

## 13. Candidate launch

| Tier | AMM | Liquidity ABI | Paired token | Backing oracle | Local max | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---|---:|---:|---:|---:|
| Primary | frxUSD/crvUSD | dynamic | frxUSD | frxUSD/USD | 20m | 20m | 10 ppm / 0.1 bp | 150 ppm / 1.5 bp |
| Secondary | crvUSD/sUSDe | dynamic | sUSDe | USDe/USD | provisional 20m | 0 | 10 ppm / 0.1 bp | 110 ppm / 1.1 bp |
| Tertiary | USDC/crvUSD | fixed | USDC | USDC/USD | 20m | 20m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |
| Tertiary | USDT/crvUSD | fixed | USDT | USDT/USD | 20m | 20m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |

The deployment sender initially owns the Factory and policy, binds them, creates and configures all four keepers, installs Curve's final dynamic keeper roles, and names the Curve Ownership Agent as pending owner of both contracts. Once a pending handoff exists, old-owner configuration is frozen. Correcting the pending recipient increments an acceptance nonce, so an already-reviewed proposal cannot accept a redirected handoff. The proposal accepts both nonce-bound handoffs, registers every keeper in both aggregate monetary policies, and assigns 20 million crvUSD ceilings to frxUSD, USDC, and USDT. Those three become active immediately; sUSDe stays at zero allocation.

## 14. Compiled identity

Pinned Vyper `0.4.3`, codesize optimization, Prague:

```text
PegKeeperV3 version:       3.0.0 (numeric tuple: 3, 0, 0)
implementation initcode: 20,253 bytes
implementation runtime:  20,095 bytes
implementation hash:
0x9af68c945716ce92b3e79066bd4e8b042ccbdefb50009dd9c162897a365275d9
EIP-170 headroom:          4,481 bytes

PegKeeperPolicy runtime:   5,490 bytes
policy hash:
0x0a377d97e86097ebcbe7fb7f5733a1fa54d29bac01b751f21196b070051ee14e

Factory semantic runtime:  3,963 bytes
Factory deployed runtime:  4,027 bytes
Factory semantic hash:
0xcfc318147ad88458f19543d0a8001ed9b046e72c713501b96839d847b8f6799e
```

The existing `3.0.0` manifest and release checklist predate this source snapshot. They must be regenerated from the final committed source before release rather than edited inside the source batch.

## 15. Required verification before any release

1. Compile under pinned Vyper/Solidity and Prague settings.
2. Pass unit, policy, Factory, deployment, proposal, runtime, and ABI-parity checks.
3. Pass stateful backing/capacity/allowance/action-reachability invariants.
4. Execute the full Curve ownership vote on a pinned fork.
5. Execute live direct expansion/contraction canaries without oracle mocks.
6. Reconfirm pool coin order, rate behavior, virtual price, fees, liquidity, oracle heartbeats, and ControllerFactory capacity at a current block.
7. Generate a new release manifest; never relabel historical evidence.
8. Obtain explicit governance authorization before any deployment, allocation, registration, activation, or broadcast.

The bundled pinned frxUSD structural canary uses the production `10 ppm` entry and `150 ppm` exit settings throughout. It executes a canonical `200,000 crvUSD` expansion and a canonical `240,517.600156528893943305 crvUSD` exact-output contraction without weakening either floor, funds through the live ownership-agent/eDAO-proxy/ControllerFactory path, burns idle allocation after setting the ceiling to zero, calls permissionless `rug_debt_ceiling`, and verifies exact keeper-balance, total-supply, residual-allocation, local-debt, and unlimited-allowance reconciliation. A separate pinned test executes both exact-output selector modes against all four candidate production pools.
