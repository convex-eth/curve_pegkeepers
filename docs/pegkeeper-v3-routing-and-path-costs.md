# PegKeeper V3 LP-yield routing and pool assumptions

Status: unreleased route research for the `lp-yield` branch. No production action is authorized.

## Separation of responsibilities

V3 uses two pool roles:

- `targetAmm`: trades crvUSD into the keeper-specific target asset during expansion;
- `yieldAmm`: receives crvUSD plus `yieldToken`, issues the LP backing, and provides the fixed one-coin crvUSD contraction.

Only target-to-yield expansion routing is configurable. There is no contraction route.

## Selected backing pool

```text
Pool / LP: 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1
coins(0):  frxUSD  0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
coins(1):  crvUSD  0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
LP decimals: 18
```

Live calls confirmed that this pool uses the StableSwap-NG dynamic-array deposit ABI:

```text
calc_token_amount(uint256[2],bool) -> reverted
calc_token_amount(uint256[],bool)  -> succeeded
calc_withdraw_one_coin(uint256,int128) -> succeeded
get_virtual_price() -> succeeded
```

V3 therefore deliberately calls:

```solidity
calc_token_amount(uint256[] amounts, bool isDeposit)
add_liquidity(uint256[] amounts, uint256 minLp)
```

Using the fixed-array selector would compile and pass a permissive mock while reverting against the selected production pool. The unit mock exposes only the dynamic-array selector, and the pinned canary exercises the live pool.

## Selected expansion routes

### frxUSD

```text
targetAmm == yieldAmm
route = []
requested crvUSD -> direct one-sided LP deposit
```

No crvUSD/frxUSD swap is performed first. If donated frxUSD exists, V3 adds it with equal-value additional crvUSD in the same deposit.

### USDC

```text
crvUSD -> USDC in targetAmm
USDC -> frxUSD through Frax mint custodian
frxUSD + matched crvUSD -> yieldAmm LP
```

### USDT

```text
crvUSD -> USDT in targetAmm
USDT -> USDC in Curve 3pool
USDC -> frxUSD through Frax mint custodian
frxUSD + matched crvUSD -> yieldAmm LP
```

No path may loop through crvUSD between the initial target-AMM intervention and `yieldToken` acquisition.

## Route checks

Each target and expansion step is exact-input and enforces:

- immediate venue quote;
- quote-relative minimum output;
- normalized absolute value floor;
- exact measured input spending;
- measured output receipt;
- exact temporary allowance reset to zero;
- token continuity and fixed endpoint validation.

The full target-to-yield route also enforces `expansionMaxRouteLossBps`. Route output is not final backing until it and matched crvUSD have been deposited into `yieldAmm` and measured LP tokens have been received.

Any failure reverts the initial target swap, path execution, LP deposit, debt accounting, velocity pressure, and rewards. There is no target-retention fallback.

## Matched-liquidity cost

A route quote must be evaluated together with the matched LP leg.

For a first-leg amount `X` and final yield value `Y`:

```text
crvUSD consumed = X + Y
LP deposit       = Y crvUSD + yieldToken worth Y
```

Around par, `Y ~= X`; a `500,000 crvUSD` target trade therefore consumes about `1,000,000 crvUSD` of velocity and capacity. Route ladders that show only target-to-yield cost are insufficient for sizing this implementation.

A yield-token donation `D` adds another `D` of matched crvUSD consumption. An oversized unsolicited donation can make an expansion revert until governance recovers it through `execute()` or sufficient idle balance/capacity becomes available. The donation does not become keeper profit.

## LP accounting assumption

Persistent backing is:

```text
floor(lpBalance * virtualPrice / 1e18)
```

This is not a market-price oracle. It assumes:

1. both pool coins are governance-approved equivalent stable assets;
2. the pool correctly includes rate-provider or wrapped-share appreciation in virtual price;
3. the pool's accounting and LP token are not compromised;
4. one-coin exit economics are checked independently.

For an ERC-4626 yield coin, V3 uses `convertToAssets()` only to size the matched crvUSD for loose shares entering the LP. Once LP tokens exist, virtual price is used once. Multiplying LP value by the ERC-4626 share rate again would double-count appreciation.

## Static contraction economics

Contraction does not reverse the expansion route. It burns held LP and requests crvUSD only:

```text
quote = calc_withdraw_one_coin(lpAmount, crvUsdIndex)
min   = quote * (10_000 - yieldAmmExecutionBufferBps) / 10_000
remove_liquidity_one_coin(lpAmount, crvUsdIndex, min)
```

The executable quote protects slippage. The pre/post complete LP position at separate virtual-price snapshots determines backing value removed. The call reverts if the pool's own repricing makes that value delta negative or if post-reward crvUSD does not exceed value removed by the configured exit margin.

The pinned canary makes crvUSD sufficiently abundant in the backing pool before exercising contraction. Without a favorable imbalance, single-coin withdrawal fees can make a contraction correctly fail the positive-profit floor.

## Current addresses

| Role | Address |
|---|---|
| frxUSD/crvUSD yield AMM | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` |
| USDC/crvUSD target AMM | `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` |
| USDT/crvUSD target AMM | `0x390f3595bCa2Df7d23783dFd126427CCeb997BF4` |
| Curve 3pool | `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` |
| Frax mint custodian | `0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c` |
| USDC/USDT oracle pool | `0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85` |

FraxNet redemption accounts and RWA redemption capacity are irrelevant to this architecture because contraction never redeems frxUSD through a configured route.

## Pre-activation checks

1. Verify target and yield pool code, coin order, decimals, fee parameters, dynamic-array ABI, balances, virtual price, and rate providers.
2. Re-run target and expansion-path quote ladders at total matched-liquidity sizes.
3. Reconfirm Frax mint fee, cap, minted amount, `maxDeposit()`, proxy implementation, and authorization.
4. Simulate balanced and one-sided LP additions with measured token and LP deltas.
5. Simulate one-coin crvUSD withdrawal across normal and stressed pool states.
6. Verify all temporary allowances return to zero.
7. Size local cap and velocity from total crvUSD consumption, not first-leg amount.
8. Run a current-block end-to-end fork canary before any governance action.
