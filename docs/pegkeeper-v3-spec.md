# PegKeeper V3 direct-liquidity specification

Status: unreleased `3.4.0` candidate on branch `main`. Not deployed. Nothing in this document authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## 1. Scope

PegKeeperV3 owns and accounts for liquidity in exactly one Curve two-coin pool containing crvUSD and one paired token.

Each proxy fixes:

- `pool`: the pool and its LP token;
- `paired_token`: the non-crvUSD pool coin;
- `backing_asset`: `paired_token`, or `paired_token.asset()` in ERC-4626 mode;
- `backing_oracle`: an independent USD oracle for retained backing;
- local capacity, intervention, profit, velocity, role, and pause state.

The core contains no target AMM, swap operation, route struct, path storage, route loss bound, DAI/USDS adapter, ERC-4626 route operation, Frax minter operation, or detached preview module.

The AMM must:

- contain exactly crvUSD and `paired_token`;
- expose its 18-decimal LP token at the pool address;
- implement StableSwap-NG dynamic-array `calc_token_amount(uint256[],bool)` and `add_liquidity(uint256[],uint256)`;
- implement `balances(uint256)`, `get_virtual_price()`, `calc_withdraw_one_coin(uint256,int128)`, and `remove_liquidity_one_coin(uint256,int128,uint256)`.

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
- primary utilization threshold;
- one primary;
- multiple indexed secondaries;
- multiple indexed tertiaries;
- `can_allocate`, `can_expand`, `can_contract`, and `expansion_regime` decisions.

It binds to one Factory once. Its owner and the Factory owner are independently transferable through two-step ownership.

The policy may be replaced without redeploying keepers because each keeper reads `factory.policy()` dynamically.

## 3. Expansion admission

A keeper exposes `can_expand_without_policy()`. This is a non-recursive local probe covering:

- global and expansion pauses;
- shared intervention delay;
- normalized local pool deficit;
- minimum expansion amount;
- idle crvUSD;
- local and ControllerFactory capacity;
- velocity availability;
- retained-backing oracle floor;
- direct AMM quote, entry-profit floor, reward, and final solvency preview.

