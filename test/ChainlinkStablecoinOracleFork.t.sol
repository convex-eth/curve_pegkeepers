// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3ChainlinkOracles} from "../script/DeployPegKeeperV3ChainlinkOracles.s.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";

contract ChainlinkStablecoinOracleForkTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    }

    function test_liveFrxUsdAndUsdsFeedsNormalizeToOneEighteen() public {
        DeployPegKeeperV3ChainlinkOracles deployer = new DeployPegKeeperV3ChainlinkOracles();
        deployer.validateMainnetRegistry();
        DeployPegKeeperV3ChainlinkOracles.Config memory config =
            DeployPegKeeperV3ChainlinkOracles.Config({
                registry: deployer.CHAINLINK_FEED_REGISTRY(),
                quote: deployer.USD(),
                frxUsd: deployer.FRXUSD(),
                frxUsdExpectedFeed: deployer.FRXUSD_USD_FEED(),
                frxUsdMaxDelay: 2 days,
                usds: deployer.USDS(),
                usdsExpectedFeed: deployer.USDS_USD_FEED(),
                usdsMaxDelay: 2 days
            });

        (address frxUsdAdapter, address usdsAdapter) = deployer.deploy(config);

        _assertLiveAdapter(frxUsdAdapter, deployer.FRXUSD_USD_FEED());
        _assertLiveAdapter(usdsAdapter, deployer.USDS_USD_FEED());
    }

    function _assertLiveAdapter(address adapter, address expectedFeed) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertEq(oracle.feed(), expectedFeed);
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), 2 days);
        assertGt(oracle.price(), 0.95e18);
        assertLt(oracle.price(), 1.05e18);
    }
}
