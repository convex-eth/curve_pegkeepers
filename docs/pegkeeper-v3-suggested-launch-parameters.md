# PegKeeper V3 suggested launch parameters

Status: unreleased `3.0.0` candidate. This document does not authorize deployment, allocation, registration, activation, governance execution, or broadcast.

## Candidate keeper set

Every keeper is a complete standalone deployment using its own crvUSD/paired-token pool directly. There are no proxies, routes, intermediate swaps, or keeper Factory.

| Keeper | AMM | Liquidity ABI | Paired token | Retained backing | Local max | Initial ControllerFactory ceiling |
|---|---|---|---|---|---:|---:|
| frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | dynamic | frxUSD | frxUSD | 150m | 150m |
| USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | fixed | USDC | USDC | 150m | 150m |
| USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | fixed | USDT | USDT | 150m | 150m |

Token addresses:

```text
crvUSD  0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
frxUSD  0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
USDC    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT    0xdAC17F958D2ee523a2206206994597C13D831ec7
```

## Shared deployment configuration

| Parameter | Candidate value |
|---|---:|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| Policy owner / keeper admin | Curve Ownership Agent `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| keeper emergency admin | `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| keeper fee receiver | `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| AMM execution buffer | `3 bps` |
| aggregate crvUSD oracle | `0x18672b1b0c623a30089A280Ed9256379fb0E4E62` |

Every keeper stores the final admin, emergency admin, fee receiver, and Policy directly at construction. The deployment sender receives no protocol role and performs no post-deploy keeper configuration.

## Policy list and independent admission

`PegKeeperPolicy` is the sole active-keeper registry. Its bounded list mirrors the V2 regulator's structure: owner-only batch add/remove, duplicate and missing-entry rejection, 1-based indices, pop-and-swap removal, moved-index repair, and clean re-addition.

Allocation and expansion require:

- active Policy-list membership;
- `keeper.policy() == policy`;
- the applicable aggregate/local safety checks.

A removed keeper cannot allocate or expand but remains able to contract while it still points to that Policy. This keeps wind-down open.

Every active keeper is evaluated independently. No keeper's utilization, pause state, oracle, delay, imbalance, or profitability blocks another. AMM fees and keeper-local gross-profit floors provide soft economic preference: frxUSD enters at `0.1 bp`, while USDC and USDT require `3 bp`.

The Policy has no hard cross-keeper sequencing.

## Global Policy

| Parameter | Launch value |
|---|---:|
| `keeperProfitShareBps` | `3_000` |
| maximum list length | `8` |
| launch list | frxUSD, USDC, USDT |

`keeper_profit_share_bps(keeper)` returns one owner-managed value for current keepers. The address argument preserves room for future keeper-aware logic.

## Keeper-local policy

| Parameter | frxUSD | USDC / USDT |
|---|---:|---:|
| `entryMinProfitPpm` | `10` (`0.1 bp`) | `300` (`3 bp`) |
| `normalExitMinProfitPpm` | `150` (`1.5 bp`) | `80` (`0.8 bp`) |
| `maxInterventionShareBps` | `2_000` (`20%`) | `2_000` (`20%`) |
| `actionDelay` | `12` seconds | `12` seconds |
| retained-backing floor | `0.999e18` | `0.999e18` |

Both profit floors apply to gross realized profit before keeper compensation. With a `3_000 bps` reward share, the `1.5 bp` and `0.8 bp` exit boundaries pay the caller `0.45 bp` and `0.24 bp`.

Entry and exit floors are independent. The launch profiles make USDC/USDT exposure harder to create and economically easier to unwind than frxUSD exposure. Pool state can still change actual executability.

The `20%` intervention share defines the sole ordinary action amount. Callers cannot select dust clips. `update()` selects direction, `update(address beneficiary)` routes reward to a nonzero beneficiary, and amountless `expand_supply()` / `contract_supply()` expose the same canonical actions.

`actionDelay` is shared across expansion, contraction, `update`, and `borrow_crvusd`. Donation and profit settlement remain timer-independent. Keeper-local and ControllerFactory ceilings independently bound total exposure.

## Retained-backing oracles

| Keeper | Chainlink proxy | Adapter max delay | Minimum |
|---|---|---:|---:|
| frxUSD | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | `26 hours` | `0.999e18` |
| USDC | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` | `26 hours` | `0.999e18` |
| USDT | `0x3E7d1eAB13ad0104d2750B8863b489D65364e32D` | `26 hours` | `0.999e18` |

