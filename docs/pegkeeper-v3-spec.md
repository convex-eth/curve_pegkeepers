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
- keeper index, local cap, entry/exit profit floors, keeper reward share, and execution buffer;
- final local `admin`, `emergency_admin`, and selected `policy`.

The constructor validates contract code, pool coin order, decimals, virtual price, role separation, Policy code, and parameter bounds. It grants unlimited crvUSD allowance to the ControllerFactory and unlimited pool allowances for crvUSD and the paired token. The keeper starts unpaused, debt-free, and without ControllerFactory allocation.

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
future_admin();
new_admin_deadline();
emergency_admin();
policy();
keeper_profit_share_bps();
```

Only the current keeper admin may call:

```solidity
commit_new_admin(address);
apply_new_admin();
set_emergency_admin(address);
set_policy_contract(address);
set_keeper_profit_share_bps(uint256);
```

Constructor admin and emergency-admin roles must be nonzero and distinct. Admin replacement follows Curve's three-day `commit_new_admin` / `apply_new_admin` flow. The current admin remains active during the delay and can overwrite or cancel a pending commitment by recommitting; only `future_admin` may apply after the deadline. `set_emergency_admin` can replace or revoke the emergency role. A replacement Policy must contain code.

The admin may configure keeper parameters, pause or unpause, execute recovery calls, and adjust recorded debt. The emergency admin may only pause. There is no shared keeper-role owner.

## 3. PegKeeperPolicy global rulings

Each keeper stores its selected Policy directly and queries:

```solidity
can_expand();
can_contract();
expansion_regime();
```

The current `PegKeeperPolicy` stores the aggregate crvUSD oracle and global `fee_receiver`. It owns no keeper list or reward parameter and never calls a keeper for local conditions. Its current executable rulings depend only on the exact aggregate-price boundary. The Policy admin can replace the nonzero fee receiver once for every keeper selecting that Policy. Policy administration uses the same three-day Curve handoff as keepers; the current admin remains active while a commitment is pending.

The no-argument ABI is intentionally replaceable rather than permanently price-only. A future Policy can add global or caller-aware rules while retaining these selectors; direct keeper calls expose the querying keeper as `msg.sender`. Governance can select a replacement with keeper-local `set_policy_contract`.

```text
aggregate price < 1e18: can_expand = false; can_contract = true
aggregate price = 1e18: can_expand = true;  can_contract = true
aggregate price > 1e18: can_expand = true;  can_contract = false
```

Policy and keeper oracle reads use the declared `price()` interface directly. Oracle failure or a zero aggregate price fails closed.

## 4. Keeper-local admission

Execution and previews query the selected Policy for the applicable global ruling, then enforce pauses, action delay, normalized local imbalance, idle crvUSD, keeper-local and ControllerFactory capacity, the retained-backing oracle floor, direct AMM economics, and reward accounting inside the keeper. Profitable expansion and donation settlement may reduce a pre-existing deficit without curing it. Protocol-profit withdrawal remains bounded by backing surplus and rechecks final solvency. The current Policy does not inspect keeper state and has no cross-keeper ordering; keeper-local fees and profit floors provide soft economic preference only.

## 5. PegKeeperRegistry and wind-down

`PegKeeperRegistry` is an independently administered discovery and enumeration contract:

```solidity
peg_keeper_count();
peg_keepers(uint256 index);
is_active(address keeper);
add_peg_keepers(address[] keepers);
remove_peg_keepers(address[] keepers);
```

The deterministic list bound is 32. Addition is admin-only and rejects non-contract or duplicate entries. Removal is admin-only, rejects missing entries, pop-and-swaps the tail into the removed slot, repairs the moved keeper's 1-based index, and permits later re-addition. Registry administration uses the same three-day Curve handoff.

Registry is not queried by Policy or keeper execution. Enrollment is therefore informational and governance-facing: it does not grant expansion authority, and removal does not block expansion or contraction. Wind-down remains controlled by keeper-local conditions plus the selected Policy's global contraction ruling.

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
7. requires LP value after deposit to cover the pre-action LP value, donation principal, and new crvUSD principal, then checks the gross entry floor;
8. pays reward in LP and checks retained backing against the entry baseline;
9. increases `debt` by actual matched crvUSD;
10. records intervention time without requiring a pre-existing deficit to be fully cured.

`preview_expansion()` applies the same accounting and safety predicates without state changes, including partial-deficit-repair eligibility. A zero entry floor, or a positive floor rounded to zero, permits local break-even but never a loss of the action's protected principal. No ordinary expansion function accepts a caller-selected amount. `update()` dispatches to this canonical action when local balance calls for expansion.

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

The entry floor applies to realized gross profit before caller compensation. Reward is calculated only after that floor passes. Donation principal remains excluded from caller profit, and settlement may partially repair a pre-existing deficit.

`sweep_donated_paired_token(maxAmount)`:

- selects and settles loose paired tokens into the AMM;
- requires oracle health and a positive amount;
- requires `policy.can_expand()` before matching any positive crvUSD amount;
- when expansion is allowed, selects the aggregate matching regime through `policy.expansion_regime()`;
- under the current price-only Policy, fully matches at or above aggregate `$1` and deposits one-sided below `$1`;
- consumes capacity only for actual matched crvUSD;
- does not consume the monetary-intervention timer.

`withdraw_profit()` settles donations and transfers all claimable idle crvUSD to the selected Policy's current `fee_receiver`. Its bounded overload applies a caller-supplied transfer cap.

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
- previewed retained LP backing at least projected remaining debt.

Preview uses expected production-pool burn, `calc_token_amount(..., false) + 1 LP wei`, for gross profit and expected backing. The larger buffered maximum burn is execution-only. Execution independently rechecks actual burn, profit, and debt reduction.

Contraction reduces debt by crvUSD retained after reward. Terminal value above remaining debt is sent to the selected Policy's global fee receiver.

`update()` selects contraction when the pool has excess crvUSD and returns zero if the delay was consumed. `update(address beneficiary)` routes the physical reward to the selected nonzero beneficiary. `estimate_caller_profit()` returns zero when neither canonical direction is executable. `calc_profit()` aliases current protocol surplus in crvUSD-value terms.

## 10. Governance debt accounting

The keeper admin may call:

```solidity
increase_debt(uint256 amount)
reduce_debt(uint256 amount)
```

`increase_debt` performs checked addition and emits `DebtIncreased`. `reduce_debt` clamps the requested reduction at zero and emits `DebtReduced`. These functions are bookkeeping-only: they do not move or mint crvUSD, query Policy or oracle state, enforce pauses or capacity, or update the intervention timestamp. Governance performs any corresponding asset movement separately through `execute`.

For a debt migration of `X` from keeper A to keeper B under unchanged ControllerFactory allocations, one atomic governance execution must:

1. call `B.increase_debt(X)`;
2. transfer `X` idle crvUSD from B to A through `B.execute`;
3. call `A.reduce_debt(X)`;
4. transfer the corresponding backing from A to B through `A.execute`.

The crvUSD counter-transfer preserves each keeper's `debt + idle crvUSD` against its unchanged `debt_ceiling_residual`. Calling only `increase_debt` leaves ControllerFactory residual accounting economically unreconciled. If B lacks `X` idle crvUSD, governance must instead migrate ControllerFactory allocation through coordinated `set_debt_ceiling` mint/transfer/burn operations.

## 11. Pauses, capacity, and timing

Pause directions:

```text
0 expansion
1 exact-crvUSD contraction
2 all execution
```

`action_imbalance_bps` controls the sole ordinary action size as a share of current normalized pool imbalance. `action_delay` controls elapsed-time frequency for expansion, contraction, and `update`. `keeper_profit_share_bps` is independently stored and admin-controlled on each keeper, bounded to `10_000 bps`. Donation and profit settlement remain outside the timer so donated dust cannot monopolize it.

Every permissionless debt increase is bounded by both:

```text
keeper.max_debt()
ControllerFactory.debt_ceiling(keeper)
```

`available_expansion()` returns zero unless the Policy's global expansion ruling passes. Otherwise it reports the minimum of canonical `20%` deficit, idle crvUSD after donation reserves, and both capacity limits. `available_contraction()` likewise requires the global contraction ruling and reports the canonical exact output permitted by local excess and available LP.

## 12. Deployment and activation

The environment-free deployment script performs eight monotonic CREATEs:

1. `PegKeeperPolicy`, administered directly by the Curve Ownership Agent and initialized with the global fee receiver;
2. `PegKeeperRegistry`, administered directly by the Curve Ownership Agent;
3. frxUSD/USD adapter;
4. USDC/USD adapter;
5. USDT/USD adapter;
6. standalone frxUSD keeper;
7. standalone USDC keeper;
8. standalone USDT keeper.

Every keeper is complete at construction with final roles and selected Policy. There is no implementation deployment, clone creation, temporary administration, pending admin commitment, or post-deploy keeper configuration.

The Registry remains empty after deployment. Every keeper is unpaused and has zero ControllerFactory allocation. Deployment alone therefore does not activate debt growth.

The launch proposal performs ten actions:

1. one batched `registry.add_peg_keepers([frxUSD, USDC, USDT])`;
2. six registrations across current and legacy aggregate monetary policies;
3. three ControllerFactory ceiling assignments.

## 13. Candidate launch

| AMM | Liquidity ABI | Paired token | Backing oracle | Local max | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---:|---:|---:|---:|
| frxUSD/crvUSD | dynamic | frxUSD | frxUSD/USD | 150m | 150m | 10 ppm / 0.1 bp | 150 ppm / 1.5 bp |
| USDC/crvUSD | fixed | USDC | USDC/USD | 150m | 150m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |
| USDT/crvUSD | fixed | USDT | USDT/USD | 150m | 150m | 300 ppm / 3 bp | 80 ppm / 0.8 bp |

All launch keepers use `20%` intervention share, `12`-second `action_delay`, `0.999e18` retained-backing floor, `3 bps` AMM execution buffer, and an independent keeper-local reward share starting at `3_000 bps`.

## 14. Compiled identity

Pinned Vyper `0.4.3`, codesize optimization, Prague:

```text
PegKeeperV3 version:       3.0.0
standalone initcode:      17,227 bytes
keeper runtime core:       14,476 bytes
standalone runtime:      14,508 bytes
EIP-170 headroom:         10,068 bytes
runtime core hash:
0xa43304a9410595aaa28c7f74725b152c204d2b5209a63e2fa0129cc3b064a287
mainnet runtime hash:
0x591301e2a4eb3fab8cb77d0c1249779a5a05574f11a6be72f8e5f1d0d94fee0d

