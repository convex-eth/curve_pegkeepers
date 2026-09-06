# Curve PegKeeper V3

Foundry/Vyper workspace for Curve crvUSD PegKeeper research, V2 migration testing, and an unreleased direct-liquidity PegKeeperV3 candidate.

> **Status:** unreleased version `3.0.0` on branch `main` is not deployed. Nothing in this repository authorizes deployment, allocation, registration, activation, governance execution, or broadcast.

## What a PegKeeper does

A PegKeeper uses crvUSD allocated by the ControllerFactory to rebalance a two-coin Curve pool:

- when crvUSD is scarce, it deposits crvUSD and records the amount as debt;
- when crvUSD is abundant, it burns held LP through a one-coin crvUSD withdrawal and reduces debt;
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
        -> remove_liquidity_one_coin(..., crvUSD)
        -> idle crvUSD
```

The Factory derives the paired token from the AMM. For ERC-4626 paired tokens, it derives the retained backing asset through `asset()` and values loose shares with `convertToAssets()`. Held LP is valued only with `get_virtual_price()`; applying the ERC-4626 rate again would double-count it.

Expansion, donation settlement, and contraction use measured token/LP deltas, temporary exact approvals reset to zero, quote-derived slippage floors, gross-before-reward accounting, and final backing-versus-debt solvency.

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
- priority filtering over the Factory's active keeper set.

The Factory exposes:

```solidity
policy()
activePegKeeperCount()
activePegKeeperAt(index)
is_active(keeper)
```

Factory ownership can replace a policy only after the replacement is bound to that Factory. Deactivation blocks new expansion but does not block contraction, so an inactive keeper can wind down.

### Three-layer expansion priority

The candidate threshold is `8_000 bps` (`80%`).

1. **Primary — frxUSD:** may expand whenever its own local probe passes.
2. **Secondary — sUSDe:** may expand when locally viable and the primary is either unavailable or at least 80% utilized.
3. **Tertiary — USDC and USDT:** may expand only when locally viable, the primary is unavailable, and every active secondary is unavailable.

Primary utilization is:

```text
primary.debt()
-----------------------------------------------
min(primary.max_deployed_crvusd(),
    ControllerFactory.debt_ceiling(primary))
```

The policy deliberately does not reconstruct allocation as `crvUSD.balanceOf(primary) + debt()`: a direct token donation could otherwise inflate the denominator and grief secondary admission.

`can_expand_without_policy()` is the non-recursive keeper probe. It checks pause state, intervention delay, local imbalance, retained-backing oracle, capacity, velocity, and minimum-size preview economics. Policy calls isolate a reverting predecessor as unavailable, allowing a lower tier to operate.

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
- independently enforces expansion/global pauses, minimum amount, delay, retained-oracle health, and the requested amount's local imbalance bound;
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

| Profile | `entryMinProfitPpm` | `normalExitMinProfitPpm` |
|---|---:|---:|
| frxUSD / sUSDe | `10` (`0.1 bp`) | `500` (`5 bp`) |
| USDC / USDT last resort | `500` (`5 bp`) | `100` (`1 bp`) |

The last-resort profile makes USDC/USDT more expensive to enter and easier to unwind. `keeperProfitShareBps` remains `3_000` for every candidate keeper.

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

Every deployed keeper is added to the active list and starts with expansion, contraction, and global execution paused.

The environment-free dependency deployer performs seven monotonic CREATEs:

1. locked `PegKeeperV3` implementation;
2. `PegKeeperPolicy`;
3. `PegKeeperV3Factory`;
4. frxUSD/USD Chainlink adapter;
5. USDe/USD Chainlink adapter;
6. USDC/USD Chainlink adapter;
7. USDT/USD Chainlink adapter.

The policy is intentionally unbound until the governance proposal executes its first action. No keeper can be deployed through the Factory while the policy is unbound.

## Canonical paused launch proposal

The current proposal creates four direct keepers:

| Tier | Paired token | AMM | Liquidity ABI | Retained oracle | Local cap | Initial ceiling | Entry floor | Contraction floor |
|---|---|---|---|---|---:|---:|---:|---:|
| Primary | frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD/USD | 20m | 20m | 0.1 bp | 5 bp |
| Secondary | sUSDe | `0x57064F49Ad7123C92560882a45518374ad982e85` | dynamic | USDe/USD | provisional 20m | **0** | 0.1 bp | 5 bp |
| Tertiary | USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC/USD | 20m | 20m | 5 bp | 1 bp |
| Tertiary | USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT/USD | 20m | 20m | 5 bp | 1 bp |

The proposal leaves all four fully paused. It would deploy and register sUSDe without a production debt ceiling; governance must remeasure live liquidity and independently choose its local cap and ControllerFactory ceiling before activation.

## Runtime identity

Pinned Vyper `0.3.10`, `--optimize codesize`, Shanghai:

```text
PegKeeperV3 version:       3.0.0 (numeric tuple: 3, 0, 0)
implementation initcode: 17,847 bytes
implementation runtime:  17,764 bytes
EIP-170 headroom:          6,812 bytes
implementation hash:
0xcef94a7ce7d9c25978a7866c4fb82045191148e8fdc05f97e24bfbc9cb4292ff

PegKeeperPolicy runtime:   4,394 bytes
policy hash:
0x958aef56c99aefc7f1f3fd7a39097d71d04a5dcfe51993a6488f1df53e7c7078

Factory semantic runtime:  3,875 bytes
Factory deployed runtime:  3,939 bytes
Factory semantic hash:
0x73b019397ebccae92946c77188a3cf07577efc3b3ded1fb331774cae36a1bbb0
```

The detached preview module has been removed; preview logic is back in the core.

## Verification

```bash
git submodule update --init --recursive
make setup
ETH_RPC_URL=https://an-archive-rpc.example make check
```

Coverage includes both fixed- and dynamic-array liquidity dispatch, direct expansion, ERC-4626 valuation, donations, surplus, policy priority, active-list lifecycle, policy replacement, admin draw accounting, preview/execution parity, contraction, runtime pins, ABI parity, stateful invariants, unified deployment JSON, full Curve ownership-vote execution, a live sUSDe dynamic-array expansion, and real fixed-array deposits through the proposed USDC/USDT pools under explicit fork-only eligibility and valuation fixtures.

The pinned frxUSD structural canary uses the frxUSD production `500 ppm` exit policy for all earlier checks, then sets the normal-exit floor to zero on the fork only because that historical pool state offers no executable `5 bp` exit. It still exercises the real one-coin withdrawal, policy direction, measured deltas, debt reduction, and final solvency. Unit tests separately pin the exact production exit-profit boundary.

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
