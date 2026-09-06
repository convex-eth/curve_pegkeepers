// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {MockChainlinkAggregator, MockChainlinkProxy} from "./ChainlinkStablecoinOracle.t.sol";
import {LpYieldFactory, LpYieldOracle, LpYieldToken} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3UnifiedDeploymentTest is Test {
    string internal constant TEST_OUTPUT = "deployments/mainnet/PegKeeperV3-deployment.test.json";

    function test_deploysCompleteReleaseAndWritesEveryAddressToJson() public {
        LpYieldToken crvUsd = new LpYieldToken(18);
        LpYieldOracle aggregateCrvUsdOracle = new LpYieldOracle();
        LpYieldFactory controllerFactory = new LpYieldFactory(
            address(crvUsd),
            address(this),
            address(0xBEEF),
            address(0xFEE),
            address(aggregateCrvUsdOracle)
        );
        MockChainlinkAggregator chainlinkAggregator = new MockChainlinkAggregator();
        MockChainlinkProxy chainlinkProxy = new MockChainlinkProxy(chainlinkAggregator);
        vm.warp(10_000);
        chainlinkAggregator.setRound(7, 99_990_000, block.timestamp, 7);

        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = DeployPegKeeperV3.Config({
            owner: address(this),
            controllerFactory: address(controllerFactory),
            aggregateCrvUsdOracle: address(aggregateCrvUsdOracle),
            admin: makeAddr("admin"),
            emergencyAdmin: makeAddr("emergencyAdmin"),
            feeReceiver: makeAddr("feeReceiver"),
            primaryUtilizationBps: 8_000,
            maxDeployedCrvUsd: 2_500_000e18,
            ammExecutionBufferBps: 7,
            frxUsdProxy: address(chainlinkProxy),
            frxUsdMaxDelay: 26 hours,
            usdeProxy: address(chainlinkProxy),
            usdeMaxDelay: 25 hours,
            usdcProxy: address(chainlinkProxy),
            usdcMaxDelay: 26 hours,
            usdtProxy: address(chainlinkProxy),
            usdtMaxDelay: 26 hours
        });

        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);
        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);
        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);

        assertGt(deployment.implementation.code.length, 0);
        assertGt(deployment.policy.code.length, 0);
        assertGt(deployment.factory.code.length, 0);
        assertEq(factory.implementation(), deployment.implementation);
        assertEq(factory.owner(), config.owner);
        assertEq(factory.controllerFactory(), config.controllerFactory);
        assertEq(factory.policy(), deployment.policy);
        assertEq(policy.owner(), config.owner);
        assertEq(policy.factory(), address(0));
        assertEq(policy.aggregateCrvUsdOracle(), config.aggregateCrvUsdOracle);
        assertEq(policy.primaryUtilizationBps(), config.primaryUtilizationBps);
        assertEq(factory.admin(), config.admin);
        assertEq(factory.activePegKeeperCount(), 0);
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.admin, config.admin);
        assertEq(defaults_.emergencyAdmin, config.emergencyAdmin);
        assertEq(defaults_.feeReceiver, config.feeReceiver);
        assertEq(defaults_.maxDeployedCrvUsd, config.maxDeployedCrvUsd);
        assertEq(defaults_.ammExecutionBufferBps, config.ammExecutionBufferBps);

        assertEq(deployment.implementation, vm.computeCreateAddress(address(deployer), 1));
        assertEq(deployment.policy, vm.computeCreateAddress(address(deployer), 2));
        assertEq(deployment.factory, vm.computeCreateAddress(address(deployer), 3));
        assertEq(deployment.frxUsdUsdOracle, vm.computeCreateAddress(address(deployer), 4));
        assertEq(deployment.usdeUsdOracle, vm.computeCreateAddress(address(deployer), 5));
        assertEq(deployment.usdcUsdOracle, vm.computeCreateAddress(address(deployer), 6));
        assertEq(deployment.usdtUsdOracle, vm.computeCreateAddress(address(deployer), 7));
        _assertChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _assertChainlinkOracle(deployment.usdeUsdOracle, config.usdeProxy, config.usdeMaxDelay);
        _assertChainlinkOracle(deployment.usdcUsdOracle, config.usdcProxy, config.usdcMaxDelay);
        _assertChainlinkOracle(deployment.usdtUsdOracle, config.usdtProxy, config.usdtMaxDelay);

        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);
        string memory json = vm.readFile(TEST_OUTPUT);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(json, ".implementation"), deployment.implementation);
        assertEq(vm.parseJsonAddress(json, ".policy"), deployment.policy);
        assertEq(vm.parseJsonAddress(json, ".factory"), deployment.factory);
        assertEq(vm.parseJsonAddress(json, ".frxUsdUsdOracle"), deployment.frxUsdUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdeUsdOracle"), deployment.usdeUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdcUsdOracle"), deployment.usdcUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdtUsdOracle"), deployment.usdtUsdOracle);
        vm.removeFile(TEST_OUTPUT);
    }

    function test_mainnetConfigurationIsExplicitAndEnvironmentFree() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();

        assertEq(config.owner, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.controllerFactory, deployer.CRVUSD_CONTROLLER_FACTORY());
        assertEq(config.aggregateCrvUsdOracle, deployer.CRVUSD_AGGREGATE_ORACLE());
        assertEq(config.admin, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.emergencyAdmin, deployer.EMERGENCY_ADMIN());
        assertEq(config.feeReceiver, deployer.FEE_SPLITTER());
        assertEq(config.primaryUtilizationBps, 8_000);
        assertEq(config.maxDeployedCrvUsd, 20_000_000e18);
        assertEq(config.ammExecutionBufferBps, 3);
        assertEq(config.frxUsdProxy, deployer.FRXUSD_USD_PROXY());
        assertEq(config.usdeProxy, deployer.USDE_USD_PROXY());
        assertEq(config.usdcProxy, deployer.USDC_USD_PROXY());
        assertEq(config.usdtProxy, deployer.USDT_USD_PROXY());
        assertEq(config.frxUsdMaxDelay, 26 hours);
        assertEq(config.usdeMaxDelay, 25 hours);
        assertEq(config.usdcMaxDelay, 26 hours);
        assertEq(config.usdtMaxDelay, 26 hours);
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.max_delay(), maxDelay);
        assertGt(oracle.price(), 0);
    }
}
