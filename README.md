# Curve PegKeeper V3

Foundry/Vyper workspace for Curve crvUSD PegKeeper research, V2 migration testing, and an unreleased direct-liquidity PegKeeperV3 candidate.

> **Status:** unreleased version `3.0.0` on branch `main` is not deployed. Nothing in this repository authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## What a PegKeeper does

A PegKeeper uses crvUSD allocated by the ControllerFactory to rebalance one two-coin Curve pool:

- when crvUSD is scarce, it deposits crvUSD and records the amount as debt;
- when crvUSD is abundant, it removes the canonical exact crvUSD amount and reduces debt;
- it retains the LP token as backing and pays callers only from realized accounting profit.

PegKeepers are not a hard peg guarantee. Their effectiveness depends on pool depth, oracle health, policy admission, available debt capacity, and executable economics.

## Standalone direct-only architecture

Each `PegKeeperV3` is one full, non-upgradeable deployment fixed to one pool containing crvUSD and one paired token. There is no implementation contract, proxy, clone factory, keeper factory, or factory-owned registry.

The constructor:

- reads crvUSD from the canonical ControllerFactory and binds it as a public immutable;
- derives the paired token from the pool;
- optionally derives an ERC-4626 backing asset through `asset()`;
- fixes the pool liquidity ABI mode, keeper index, backing oracle, cap, profit floors, and execution buffer;
- stores the final `admin`, `emergency_admin`, `fee_receiver`, and `policy` directly on that keeper;
- grants the ControllerFactory unlimited crvUSD allowance for ceiling reductions and residual-allocation burning.

```text
expansion:
    crvUSD (+ optional matched paired-token donation)
        -> add_liquidity on the keeper's own AMM
        -> retained LP

contraction:
    retained LP
        -> remove_liquidity_imbalance([exact crvUSD, 0], max LP burn)
        -> idle crvUSD
```

The core has no swap router, target AMM, path storage, route adapter, or detached preview module. For ERC-4626 paired tokens, loose shares are normalized with `convertToAssets()`. Held LP is valued only with `get_virtual_price()`; applying the ERC-4626 rate again would double-count it.

Expansion, donation settlement, and contraction use measured token/LP deltas, temporary exact approvals reset to zero, quote-derived slippage bounds, gross-before-reward accounting, and final backing-versus-debt solvency. Contraction preview values the expected `calc_token_amount(..., false) + 1 LP wei` burn; the larger buffered burn is execution-only, where actual profit and solvency are rechecked.

Ordinary interventions do not accept a caller-selected amount. `expand_supply()` and `contract_supply()` execute the sole current crvUSD amount: the configured `20%` share of normalized local imbalance, bounded by balance, backing, and capacity. `update()` selects the local direction for V2 compatibility. `update(address beneficiary)` routes the physical reward to a selected nonzero beneficiary. Both forms return zero rather than reverting when another caller already consumed the shared `action_delay`.

## PegKeeperPolicy

Each keeper stores its selected Policy directly and asks it at execution time:

```solidity
policy.can_allocate(address(this));
policy.can_expand(address(this));
policy.can_contract(address(this));
policy.keeper_profit_share_bps(address(this));
```

`PegKeeperPolicy` owns:

- the aggregate crvUSD oracle and exact direction gate;
- one owner-managed keeper profit share, bounded to `10_000 bps`;
- the active keeper list used for allocation and expansion admission.

The list follows the V2 regulator pattern:

```solidity
peg_keeper_count();
peg_keepers(index);
is_active(keeper);
add_peg_keepers(keepers);
remove_peg_keepers(keepers);
```

It is bounded to eight entries. Addition rejects duplicates and requires every keeper to expose `policy() == address(this)`. Removal uses pop-and-swap and repairs the moved keeper's 1-based index. A removed keeper can be added again without duplicate state.

Active membership and direct Policy binding are both required for allocation and expansion. Contraction requires direct binding but deliberately does not require active membership, so list removal cannot trap an unwind.

