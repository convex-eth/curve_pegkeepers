# Curve PegKeeper V3

Foundry/Vyper workspace for Curve crvUSD PegKeeper research, V2 migration testing, and an unreleased direct-liquidity PegKeeperV3 candidate.

> **Status:** unreleased version `3.0.0` on branch `main` is not deployed. Nothing in this repository authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## What a PegKeeper does

A PegKeeper uses crvUSD allocated by the ControllerFactory to rebalance a two-coin Curve pool:

- when crvUSD is scarce, it deposits crvUSD and records the amount as debt;
- when crvUSD is abundant, it removes the canonical exact crvUSD amount and reduces debt;
- it retains the LP token as backing and pays callers only from realized accounting profit.

PegKeepers are not a hard peg guarantee. Their effectiveness depends on pool depth, oracle health, policy admission, available debt capacity, and executable economics.

## Direct-only V3 architecture

Each `PegKeeperV3` is fixed to one Curve pool containing crvUSD and one paired token. Initialization also fixes whether that pool uses dynamic `uint256[]` or fixed `uint256[2]` liquidity calls. It has no swap router, target AMM, path storage, route adapter, or detached preview module.

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

The Factory derives the paired token from the AMM. For ERC-4626 paired tokens, it derives the retained backing asset through `asset()` and values loose shares with `convertToAssets()`. Held LP is valued only with `get_virtual_price()`; applying the ERC-4626 rate again would double-count it.

Expansion, donation settlement, and contraction use measured token/LP deltas, temporary exact approvals reset to zero, quote-derived slippage bounds, gross-before-reward accounting, and final backing-versus-debt solvency. Contraction preview values the expected `calc_token_amount(..., false) + 1 LP wei` burn; the larger buffered burn remains execution-only, where actual profit and solvency are rechecked.

Ordinary interventions do not accept a caller-selected amount. `expand_supply()` and `contract_supply()` execute the sole current crvUSD amount: the configured `20%` share of normalized local imbalance, further bounded by available balance/backing, capacity, and expansion velocity. `update()` selects the local direction and executes the same canonical action for V2 keeper compatibility; like V2, it returns zero rather than reverting when another caller already consumed the intervention delay. `preview_expansion()` and `preview_contraction()` apply the complete economics and solvency checks; `available_expansion()` and `available_contraction()` expose current caps; `estimate_caller_profit()` returns zero unless a canonical preview succeeds. Caller-selected dust cannot consume the shared intervention timer while a larger canonical action is available.

## PegKeeperPolicy

Configurable admission logic lives in `PegKeeperPolicy`, not `PegKeeperV3Factory`.

Every keeper dynamically asks:

```solidity
factory.policy().can_expand(address(this))
```

The policy owns:

- the aggregate crvUSD oracle and exact direction gate;
- a three-tier keeper classification;
- the primary-utilization threshold;
- the global keeper profit share;
- priority filtering over the Factory's active keeper set.

Every reward path reads `factory.policy().keeper_profit_share_bps(address(this))` at execution time. The current policy ignores the address and returns one owner-managed value bounded to `10_000 bps`. Replacing or updating policy therefore changes the reward rule for every existing keeper without a keeper migration.

The Factory exposes:

```solidity
policy()
activePegKeeperCount()
activePegKeeperAt(index)
is_active(keeper)
```

Factory ownership can replace a policy only after the replacement is bound to that Factory. Deactivation blocks new expansion but does not block contraction, so an inactive keeper can wind down.

### Three-layer expansion priority

The shared priority threshold is `8_000 bps` (`80%`).

1. **Primary — frxUSD:** may expand whenever its own local execution checks pass.
2. **Secondary — sUSDe:** may expand when locally executable after the primary stops retaining priority.
3. **Tertiary — USDC and USDT:** may expand when locally executable only after the primary and every funded secondary stop retaining priority.

A higher-tier keeper retains priority while it is active and Factory-bound, unpaused, backed by a healthy retained-backing oracle, funded with a nonzero effective cap, and below 80% utilization. Policy checks those states directly. Temporary local non-executability from pool imbalance, intervention delay, velocity, loose balance, AMM quote, or minimum-profit economics does not release priority.

Priority utilization for each higher-tier keeper is:

```text
keeper.debt()
-----------------------------------------------
min(keeper.max_deployed_crvusd(),
    ControllerFactory.debt_ceiling(keeper))
```

The policy deliberately does not reconstruct allocation as `crvUSD.balanceOf(keeper) + debt()`: a direct token donation could otherwise inflate the denominator and grief lower-tier admission. An unset, inactive, paused, oracle-unhealthy, or zero-capacity higher tier does not block the next tier.

