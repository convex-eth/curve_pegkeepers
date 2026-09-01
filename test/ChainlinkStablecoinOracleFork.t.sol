// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";

contract ChainlinkStablecoinOracleForkTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
    }

    function test_unifiedDeploymentCreatesLiveFrxUsdAdapter() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(deployer.mainnetConfig());

        IChainlinkStablecoinOracle frxUsdOracle =
            IChainlinkStablecoinOracle(deployment.frxUsdUsdOracle);

        assertEq(frxUsdOracle.feed(), deployer.FRXUSD_USD_PROXY());
        assertEq(frxUsdOracle.feed_decimals(), 8);
        assertEq(frxUsdOracle.max_delay(), deployer.RECOMMENDED_CHAINLINK_MAX_DELAY());
        assertGt(frxUsdOracle.price(), 0);
    }
}
