# PegKeeper V3 direct-liquidity specification

Status: unreleased `3.0.0` candidate on branch `main`. Not deployed. Nothing in this document authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## 1. Scope and deployment unit

Each `PegKeeperV3` is one complete, non-upgradeable deployment owning and accounting for liquidity in exactly one Curve two-coin pool containing crvUSD and one paired token. There is no shared implementation, initializer, proxy, clone, keeper factory, or factory registry.

The constructor fixes or derives:

- `crv_usd`: read from the canonical ControllerFactory and bound as a public immutable;
- `pool`: the pool and LP token;
- `paired_token`: the non-crvUSD pool coin, derived from pool coin order;
- `pool_uses_dynamic_arrays`: whether liquidity calls use `uint256[]` or `uint256[2]`;
- `backing_asset`: `paired_token`, or `paired_token.asset()` in ERC-4626 mode;
- `backing_oracle`: an independent USD oracle for retained backing;
- keeper index, local cap, entry/exit profit floors, and execution buffer;
- final local `admin`, `emergency_admin`, `fee_receiver`, and `policy`.

The constructor validates contract code, pool coin order, decimals, virtual price, role separation, Policy code, and parameter bounds. It grants the ControllerFactory unlimited crvUSD allowance for ceiling reductions and permissionless residual-allocation burning. The keeper starts unpaused, debt-free, and without ControllerFactory allocation.

The core contains no target AMM, swap operation, route struct, path storage, route loss bound, conversion adapter, or detached preview module.

The AMM must:

- contain exactly crvUSD and the paired token;
- expose its 18-decimal LP token at the pool address;
- implement the selected dynamic- or fixed-array liquidity ABI;
- implement `balances(uint256)`, `get_virtual_price()`, exact-output imbalance withdrawal, and one-coin withdrawal helpers.

The selected ABI mode is exposed by `pool_uses_dynamic_arrays()`. Execution does not retry the other ABI after a revert; a wrong mode fails closed.

## 2. Keeper-local authority

Every keeper directly stores:

```solidity
admin();
emergency_admin();
fee_receiver();
policy();
```

Only the current keeper admin may call:

```solidity
set_admin(address);
set_emergency_admin(address);
set_fee_receiver(address);
set_policy_contract(address);
```

Admin and emergency admin must be nonzero and distinct. Fee receiver must be nonzero. A replacement Policy must contain code. Role and Policy changes emit old/new events.

The admin may configure keeper parameters, pause or unpause, execute recovery calls, and perform the external draw. The emergency admin may only pause. There is no shared keeper-role owner.

## 3. PegKeeperPolicy and active list

`PegKeeperPolicy` owns:

- the aggregate crvUSD oracle;
- one global keeper profit share;
- the active keeper list;
- `can_allocate`, `can_expand`, `can_contract`, and `expansion_regime` decisions.

Policy ownership uses a nonce-bound two-step transfer. Configuration freezes while an ownership transfer is pending.

The list follows the V2 regulator design and is bounded to eight keepers:

```solidity
peg_keeper_count();
peg_keepers(uint256 index);
is_active(address keeper);
add_peg_keepers(address[] keepers);
remove_peg_keepers(address[] keepers);
```

Addition is owner-only, rejects duplicate entries, and requires each candidate to contain code and return `policy() == address(this)`. Removal is owner-only, rejects missing entries, pop-and-swaps the tail into the removed slot, and repairs the moved keeper's 1-based index. Removed keepers can be added again.

The list is not duplicated elsewhere. The aggregate crvUSD oracle and monetary policies maintain separate registries for different purposes.

Every reward path calls `policy.keeper_profit_share_bps(keeper)`. The current Policy returns one owner-managed value for every address and bounds it to `10_000 bps`; the address argument leaves room for future keeper-aware logic without changing the keeper ABI.

### 3.1 Binding and replacement

Each keeper stores its selected Policy directly. Policy admission checks the reverse binding through `keeper.policy()`.

- allocation and expansion require both active-list membership and correct binding;
- contraction requires correct binding but not active membership.

A Policy migration must coordinate keeper-local `set_policy_contract` with removal from the old list and addition to the new list. During any gap, allocation and expansion fail closed. A stale old-list entry is inert once the keeper points elsewhere because reverse binding fails.

## 4. Expansion admission

A keeper exposes `can_expand_without_policy()`, a non-recursive local probe covering:

- global and expansion pauses;
- shared action delay;
- normalized local pool deficit and canonical expansion amount;
- idle crvUSD;
- keeper-local and ControllerFactory capacity;
- retained-backing oracle floor;
- direct AMM quote, entry-profit floor, reward, and final solvency.

Expected economic failure returns `false`. Policy invokes this probe with a low-level static call and treats malformed return data or reversion as non-executability.

`policy.can_expand(keeper)` requires:

1. a valid aggregate crvUSD price at least `1e18`;
2. active-list membership;
3. `keeper.policy() == policy`;
4. a successful local keeper probe.

The Policy has no cross-keeper ordering. Every admitted keeper is evaluated independently. Keeper-local fees and profit floors provide soft economic preference only.

`policy.can_allocate(keeper)` requires active membership and correct binding without calling the local AMM probe. Donation matching separately enforces amount, backing, capacity, aggregate direction, and final solvency.

## 5. Aggregate direction and wind-down

The aggregate oracle is read with exact 32-byte returndata checks.

```text
aggregate price < 1e18: can_expand = false; can_contract = true
aggregate price = 1e18: can_expand = true;  can_contract = true
aggregate price > 1e18: can_expand = true;  can_contract = false
```

Oracle failure fails closed.

`can_contract(keeper)` requires correct Policy binding but deliberately ignores active-list membership. Removing a keeper blocks new allocation and expansion without trapping its unwind.

## 6. Direct expansion

For canonical crvUSD amount `X` and selected donated paired-token value `D`:

```text
crvUSD deposited     = X + D
paired token deposited = selected loose paired-token balance
recorded debt increase = X + D
```

The call:

1. checks pauses, Policy expansion admission, action delay, and local deficit share;
2. checks retained-backing oracle health;
3. values selected loose paired tokens;
4. checks idle balance and both capacity ceilings;
5. quotes and performs direct `add_liquidity` with the configured execution buffer;
6. measures exact crvUSD, paired-token, and LP deltas;
7. computes gross action profit before caller reward;
8. pays reward in LP;
9. increases `deployed_crvusd` by actual matched crvUSD;
10. checks final retained backing and records intervention time.

`preview_expansion()` applies the same accounting and safety predicates without state changes. No ordinary expansion function accepts a caller-selected amount. `update()` dispatches to this canonical action when local balance calls for expansion.

## 7. LP and ERC-4626 valuation

Persistent backing is the complete held LP balance:

```text
lpValue = floor(pool.balanceOf(keeper) * get_virtual_price() / 1e18)
```

For an ERC-4626 paired token:

- loose share balances and pool normalization use `convertToAssets()`;
- persistent LP uses only `get_virtual_price()`;
- the ERC-4626 rate is not applied again to LP value.

The retained-backing oracle is independent of virtual price and caps its valuation contribution at `$1`. The launch floor is `0.999e18`.

## 8. Donations and profit attribution

A paired-token donation is protocol property, not caller-created profit.

```text
accounting baseline = LP value before + normalized donation value
principal           = crvUSD deposited
realized gross      = max(LP value after - baseline - principal, 0)
```

The entry floor applies to realized gross profit before caller compensation. Reward is calculated only after that floor passes, and retained LP must still cover resulting debt.

`sweep_donated_paired_token(maxAmount)`:

- selects and settles loose paired tokens into the AMM;
- requires oracle health and a positive amount;
- matches crvUSD only when `policy.can_allocate(self)`;
- at or above aggregate `$1`, targets a full value match;
- below aggregate `$1`, matches only enough to avoid overshooting normalized pool balance;
- consumes capacity only for actual matched crvUSD;
- does not consume the monetary-intervention timer.

`withdraw_profit()` settles donations and transfers all claimable idle crvUSD to the keeper's current `fee_receiver`. Its bounded overload applies a caller-supplied transfer cap.

## 9. Canonical exact-output contraction

`contract_supply()` has one path:

```text
held LP
  -> quote LP burn for canonical crvUSD output
  -> remove_liquidity_imbalance([exact crvUSD, 0], maxLpBurn)
  -> exact crvUSD
```

It requires:

- contraction/global pauses open;
- Policy contraction admission;
- elapsed shared action delay;
- canonical output equal to the configured `20%` normalized local crvUSD excess share, bounded by LP backing;
- quoted and measured LP burn within the quote-derived bound;
- measured crvUSD receipt exactly equal to requested output;
- strictly positive gross exit profit before reward, even if the configured floor is zero;
- the configured gross exit floor;
- final retained LP backing at least remaining debt.

Preview uses expected production-pool burn, `calc_token_amount(..., false) + 1 LP wei`, for gross profit and expected backing. The larger buffered maximum burn is execution-only. Execution independently rechecks actual burn, profit, debt reduction, and solvency.

Contraction reduces debt by crvUSD retained after reward. Terminal value above remaining debt is sent to the local fee receiver.

`update()` selects contraction when the pool has excess crvUSD and returns zero if the delay was consumed. `update(address beneficiary)` routes the physical reward to the selected nonzero beneficiary. `estimate_caller_profit()` returns zero when neither canonical direction is executable. `calc_profit()` aliases current protocol surplus in crvUSD-value terms.

## 10. Policy-gated external draw