Expected economic failure returns `false`. A malformed or reverting external dependency may revert; policy calls the probe with a low-level static call and treats failure as unavailable.

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
(
    primary is not locally expandable
    OR
    primary utilization >= primaryUtilizationBps
)
```

Tertiary:

```text
candidate must be active and locally expandable
AND primary is not locally expandable
AND every active secondary is not locally expandable
```

The `80%` primary utilization check uses:

```text
used = primary.debt()
cap  = min(
    primary.max_deployed_crvusd(),
    ControllerFactory.debt_ceiling(primary)
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

For requested crvUSD `X` and selected donated paired-token value `D`:

```text
crvUSD deposited = X + D
paired token deposited = loose paired-token balance
recorded debt increase = X + D
```

With no donation, expansion is a one-sided `X` crvUSD deposit into the keeper's own pool.

The call:

1. checks pauses, amount floor, `policy.can_expand(self)`, intervention delay, and local deficit share;
2. checks retained-backing oracle health;
3. values loose paired tokens;
4. checks idle balance, local/Factory cap, and velocity for total matched crvUSD;
5. quotes and performs direct `add_liquidity` with one AMM execution buffer;
6. measures exact crvUSD, paired-token, and LP deltas;
7. computes gross action profit before caller reward;
8. pays the configured reward in LP;
9. increases `deployed_crvusd` by actual matched crvUSD;
10. checks final retained backing and records intervention time.

`preview_expansion` executes the same direct accounting and safety predicates without state changes.

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

Caller reward is calculated only from realized gross profit. The retained LP must still satisfy the entry floor and cover resulting debt.

`sweep_donated_paired_token(maxAmount)`:

- settles selected loose paired tokens into the AMM;
- requires oracle health and amount floor;
- matches crvUSD only when `policy.can_allocate(self)`;
- at/above aggregate `$1`, targets a full value match;
- below aggregate `$1`, matches only the amount needed to avoid overshooting normalized pool balance;
- consumes capacity and velocity only for actual crvUSD matched;
- does not update the monetary-intervention timestamp.

`withdraw_profit()` performs the same donation settlement before transferring all claimable idle crvUSD to the live Factory fee receiver. `withdraw_profit(maxCrvUsdAmount)` runs the same path with a caller-supplied transfer bound.

## 8. Static contraction

`contract_supply(lpAmount)` has one path:

```text
held LP
  -> remove_liquidity_one_coin(lpAmount, crvUsdIndex, minCrvUsd)
  -> crvUSD
```

It requires:

- contraction/global pauses open;
- `policy.can_contract(self)`;
- shared intervention delay;
- quote and measured output within the normalized local crvUSD excess share;
- measured output at least the quote-buffer minimum;
- positive value removed;
- configured gross exit profit before reward;
- final retained LP backing at least remaining debt.

Contraction reduces debt by crvUSD retained after reward. Any amount above remaining debt is terminal surplus transferred to the fee receiver.

Entry and normal-contraction profit floors are independent; `normalExitMinProfitPpm` may be below `entryMinProfitPpm`. The candidate USDC/USDT keepers deliberately use that ordering so last-resort exposure is expensive to enter and cheaper to unwind.

## 9. Policy-gated external draw

The Factory admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The function requires:

- nonzero amount and receiver;
- expansion/global pauses open and the intervention delay elapsed;
- amount at least `min_expansion_amount` and within the current normalized local imbalance bound;
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
1 LP contraction
2 all execution
```

Factory `admin()` may pause or unpause. `emergency_admin()` may only pause. Every Factory-created keeper starts fully paused.

`execute(target,value,data)` remains an admin-only arbitrary execution/recovery hook with bubbled revert data. It is not permissionless and does not silently modify debt.

## 11. Capacity and velocity

Expansion, donation matching, surplus claims, and `borrow_crvusd` consume velocity by actual crvUSD debt increase.

Default bucket:

```text
max burst = 5% of max_deployed_crvusd
full refill = 300 seconds
```

`available_expansion()` returns zero unless policy admission passes. Otherwise it reports the minimum of local imbalance allowance, idle crvUSD, local/Factory capacity, and velocity.

## 12. Factory deployment and active lifecycle

Factory deployment:

```solidity
deployPegKeeper(
    address amm,
    bool pairedTokenIsErc4626,
    address backingOracle
)
```

The Factory derives the non-crvUSD coin, derives ERC-4626 backing when requested, creates one minimal proxy, initializes it, applies roles/defaults, adds it to the active list, and emits `PegKeeperDeployed`.

Historical deployment membership is private. The public policy-facing registry contains only active keepers.

## 13. Candidate launch

| Tier | AMM | Paired token | Backing oracle | Local max | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---:|---:|---:|---:|
| Primary | frxUSD/crvUSD | frxUSD | frxUSD/USD | 20m | 20m | 10 ppm / 0.1 bp | 500 ppm / 5 bp |
| Secondary | crvUSD/sUSDe | sUSDe | USDe/USD | provisional 20m | 0 | 10 ppm / 0.1 bp | 500 ppm / 5 bp |
| Tertiary | USDC/crvUSD | USDC | USDC/USD | 20m | 20m | 500 ppm / 5 bp | 100 ppm / 1 bp |
| Tertiary | USDT/crvUSD | USDT | USDT/USD | 20m | 20m | 500 ppm / 5 bp | 100 ppm / 1 bp |

All keepers are deployed, registered in both aggregate monetary policies, tiered, and left fully paused. There is no sUSDe production allocation action.

The dependency deployer creates implementation, policy, Factory, and four Chainlink adapters. The governance proposal first binds policy, then deploys/configures keepers.

## 14. Compiled identity

Pinned Vyper `0.3.10`, codesize optimization, Shanghai:

```text
PegKeeperV3 version:       3.4.0
implementation initcode: 17,861 bytes
implementation runtime:  17,782 bytes
implementation hash:
0x0b5973491de6d7103e6af7457343001e735b03b6e2bd24c44fdaf3463de0412f
EIP-170 headroom:          6,794 bytes

PegKeeperPolicy runtime:   4,394 bytes
policy hash:
0x958aef56c99aefc7f1f3fd7a39097d71d04a5dcfe51993a6488f1df53e7c7078

Factory semantic runtime:  3,839 bytes
Factory deployed runtime:  3,903 bytes
Factory semantic hash:
0x18ce5dfa53fce0917c30401a04f1e317dda0413be53c19dc5948fccc1c1200fd
```

The historical `3.0.0` manifest and release checklist remain frozen and are not evidence for this candidate.

## 15. Required verification before any release

1. Compile under pinned Vyper/Solidity and Shanghai settings.
2. Pass unit, policy, Factory, deployment, proposal, runtime, and ABI-parity checks.
3. Pass stateful backing/capacity/allowance/action-reachability invariants.
4. Execute the full Curve ownership vote on a pinned fork.
5. Execute live direct expansion/contraction canaries without oracle mocks.
6. Reconfirm pool coin order, rate behavior, virtual price, fees, liquidity, oracle heartbeats, and ControllerFactory capacity at a current block.
7. Generate a new release manifest; never relabel historical evidence.
8. Obtain explicit governance authorization before any deployment, allocation, registration, activation, or broadcast.

The bundled pinned frxUSD structural canary lowers `normalExitMinProfitPpm` to zero on the fork only after proving that the historical state has no executable `500 ppm` exit. This tests the real one-coin withdrawal path without misrepresenting historical profitability. The frxUSD production proposal remains `500 ppm`, whose exact boundary is covered by unit tests.