### Independent admission and soft priorities

The current Policy has no cross-keeper ordering. Every active, correctly bound keeper is independently eligible when the aggregate direction allows expansion and its `can_expand_without_policy()` probe succeeds. One keeper's debt, capacity, pause state, oracle, pool imbalance, action delay, or profitability cannot block another.

`can_expand_without_policy()` is non-recursive. It checks pause state, action delay, local imbalance, retained-backing oracle, capacity, canonical-action economics, and final solvency. `can_allocate(keeper)` checks active membership and correct binding without invoking the keeper's AMM probe; donation matching has its own amount, backing, capacity, direction, and solvency checks.

Keeper-local AMM fees and gross-profit floors provide soft economic preference. frxUSD has a lower entry floor; USDC and USDT require more gross edge before exposure is created. This is not hard sequencing.

The aggregate direction boundary is exact:

```text
aggregate price < 1e18: expansion denied; contraction allowed
aggregate price = 1e18: expansion and contraction allowed
aggregate price > 1e18: expansion allowed; contraction denied
```

Malformed or reverting aggregate-oracle responses fail closed.

## Keeper-local governance

Each keeper directly exposes:

```solidity
admin();
emergency_admin();
fee_receiver();
policy();
set_admin(newAdmin);
set_emergency_admin(newEmergencyAdmin);
set_fee_receiver(newFeeReceiver);
set_policy_contract(newPolicy);
```

Only the current keeper admin may update these values. Admin and emergency admin must remain distinct. A replacement Policy must contain code. Because admission requires two-way binding, governance must coordinate `set_policy_contract` with list removal/addition; the keeper fails closed for expansion during any gap.

`admin` may configure policy parameters, execute recovery calls, pause or unpause, and use the policy-gated external draw. `emergency_admin` may only pause.

## External execution modules

Routing and arbitrage remain outside the core. The keeper admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The draw requires Policy expansion admission, open pauses, elapsed delay, healthy retained backing, a requested amount within local imbalance, sufficient idle crvUSD, and resulting debt within both the keeper cap and ControllerFactory ceiling. It records debt and updates the shared intervention timestamp before transferring exactly the requested amount.

The draw cannot prove that an external module returns LP backing. A production integration must make the draw, external execution, backing return, and postconditions atomic. `reduce_deployed_crvusd(amount)` is the keeper-admin inverse bookkeeping operation.

## Donations, profit, and surplus

Loose paired-token donations can be swept into LP. Admission denial sets their crvUSD match to zero rather than allowing debt growth through a side path. Donation value is excluded from caller-profit attribution.

`withdraw_profit()` first settles loose paired-token donations, then transfers all claimable idle crvUSD to the keeper's current local `fee_receiver`. The bounded overload performs the same accounting with a caller-supplied transfer cap. Both remain callable in contraction regimes.

Entry and normal-contraction floors apply to gross realized profit before keeper compensation and are independent:

| Profile | `entryMinProfitPpm` | `normalExitMinProfitPpm` |
|---|---:|---:|
| frxUSD | `10` (`0.1 bp`) | `150` (`1.5 bp`) |
| USDC / USDT | `300` (`3 bp`) | `80` (`0.8 bp`) |

Every contraction requires strictly positive gross realized profit before compensation, even when the configured floor is zero. Break-even and loss-making withdrawals are never permitted.

At the initial global `3_000 bps` keeper share, the `0.1 bp` frxUSD entry boundary splits into `0.03 bp` for the caller and `0.07 bp` retained by the protocol. The `3 bp` USDC/USDT boundary splits into `0.9 bp` and `2.1 bp`.

## Deployment

The environment-free deployment script performs seven monotonic CREATEs:

1. `PegKeeperPolicy` owned directly by the Curve Ownership Agent;
2. frxUSD/USD Chainlink adapter;
3. USDC/USD Chainlink adapter;
4. USDT/USD Chainlink adapter;
5. standalone frxUSD PegKeeperV3;
6. standalone USDC PegKeeperV3;
7. standalone USDT PegKeeperV3.

Each keeper is complete at construction with final roles and selected Policy. There is no temporary implementation, deployer-owned configuration phase, ownership handoff, acceptance nonce, or post-deploy keeper setup transaction. The Policy list is intentionally empty after deployment. Every keeper is unpaused, debt-free, and has a zero ControllerFactory allocation until governance acts.

The deployment JSON records the Policy, three oracle adapters, and three keeper addresses.

## Canonical launch proposal

The proposal contains ten actions:

1. add all three keepers to `PegKeeperPolicy` in one batch;
2. register each keeper in the current aggregate monetary policy;
3. register each keeper in the legacy aggregate monetary policy;
4. assign each keeper its ControllerFactory ceiling.

That is one Policy action, six monetary-policy registrations, and three ceiling assignments.

| Paired token | AMM | Liquidity ABI | Retained oracle | Local cap | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---:|---:|---:|---:|
| frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD/USD | 150m | 150m | 0.1 bp | 1.5 bp |
| USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC/USD | 150m | 150m | 3 bp | 0.8 bp |
| USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT/USD | 150m | 150m | 3 bp | 0.8 bp |

## Runtime identity

Pinned Vyper `0.4.3`, `--optimize codesize`, Prague:

```text
PegKeeperV3 version:       3.0.0 (numeric tuple: 3, 0, 0)
standalone initcode:      19,545 bytes
runtime core:            16,987 bytes
standalone runtime:      17,019 bytes
EIP-170 headroom:         7,557 bytes
runtime core hash:
0x3ea6b15c5e12d39aecf1f98e99076598f8ff85cadba14cb29b403e61d8e0db34
mainnet runtime hash (canonical crvUSD immutable suffix):
0x147f13c1e456fa7ff0fdda157ec3e68ab06b54eb6cc38eb43c10d5aa78c5257a

PegKeeperPolicy runtime:   2,947 bytes
policy hash:
0xe4388d617ce6babcb14d56859da66b68f4978dcf32c34adb8ac2f01559f279d0
```

## Verification

```bash
git submodule update --init --recursive
make setup
ETH_RPC_URL=https://an-archive-rpc.example make check
```

Coverage includes fixed- and dynamic-array liquidity dispatch, amountless expansion/contraction, V2-compatible update/profit views, ERC-4626 valuation, donations, surplus, keeper-local role changes, Policy binding, V2-style list lifecycle and pop-and-swap removal, independent admission, external draw accounting, preview/execution parity, runtime pins, ABI parity, stateful invariants, deployment JSON, and full Curve ownership-vote execution.

The pinned frxUSD canary uses the production `10 ppm` entry and `150 ppm` exit profile. It exercises canonical expansion and exact-output contraction under the `20%` rule without weakening the profit floor, and verifies Policy direction, measured deltas, debt reduction, final solvency, ControllerFactory funding, idle-allocation burning, residual rugging, and the persistent ControllerFactory allowance.

The existing `deployments/mainnet/PegKeeperV3-release.json`, `docs/pegkeeper-v3-release-checklist.md`, and `scripts/verify-release-manifest.py` predate this source candidate. They remain frozen and must be regenerated from the final committed source snapshot before release.

## Main files

```text
src/vyper/PegKeeperV3.vy
src/vyper/PegKeeperPolicy.vy
src/vyper/ChainlinkStablecoinOracle.vy
src/interfaces/IPegKeeperV3.sol
src/interfaces/IPegKeeperPolicy.sol
script/DeployPegKeeperV3.s.sol
script/PegKeeperV3ReleaseCanary.s.sol
script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol
docs/pegkeeper-v3-spec.md
docs/pegkeeper-v3-suggested-launch-parameters.md
```