The keeper admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

It requires:

- nonzero amount and receiver;
- open expansion/global pauses and elapsed action delay;
- amount within normalized local imbalance;
- healthy retained backing;
- `policy.can_expand(address(this))`;
- resulting debt within local cap and ControllerFactory ceiling;
- sufficient idle crvUSD.

It increments debt, records intervention time, transfers exactly `amount`, and emits `CrvUsdBorrowed`. External execution and backing return must be atomic at the module/governance transaction layer. `reduce_deployed_crvusd(amount)` is the admin-only inverse bookkeeping operation.

## 11. Pauses, capacity, and timing

Pause directions:

```text
0 expansion
1 exact-crvUSD contraction
2 all execution
```

`max_intervention_share_bps` controls the sole ordinary action size. `action_delay` controls frequency for expansion, contraction, `update`, and external draw. Donation and profit settlement remain outside this timer so donated dust cannot monopolize it.

Every debt increase is bounded by both:

```text
keeper.max_deployed_crvusd()
ControllerFactory.debt_ceiling(keeper)
```

`available_expansion()` returns zero unless Policy admission passes. Otherwise it reports the minimum of canonical `20%` deficit, idle crvUSD after donation reserves, and both capacity limits. `available_contraction()` reports the canonical exact output permitted by local excess and available LP.

## 12. Deployment and activation

The environment-free deployment script performs seven monotonic CREATEs:

1. `PegKeeperPolicy`, owned directly by the Curve Ownership Agent;
2. frxUSD/USD adapter;
3. USDC/USD adapter;
4. USDT/USD adapter;
5. standalone frxUSD keeper;
6. standalone USDC keeper;
7. standalone USDT keeper.

Every keeper is complete at construction with final roles and selected Policy. There is no implementation deployment, clone creation, temporary ownership, ownership acceptance, acceptance nonce, or post-deploy keeper configuration.

The Policy list remains empty after deployment. Every keeper is unpaused and has zero ControllerFactory allocation. Deployment alone therefore does not activate debt growth.

The launch proposal performs ten actions:

1. one batched `policy.add_peg_keepers([frxUSD, USDC, USDT])`;
2. six registrations across current and legacy aggregate monetary policies;
3. three ControllerFactory ceiling assignments.

## 13. Candidate launch

| AMM | Liquidity ABI | Paired token | Backing oracle | Local max | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---:|---:|---:|---:|
| frxUSD/crvUSD | dynamic | frxUSD | frxUSD/USD | 150m | 150m | 10 ppm / 0.1 bp | 150 ppm / 1.5 bp |
| USDC/crvUSD | fixed | USDC | USDC/USD | 150m | 150m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |
| USDT/crvUSD | fixed | USDT | USDT/USD | 150m | 150m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |

All launch keepers use `20%` intervention share, `12`-second `action_delay`, `0.999e18` retained-backing floor, and `3 bps` AMM execution buffer. Policy keeper reward share starts at `3_000 bps`.

## 14. Compiled identity

Pinned Vyper `0.4.3`, codesize optimization, Prague:

```text
PegKeeperV3 version:       3.0.0
standalone initcode:      19,545 bytes
runtime core:            16,987 bytes
standalone runtime:      17,019 bytes
EIP-170 headroom:         7,557 bytes
runtime core hash:
0x3ea6b15c5e12d39aecf1f98e99076598f8ff85cadba14cb29b403e61d8e0db34
mainnet runtime hash:
0x147f13c1e456fa7ff0fdda157ec3e68ab06b54eb6cc38eb43c10d5aa78c5257a

PegKeeperPolicy runtime:   2,947 bytes
policy hash:
0xe4388d617ce6babcb14d56859da66b68f4978dcf32c34adb8ac2f01559f279d0
```

Vyper appends the canonical crvUSD immutable word to the Keeper runtime core. Tests pin the core and assert exact deployed-code composition before pinning the mainnet runtime hash.

The existing release manifest, release checklist, and manifest verifier predate this source snapshot. They remain frozen and must be regenerated rather than edited in this source batch.

## 15. Required verification before release

1. Compile under pinned Vyper/Solidity and Prague settings.
2. Pass unit, Policy-list, deployment, proposal, runtime, ABI-parity, and invariant checks.
3. Verify pop-and-swap removal, moved-index repair, duplicate rejection, reactivation, and removed-keeper wind-down.
4. Execute the full ten-action Curve ownership vote on a pinned fork.
5. Execute live direct expansion/contraction canaries without oracle mocks.
6. Reconfirm pool coin order, ABI mode, rates, virtual prices, fees, liquidity, oracle heartbeats, and ControllerFactory capacity at a current block.
7. Generate a new release manifest; never relabel historical evidence.
8. Obtain explicit governance authorization before deployment, allocation, registration, activation, or broadcast.
