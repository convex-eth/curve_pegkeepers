# PegKeeper V3 suggested launch parameters

Status: unreleased `3.0.0` candidate. This document does not authorize deployment, allocation, registration, activation, governance execution, or broadcast.

## Candidate keeper set

All keepers use their own crvUSD/paired-token pool directly. There are no routes or intermediate swaps.

| Priority | Keeper | AMM | Liquidity ABI | Paired token | Retained backing | Local max | Initial ControllerFactory ceiling |
|---|---|---|---|---|---|---:|---:|
| Primary | frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD | frxUSD | 20m | 20m |
| Secondary | sUSDe | `0x57064F49Ad7123C92560882a45518374ad982e85` | dynamic | sUSDe | USDe | provisional 20m | **0** |
| Tertiary | USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC | USDC | 20m | 20m |
| Tertiary | USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT | USDT | 20m | 20m |

Token addresses:

```text
crvUSD  0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
frxUSD  0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
sUSDe   0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
USDe    0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
USDC    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT    0xdAC17F958D2ee523a2206206994597C13D831ec7
```

The proposal deploys/configures/registers sUSDe but deliberately assigns no production debt ceiling. Its `20m` local maximum is a placeholder, not funding. Governance must remeasure pool depth and explicitly choose both values before activation.

## Shared deployment configuration