`can_expand_without_policy()` remains the non-recursive execution probe for the candidate keeper. It checks pause state, intervention delay, local imbalance, retained-backing oracle, capacity, velocity, and canonical-action preview economics. Policy no longer uses that transient result to decide whether a higher tier retains priority.

The aggregate direction boundary remains exact:

```text
aggregate price < 1e18: expansion denied; contraction allowed
aggregate price = 1e18: expansion and contraction allowed
aggregate price > 1e18: expansion allowed; contraction denied
```

Malformed or reverting aggregate-oracle responses fail closed.

## External execution modules

Routing and arbitrage are intentionally outside the core. An authorized module or governance batch can use the existing `execute()` recovery/execution hook and the new policy-gated draw:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

`borrow_crvusd`:

- requires the dynamic Factory admin;
- requires `policy.can_expand(keeper)`;
- independently enforces expansion/global pauses, delay, retained-oracle health, and the requested amount's local imbalance bound;
- enforces the keeper cap and ControllerFactory debt ceiling;
- requires sufficient idle crvUSD;
- consumes expansion velocity and updates the intervention timestamp;
- increases `deployed_crvusd` and transfers exactly the requested amount.

The draw cannot prove LP return because funds leave for an external module. A production integration must perform the draw, swaps, LP delivery, and any required postcondition atomically in its own governance/module transaction. A half-completed multi-transaction sequence would leave recorded debt without returned LP backing.

`reduce_deployed_crvusd(amount)` remains the Factory-admin inverse for correcting recorded exposure downward.

## Donations, profit, and surplus

Loose paired-token donations can be swept into LP. Priority denial sets their crvUSD match to zero rather than allowing debt growth through a side path. Donation value is excluded from caller-profit attribution.

`withdraw_profit()` first settles loose paired-token donations, then transfers all claimable idle crvUSD to the Factory's live fee receiver. `withdraw_profit(maxCrvUsdAmount)` performs the same accounting with a caller-supplied transfer bound. Both remain callable during contraction regimes so accrued value is not trapped.

Entry and normal-contraction profit floors are independent:

Both floors apply to gross realized profit before keeper compensation. At the initial global
`3_000 bps` keeper share, the `0.1 bp` preferred entry floor splits into `0.03 bp` for the caller
and `0.07 bp` retained by the protocol; the `3 bp` tertiary entry floor splits into `0.9 bp` and
`2.1 bp`, respectively.

Every contraction requires strictly positive gross realized profit before keeper compensation,
including when governance configures the normal-contraction floor to zero. Break-even and
loss-making withdrawals are never permitted by configuration.

| Profile | `entryMinProfitPpm` | `normalExitMinProfitPpm` |
|---|---:|---:|
| frxUSD primary | `10` (`0.1 bp`) | `150` (`1.5 bp`) |
| sUSDe secondary | `10` (`0.1 bp`) | `110` (`1.1 bp`) |
| USDC / USDT tertiary | `300` (`3 bp`) | `80` (`0.8 bp`) |

The tier profiles make USDC/USDT more expensive to enter and economically easier to unwind, followed by sUSDe and then frxUSD. This is a soft economic bias rather than enforced cross-pool contraction ordering. `PegKeeperPolicy.keeper_profit_share_bps(keeper)` returns the global `3_000` keeper reward share for every candidate. Governance can change that one policy value for all existing keepers; the address argument preserves room for future keeper-aware policy without changing the keeper ABI.

Each keeper's expansion velocity is independently admin-configurable through `set_velocity_policy(maxExpansionBurstBps, expansionRefillPeriod)`. Launch values are `1_000 bps` (`10%`) of the local cap with a `36 second` full linear refill. The bucket buys roughly three blocks for independent backing oracles to react; the separate `20%` local-imbalance action remains binding when tighter. A zero burst disables new velocity capacity; the refill period must be nonzero. Configuration and local-cap changes checkpoint current pressure before applying the new rule, so elapsed time is never retroactively repriced.

## Factory and deployment

`PegKeeperV3Factory` deploys non-upgradeable EIP-1167 proxies against one locked implementation. Its keeper deployment surface is intentionally small:

```solidity
deployPegKeeper(
    address amm,
    bool pairedTokenIsErc4626,
    bool poolUsesDynamicArrays,
    address backingOracle
)
```

Every deployed keeper is added to the active list and starts unpaused. Initialization grants the ControllerFactory unlimited crvUSD allowance so ceiling reductions and permissionless residual rugging can burn returned allocation through `crvUSD.burnFrom`. Before governance assigns a ControllerFactory debt ceiling, its zero allocation prevents expansion and its zero LP/debt position leaves nothing to contract.

The environment-free dependency deployer performs seven monotonic CREATEs:

1. locked `PegKeeperV3` implementation;
2. `PegKeeperPolicy`;
3. `PegKeeperV3Factory`;
4. frxUSD/USD Chainlink adapter;
5. USDe/USD Chainlink adapter;
6. USDC/USD Chainlink adapter;
7. USDT/USD Chainlink adapter.

The deployment sender initially owns the Factory and policy. The deployer binds the policy, creates and configures all four keepers, changes the dynamic keeper admin to the Curve Ownership Agent, and sets that agent as pending owner of both Factory and policy. Starting either pending handoff freezes old-owner configuration. Any recipient correction increments its acceptance nonce and invalidates an already-built proposal, preventing stale deployment state from being accepted during the governance vote. The deployment JSON records every dependency, keeper address, and handoff nonce for independent verification.

## Canonical launch proposal

The current proposal accepts the two ownership handoffs, registers four preconfigured direct keepers, and funds three:

| Tier | Paired token | AMM | Liquidity ABI | Retained oracle | Local cap | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---|---:|---:|---:|---:|
| Primary | frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD/USD | 20m | 20m | 0.1 bp | 1.5 bp |
| Secondary | sUSDe | `0x57064F49Ad7123C92560882a45518374ad982e85` | dynamic | USDe/USD | provisional 20m | **0** | 0.1 bp | 1.1 bp |
| Tertiary | USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC/USD | 20m | 20m | 3 bp | 0.8 bp |
| Tertiary | USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT/USD | 20m | 20m | 3 bp | 0.8 bp |

The proposal contains 13 actions: two ownership acceptances, eight registrations across the current and legacy aggregate monetary policies, and three ControllerFactory ceiling assignments. frxUSD, USDC, and USDT become permissionless immediately when those ceilings supply crvUSD. sUSDe remains inert at a zero ceiling pending a separate liquidity decision.

## Runtime identity

Pinned Vyper `0.4.3`, `--optimize codesize`, Prague:

```text
PegKeeperV3 version:       3.0.0 (numeric tuple: 3, 0, 0)
implementation initcode: 20,056 bytes
implementation runtime:  19,939 bytes
EIP-170 headroom:          4,637 bytes
implementation hash:
0x77afe0eacbc9d7e6c05135c03461ff7ffce729877717e7ee7458ddce71e533c8

PegKeeperPolicy runtime:   5,490 bytes
policy hash:
0x0a377d97e86097ebcbe7fb7f5733a1fa54d29bac01b751f21196b070051ee14e

Factory semantic runtime:  3,963 bytes
Factory deployed runtime:  4,027 bytes
Factory semantic hash:
0xcfc318147ad88458f19543d0a8001ed9b046e72c713501b96839d847b8f6799e
```

The detached preview module has been removed; preview logic is back in the core.

## Verification

```bash
git submodule update --init --recursive
make setup
ETH_RPC_URL=https://an-archive-rpc.example make check
```

Coverage includes fixed- and dynamic-array liquidity dispatch, canonical amountless expansion/contraction, V2-compatible update/profit views, ERC-4626 valuation, donations, surplus, policy priority, active-list lifecycle, policy replacement, admin draw accounting, preview/execution parity, runtime pins, ABI parity, stateful invariants, unified deployment JSON, full Curve ownership-vote execution, and an action-level live sUSDe dynamic-array expansion at a coherent pinned state. A pinned fork test executes exact-crvUSD `remove_liquidity_imbalance` against all four production pools and verifies exact receipt plus the observed one-LP-wei quote/burn difference.

The pinned frxUSD structural canary uses the production `10 ppm` entry and `150 ppm` exit profile throughout. It executes a canonical `200,000 crvUSD` expansion under the `10%` burst and a canonical `240,517.600156528893943305 crvUSD` exact-output contraction under the `20%` intervention rule without weakening the profit floor. It also verifies policy direction, measured deltas, debt reduction, final solvency, real ownership-agent/eDAO-proxy/ControllerFactory funding, idle-allocation burning, permissionless residual rugging, and the keeper's persistent ControllerFactory allowance.

The existing `deployments/mainnet/PegKeeperV3-release.json` and `docs/pegkeeper-v3-release-checklist.md` predate the current `3.0.0` source candidate. They remain untouched in the source batch and must be regenerated from the final committed source snapshot before release.

## Main files

```text
src/vyper/PegKeeperV3.vy
src/vyper/PegKeeperPolicy.vy
src/vyper/PegKeeperV3Factory.vy
src/vyper/ChainlinkStablecoinOracle.vy
src/interfaces/IPegKeeperV3.sol
src/interfaces/IPegKeeperPolicy.sol
src/interfaces/IPegKeeperV3Factory.sol
script/DeployPegKeeperV3.s.sol
script/PegKeeperV3ReleaseCanary.s.sol
script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol
docs/pegkeeper-v3-spec.md
docs/pegkeeper-v3-suggested-launch-parameters.md
```
