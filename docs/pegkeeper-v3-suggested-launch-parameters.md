# PegKeeper V3 suggested launch parameters

Status: unreleased `3.4.0` candidate. This document does not authorize deployment, allocation, registration, activation, governance execution, or broadcast.

## Candidate keeper set

All keepers use their own crvUSD/paired-token pool directly. There are no routes or intermediate swaps.

| Priority | Keeper | AMM | Paired token | Retained backing | Local max | Initial ControllerFactory ceiling |
|---|---|---|---|---|---:|---:|
| Primary | frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | frxUSD | frxUSD | 20m | 20m |
| Secondary | sUSDe | `0x57064F49Ad7123C92560882a45518374ad982e85` | sUSDe | USDe | provisional 20m | **0** |
| Tertiary | USDC | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` | USDC | USDC | 20m | 20m |
| Tertiary | USDT | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` | USDT | USDT | 20m | 20m |

Token addresses:

```text
crvUSD  0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
frxUSD  0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
sUSDe   0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
USDe    0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
USDC    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
USDT    0xdAC17F958D2ee523a2206206994597C13D831ec7
```

sUSDe is deployed/configured/registered but deliberately receives no production debt ceiling. Its `20m` local maximum is a placeholder, not funding. Governance must remeasure pool depth and explicitly choose both values before activation.

## Shared deployment configuration

| Parameter | Candidate value |
|---|---:|
| ControllerFactory | `0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC` |
| Factory/Policy owner | Curve Ownership Agent `0x40907540d8a6C65c637785e8f8B742ae6b0b9968` |
| emergency admin | `0x467947EE34aF926cF1DCac093870f613C96B1E0c` |
| fee receiver | `0x2dFd89449faff8a532790667baB21cF733C064f2` |
| AMM execution buffer | `3 bps` |
| primary utilization threshold | `8_000 bps` |

The aggregate crvUSD oracle is owned by `PegKeeperPolicy`, not the Factory:

```text
0x18672b1b0c623a30089A280Ed9256379fb0E4E62
```

## Three-layer policy

### Primary

frxUSD can expand whenever its own `can_expand_without_policy()` probe succeeds.

### Secondary

sUSDe can expand when its local probe succeeds and either:

- frxUSD is locally unavailable due to pause, oracle, delay, capacity, local imbalance, or executable economics; or
- frxUSD debt is at least 80% of its effective cap.

Effective cap is the tighter of the keeper-local maximum and ControllerFactory ceiling. Raw crvUSD balance is not used.

### Tertiary

USDC or USDT can expand only when:

- the candidate itself is locally viable;
- frxUSD is unavailable; and
- every active secondary is unavailable.

This intentionally makes plain non-yielding pools last-resort liquidity.

Deactivated keepers cannot expand. They can still contract and wind down.

## Keeper-local policy

| Parameter | Value |
|---|---:|
| `entryMinProfitPpm` | `10` |
| `normalExitMinProfitPpm` | `500` (`5 bp`) |
| `keeperProfitShareBps` | `3_000` |
| `minExpansionAmount` | `10_000e18` |
| `maxInterventionShareBps` | `3_333` |
| `minInterventionDelay` | `12` seconds |
| velocity max burst | `5%` of local max |
| velocity full refill | `300` seconds |
| retained-backing floor | `0.999e18` |

Entry and normal-exit floors are independent; no ordering constraint is intended.

`maxInterventionShareBps` limits direct expansion to one third of the normalized paired-token surplus over crvUSD and limits contraction quote/receipt to one third of normalized crvUSD excess.

The velocity bucket counts every actual crvUSD debt increase, including donation matching, surplus claims, and policy-gated external draws.

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

Dependency deployer CREATE order:

1. locked keeper implementation;
2. policy;
3. Factory;
4. frxUSD/USD adapter;
5. USDe/USD adapter;
6. USDC/USD adapter;
7. USDT/USD adapter.

Proposal sequence:

1. bind policy to Factory;
2. set Factory defaults;
3. deploy each direct keeper;
4. assign primary/secondary/tertiary tier;
5. set retained oracle and keeper-local policy;
6. allocate frxUSD/USDC/USDT debt ceilings;
7. leave sUSDe ceiling at zero;
8. register all four keepers in both aggregate monetary policies;
9. leave all directions paused.

The proposal contains 33 actions and no activation or route action.

## Activation order

If separately authorized:

1. Reconfirm implementation, policy, Factory, and oracle adapter hashes.
2. Reconfirm all pool coin orders, rate behavior, virtual prices, fee parameters, balances, and one-coin quote behavior.
3. Reassess every local max and ControllerFactory debt ceiling against current pool depth.
4. Keep sUSDe at zero until governance deliberately funds it.
5. Confirm all keepers are active in Factory but directions `0`, `1`, and `2` remain paused.
6. Unpause contraction (`1`) first.
7. Unpause global execution (`2`).
8. Run bounded direct expansion/contraction canaries.
9. Unpause expansion (`0`) last.

A current-block canary is mandatory before any production action. Pinned-fork success is evidence of code behavior, not authorization or current market safety.