| Parameter | Candidate value |
|---|---:|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| Factory/Policy owner | Curve Ownership Agent `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| emergency admin | `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| fee receiver | `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| AMM execution buffer | `3 bps` |
| priority utilization threshold | `8_000 bps` |

The aggregate crvUSD oracle is owned by `PegKeeperPolicy`, not the Factory:

```text
0x18672b1b0c623a30089A280Ed9256379fb0E4E62
```

## Three-layer policy

### Primary

frxUSD can expand whenever its own local execution checks pass. While active, unpaused, backed by a healthy oracle, funded, and below 80% of its effective cap, it retains priority even when pool imbalance, delay, velocity, or entry economics temporarily prevent another expansion.

### Secondary

sUSDe can expand when its local execution checks pass and frxUSD no longer retains priority. frxUSD releases priority only when it is unset, inactive or misbound, globally or expansion-paused, below its retained-backing oracle floor, unfunded, or at least 80% utilized.

Effective cap is the tighter of the keeper-local maximum and ControllerFactory ceiling. Raw crvUSD balance is not used.

### Tertiary

USDC or USDT can expand only when:

- the candidate itself is locally viable;
- frxUSD no longer retains priority; and
- every funded, healthy, unpaused secondary has independently reached 80% utilization or otherwise stopped retaining priority.

Temporary local non-executability never releases a higher tier. A primary expansion that consumes its same-block delay or velocity therefore cannot unlock a secondary, and a secondary expansion cannot unlock the tertiary tier.

This intentionally makes plain non-yielding pools last-resort liquidity.

Deactivated keepers cannot expand. They can still contract and wind down.

## Global policy

| Parameter | Launch value |
|---|---:|
| `keeperProfitShareBps` | `3_000` |

`PegKeeperPolicy.keeper_profit_share_bps(keeper)` returns this one owner-managed value for all current keepers. The keeper argument is retained for future policy logic but is not used by this release. Updating or replacing the active policy changes the reward share immediately for every existing keeper.

## Keeper-local policy

| Parameter | frxUSD / sUSDe | USDC / USDT |
|---|---:|---:|
| `entryMinProfitPpm` | `10` (`0.1 bp`) | `500` (`5 bp`) |
| `normalExitMinProfitPpm` | `500` (`5 bp`) | `100` (`1 bp`) |
| `minExpansionAmount` | `10_000e18` | `10_000e18` |
| `maxInterventionShareBps` | `3_333` | `3_333` |
| `minInterventionDelay` | `12` seconds | `12` seconds |
| `maxExpansionBurstBps` | `500` (`5%` of local max) | `500` (`5%` of local max) |
| `expansionRefillPeriod` | `300` seconds | `300` seconds |
| retained-backing floor | `0.999e18` | `0.999e18` |

Both configured profit floors apply to gross realized profit before keeper compensation. With the initial global `3_000 bps` keeper share, a `5 bp` qualifying edge pays `1.5 bp` to the caller and leaves `3.5 bp` with the protocol.

Entry and normal-contraction floors are independent; no ordering constraint is intended. The last-resort USDC and USDT keepers require a 5 bp entry edge but only a 1 bp contraction edge. This makes their exposure more expensive to enter and independently executable at a lower positive contraction edge; it does not enforce contraction ordering between keepers.

`maxInterventionShareBps` limits direct expansion to one third of the normalized paired-token surplus over crvUSD and limits contraction quote/receipt to one third of normalized crvUSD excess.

The velocity bucket counts every actual crvUSD debt increase, including donation matching, surplus claims, and policy-gated external draws.

The Factory admin may tune each keeper through `set_velocity_policy`. A zero burst disables new velocity capacity; the refill period must be nonzero. Velocity and local-cap updates checkpoint pressure under the old settings before applying the new values.

## Retained-backing oracles

| Keeper | Chainlink proxy | Adapter max delay | Minimum |
|---|---|---:|---:|
| frxUSD | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | `26 hours` | `0.999e18` |
| sUSDe backing USDe | `0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961` | `25 hours` | `0.999e18` |
| USDC | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | `26 hours` | `0.999e18` |
| USDT | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | `26 hours` | `0.999e18` |

For sUSDe, loose shares use `convertToAssets()` for normalized balance calculations. Held LP uses only pool virtual price. The USDe/USD adapter is an independent retained-backing floor; it does not multiply LP value by the sUSDe share rate.

## Direct expansion

Every keeper deposits directly into its own AMM:

```text
requested X crvUSD
+ D crvUSD matching selected paired-token donation
+ donated paired token
-> keeper AMM LP
```

There is no target swap, `setPaths`, route-loss parameter, Frax mint step, 3pool hop, or detached preview call.

## External modules

If governance later wants routed arbitrage, it belongs in a separate module. The keeper exposes:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The draw is Factory-admin-only, policy-gated, cap/ceiling/balance/velocity bounded, and recorded as debt before transfer. Any module using it must return backing and verify final state atomically. Do not split a draw and backing return across transactions.

## Deployment/proposal sequence

Deployment sender sequence:

1. deploy the locked keeper implementation;
2. deploy policy and Factory with the deployment sender as initial owner and keeper admin;
3. deploy the frxUSD/USD, USDe/USD, USDC/USD, and USDT/USD adapters;
4. bind policy to Factory;
5. deploy and configure all four unpaused keepers with zero ControllerFactory allocation and verify each keeper's unlimited crvUSD allowance to the ControllerFactory;
6. assign the primary, secondary, and tertiary tiers;
7. change the Factory's dynamic keeper admin to the Curve Ownership Agent; and
8. set the Curve Ownership Agent as pending owner of both Factory and policy, freezing old-owner configuration and recording the acceptance nonces. A corrected recipient increments its nonce and invalidates any already-built acceptance proposal.

Proposal sequence:

1. accept Factory ownership;
2. accept policy ownership;
3. register all four keepers in both aggregate monetary policies;
4. assign 20 million crvUSD ControllerFactory ceilings to frxUSD, USDC, and USDT; and
5. leave sUSDe at a zero ceiling.

The proposal contains 13 actions. It does not deploy or configure keepers, toggle pause flags, remove V2 keepers, change a V2 Regulator, or edit aggregate-oracle membership. The proposal validates the complete preconfigured state and rejects a paused, prefunded, mutated, mis-owned, or incorrectly wired candidate before producing calldata.

## V2 coexistence and later removal

The launch proposal appends each zero-debt V3 keeper to both aggregate monetary policies while leaving every V2 keeper registered. Both registrations are required: the oldest live sfrxETH controller still uses the legacy policy, while the other live controllers use the current policy. Each policy calls `debt()` on every registered keeper. Adding zero-debt V3 keepers therefore preserves the aggregate PegKeeper debt input and calculated rates; assigning a ceiling then supplies the crvUSD that makes an unpaused keeper operational.

A later full-system V2 retirement should be separately authorized and ordered as follows:

1. Bring the preconfigured V3 keepers online through ownership acceptance, dual-policy registration, and the selected nonzero ceilings.
2. Set the old V2 Regulator to `Killed.Provide`. This globally forbids every registered V2 keeper from expanding while leaving the Regulator's normal withdrawal path available.
3. Set every V2 ControllerFactory debt ceiling to zero. This burns currently idle crvUSD and prevents new Factory allocation, but it does not burn crvUSD returned by later LP contraction.
4. Leave each V2 keeper address in both aggregate monetary policies and leave the old Regulator list intact while debt unwinds. The monetary policies must continue counting nonzero `debt()`. There is no need to remove or repoint V2 keepers when the entire Regulator is being retired.
5. Allow V2 LP positions to contract when the old Regulator's normal aggregate-price and local-price checks permit it. After contractions, call permissionless `ControllerFactory.rug_debt_ceiling(v2Keeper)` to burn returned crvUSD and reduce residual allocation; repeat as necessary.
6. Once both keeper debt and ControllerFactory residual allocation are zero, remove the V2 keeper from both monetary policies if desired. The abandoned old Regulator may retain its stale keeper list permanently because V3 does not use it.

`PegKeeperOffboarding` remains an optional per-keeper path when V2 keepers are retired asynchronously or governance wants withdrawal eligibility without the old Regulator's aggregate-price gate. It is not required for an all-at-once V2 shutdown.

The monetary policies remove keepers by address and compact their arrays with the tail entry, so removing several zero-debt keepers does not require an index order. Removing an indebted keeper is unsafe: the legacy policy immediately stops counting that debt, while the current policy stops feeding it into subsequent debt-ratio EMA updates.

The aggregate crvUSD oracle is a separate pool-source registry, not a PegKeeper registry. Replacing a keeper does not imply adding or removing its pool there. If a future proposal independently removes multiple oracle pools, `remove_price_pair(index)` swap-pops by numeric index; calls must use descending snapshot indices or recompute the live index after every removal. The contract also leaves stale data in `price_pairs(index)` beyond its private active count, so a nonzero getter alone does not prove that a pair remains active.

## Launch verification

Before authorization:

1. Reconfirm implementation, policy, Factory, keeper, and oracle-adapter identities.
2. Reconfirm all pool coin orders, selected fixed/dynamic liquidity ABI modes, rate behavior, virtual prices, fee parameters, balances, and one-coin quote behavior.
3. Reassess every local max and ControllerFactory debt ceiling against current pool depth.
4. Confirm the deployment sender still owns Factory and policy, Curve is pending owner of both, Curve is already the dynamic keeper admin, all four keepers are unpaused and debt-free, and every ControllerFactory ceiling is zero.
5. Keep sUSDe at zero until governance deliberately funds it.
6. Simulate the exact 13-action vote and verify that frxUSD, USDC, and USDT receive their ceilings only after ownership acceptance and dual-policy registration.
7. Immediately after execution, run bounded expansion and contraction canaries and verify every balance/debt delta, including returned-crvUSD burning through permissionless `rug_debt_ceiling` and the keeper's ControllerFactory allowance.
8. Retire V2 globally with `Killed.Provide`, zero ceilings, and periodic `rug_debt_ceiling` calls when separately authorized. If any overlap between V2 and V3 expansion is unacceptable, include those V2 shutdown actions in the same atomic vote before the V3 ceiling assignments.

A current-block canary is mandatory before any production action. Pinned-fork success is evidence of code behavior, not authorization or current market safety.