## Direct expansion and external modules

Every keeper deposits directly into its own AMM:

```text
canonical X crvUSD
+ D crvUSD matching selected paired-token donation
+ donated paired token
-> keeper AMM LP
```

There is no target swap, route-loss parameter, Frax mint step, 3pool hop, or detached preview call.

If governance later wants routed arbitrage, it belongs in a separate module. The keeper-local admin may call:

```solidity
borrow_crvusd(uint256 amount, address receiver)
```

The draw is Policy-gated, cap/ceiling/balance bounded, and recorded as debt before transfer. Any module must return backing and verify final state atomically.

## Deployment and proposal sequence

Deployment performs seven CREATEs in fixed order:

1. deploy `PegKeeperPolicy` with Curve Ownership Agent as owner;
2. deploy frxUSD/USD adapter;
3. deploy USDC/USD adapter;
4. deploy USDT/USD adapter;
5. deploy standalone frxUSD keeper with final roles and Policy;
6. deploy standalone USDC keeper with final roles and Policy;
7. deploy standalone USDT keeper with final roles and Policy.

Post-deployment state:

- Policy list empty;
- keepers unpaused and debt-free;
- ControllerFactory ceilings zero;
- unlimited keeper allowances to ControllerFactory present;
- no pending ownership or setup transaction.

The governance proposal contains ten actions:

1. batch-add frxUSD, USDC, and USDT keepers to Policy;
2. register each in the current aggregate monetary policy;
3. register each in the legacy aggregate monetary policy;
4. assign 150 million crvUSD ControllerFactory ceilings to each.

This is one Policy action, six registration actions, and three ceiling actions. The proposal does not deploy or configure keepers, accept ownership, toggle pauses, remove V2 keepers, change the V2 regulator, or edit aggregate-oracle membership.

## V2 coexistence and later removal

The launch appends each zero-debt V3 keeper to both aggregate monetary policies while leaving V2 registrations intact. Both registrations are required because the oldest live sfrxETH controller still uses the legacy policy while other live controllers use the current policy.

A separately authorized V2 retirement should:

1. activate and fund V3 through the ten-action proposal;
2. set the V2 regulator to `Killed.Provide`;
3. set V2 ControllerFactory ceilings to zero;
4. retain V2 monetary-policy registration while nonzero debt unwinds;
5. permit contraction and call `rug_debt_ceiling` as returned crvUSD accumulates;
6. remove a V2 keeper from monetary policies only after debt and residual allocation are zero.

The aggregate crvUSD oracle remains a separate pool-source registry. Keeper replacement does not imply oracle-source changes.

## Launch verification

Before authorization:

1. Reconfirm Policy, keeper, and adapter runtime identities.
2. Reconfirm pool coin order, ABI mode, rates, virtual prices, fees, balances, and exact-output behavior.
3. Reassess local maxima and ControllerFactory ceilings against current depth.
4. Confirm Policy ownership, empty pre-proposal list, direct keeper roles/Policy binding, unpaused/debt-free state, zero ceilings, and unlimited ControllerFactory allowances.
5. Simulate the exact ten-action vote and verify batch activation precedes registrations and ceilings.
6. Immediately after execution, run bounded expansion/contraction canaries and reconcile every balance/debt delta.
7. Retire V2 only under separate authorization.

A current-block canary is mandatory before any production action. Pinned-fork success proves code behavior, not authorization or current market safety.
