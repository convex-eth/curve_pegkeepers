# PegKeeper V3 simple direct-pool launch option

Status: unreleased `lp-yield` alternative. This does not authorize deployment, allocation, registration, activation, governance execution, or broadcast.

## Purpose

This option omits the routed USDC and USDT keepers. It deploys one keeper directly against each selected crvUSD pool and relies on external arbitrage to move value between the pools:

| Keeper | Target AMM | Yield AMM / held LP | Target/yield token | Backing unit | Expansion path |
|---|---|---|---|---|---|
| frxUSD | `0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1` | same pool | frxUSD | frxUSD | `[]` |
| sUSDe | `0x57064F49Ad7123C92560882a45518374ad982e85` | same pool | sUSDe | USDe | `[]` |

Both keepers use the PegKeeperV3 same-pool branch:

```text
expand(X)
    -> no target swap
    -> no typed route
    -> add X crvUSD directly to the keeper's AMM
    -> hold the resulting AMM LP tokens
```

Loose configured yield-token donations may be included by the existing bounded donation-settlement logic. Contraction remains a one-coin LP withdrawal into crvUSD. The proposal contains no route-setting action and leaves expansion, LP contraction, and global execution paused.

## Fixed mainnet identities

```text
crvUSD                 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E
frxUSD                 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29
USDe                   0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
sUSDe                  0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
frxUSD/crvUSD pool     0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1
crvUSD/sUSDe pool      0x57064F49Ad7123C92560882a45518374ad982e85
frxUSD/USD proxy       0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83
USDe/USD proxy         0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961
```

The sUSDe keeper is deployed with `yieldTokenIsErc4626 = true`. The Factory therefore resolves:

```text
targetAsset = sUSDe
yieldToken  = sUSDe
backingAsset = sUSDe.asset() = USDe
```

The sUSDe pool must expose a rate for sUSDe consistent with `sUSDe.convertToAssets(1e18)`. Its virtual price already incorporates that share rate. The retained-backing oracle is consequently USDe/USD, not sUSDe/USD; using sUSDe/USD would count share appreciation twice.

## Deployment package

The alternative uses:

- `script/DeployPegKeeperV3Simple.s.sol` — deploys the preview module, locked implementation, Factory, frxUSD/USD adapter, and USDe/USD adapter; writes `deployments/mainnet/PegKeeperV3-simple-deployment.json`;
- `script/proposals/curve/CurveProposalLaunchPegKeeperV3Simple.s.sol` — validates the dependencies and direct pools, then proposes two paused keeper deployments.

The governance proposal has 14 actions:

1. set common Factory defaults;
2. deploy and configure the direct frxUSD keeper;
3. assign its debt ceiling;
4. register it in both monetary policies;
5. deploy and configure the direct sUSDe keeper;
6. register it in both monetary policies without assigning an initial debt ceiling.

There is no separate governance `setPaths` action and both deployment calls encode an empty
expansion array. The Factory applies that empty array during initialization through its internal
`setPaths` call.

## Candidate policy

The script currently mirrors the existing unreleased candidate defaults:

```text
local maximum per keeper:    20,000,000 crvUSD
frxUSD initial debt ceiling: 20,000,000 crvUSD
sUSDe initial debt ceiling:  0 crvUSD
entry minimum profit:        10 ppm
normal exit minimum profit:  500 ppm
keeper profit share:         30%
minimum expansion:           10,000 crvUSD
local intervention share:    33.33%
minimum intervention delay:  12 seconds
retained-backing floor:      0.999e18
```

The sUSDe `20m` local maximum is a configuration placeholder, not an allocation or activation
recommendation. The proposal deliberately leaves its ControllerFactory debt ceiling at zero because
the live pool is far too small to justify the inherited candidate ceiling. Governance must measure
current depth and separately choose both the local maximum and ControllerFactory debt ceiling before
funding or activating that keeper. Keeping a contract paused is not an excuse to preallocate an
unsafe ceiling.

## Fork evidence

The integration test pins block `25,911,411` and proves:

- both canonical Chainlink adapters deploy and return prices above the configured floor;
- the direct pool coin order and sUSDe ERC-4626 asset relationship are correct;
- the sUSDe pool's stored rate matches `convertToAssets(1e18)` within one basis point;
- exactly two predicted keepers deploy, both fully paused and with empty expansion paths;
- the frxUSD debt ceiling and both keepers' monetary-policy registrations are applied;
- the sUSDe keeper remains unfunded with a zero ControllerFactory debt ceiling;
- after proving the proposal leaves sUSDe unfunded, a fork-only `20,000 crvUSD` canary ceiling supports a live `10,000 crvUSD` sUSDe direct LP deposit with `crvUsdSold = 0`;
- a live frxUSD deposit with negative retained margin is rejected by preview and execution rather than weakening the entry floor.

A current-block canary and explicit governance parameter decision remain mandatory before any broadcast or activation.