PegKeeperPolicy runtime:   905 bytes
policy hash:
0xa11f74514ddad33cebd3ea933e1bf8d802b74107af7b3bc23b0bb6a0067a758c

PegKeeperRegistry runtime: 1,296 bytes
registry hash:
0xa8701fd3d6a78297bb59b5d1466c6e20e96e41959650282aa03b4e7b4015e8a8
```

Vyper appends the canonical crvUSD immutable word to the Keeper runtime core. Tests pin the core and assert exact deployed-code composition before pinning the mainnet runtime hash.

The existing release manifest, release checklist, and manifest verifier predate this source snapshot. They remain frozen and must be regenerated rather than edited in this source batch.

## 15. Required verification before release

1. Compile under pinned Vyper/Solidity and Prague settings.
2. Pass unit, Policy, Registry, deployment, proposal, runtime, ABI-parity, and invariant checks.
3. Verify Registry pop-and-swap removal, moved-index repair, duplicate rejection, re-addition, and execution independence.
4. Execute the full ten-action Curve ownership vote on a pinned fork.
5. Execute live direct expansion/contraction canaries without oracle mocks.
6. Reconfirm pool coin order, ABI mode, rates, virtual prices, fees, liquidity, oracle heartbeats, and ControllerFactory capacity at a current block.
7. Generate a new release manifest; never relabel historical evidence.
8. Obtain explicit governance authorization before deployment, allocation, registration, activation, or broadcast.
