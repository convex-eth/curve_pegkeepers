// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {MockChainlinkAggregator, MockChainlinkProxy} from "./ChainlinkStablecoinOracle.t.sol";
import {
    LpYieldAmm,
    LpYieldFactory,
    LpYieldOracle,
    LpYieldToken,
    LpYieldVault
} from "./PegKeeperV3LpYield.t.sol";

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
        address finalOwner = makeAddr("finalOwner");
        DeployPegKeeperV3.Config memory config = _localConfig(
            deployer, finalOwner, controllerFactory, aggregateCrvUsdOracle, chainlinkProxy, crvUsd
        );

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
        assertEq(policy.pendingOwner(), config.finalOwner);
        assertEq(policy.ownershipTransferNonce(), deployment.policyOwnershipNonce);
        assertEq(deployment.policyOwnershipNonce, 1);
        assertEq(policy.factory(), deployment.factory);
        assertEq(policy.aggregateCrvUsdOracle(), config.aggregateCrvUsdOracle);
        assertEq(policy.primaryUtilizationBps(), config.primaryUtilizationBps);
        assertEq(
            policy.keeper_profit_share_bps(deployment.frxUsdPegKeeper), config.keeperProfitShareBps
        );
        assertEq(
            policy.keeper_profit_share_bps(deployment.usdtPegKeeper), config.keeperProfitShareBps
        );
        assertEq(factory.admin(), config.admin);
        assertEq(factory.activePegKeeperCount(), 4);
        assertEq(factory.pendingOwner(), config.finalOwner);
        assertEq(factory.ownershipTransferNonce(), deployment.factoryOwnershipNonce);
        assertEq(deployment.factoryOwnershipNonce, 1);
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
        assertEq(deployment.frxUsdPegKeeper, vm.computeCreateAddress(deployment.factory, 1));
        assertEq(deployment.sUsdePegKeeper, vm.computeCreateAddress(deployment.factory, 2));
        assertEq(deployment.usdcPegKeeper, vm.computeCreateAddress(deployment.factory, 3));
        assertEq(deployment.usdtPegKeeper, vm.computeCreateAddress(deployment.factory, 4));
        assertEq(factory.activePegKeeperAt(0), deployment.frxUsdPegKeeper);
        assertEq(factory.activePegKeeperAt(1), deployment.sUsdePegKeeper);
        assertEq(factory.activePegKeeperAt(2), deployment.usdcPegKeeper);
        assertEq(factory.activePegKeeperAt(3), deployment.usdtPegKeeper);
        assertEq(policy.primary(), deployment.frxUsdPegKeeper);
        assertEq(policy.tier(deployment.sUsdePegKeeper), 2);
        assertEq(policy.tier(deployment.usdcPegKeeper), 3);
        assertEq(policy.tier(deployment.usdtPegKeeper), 3);
        assertFalse(IPegKeeperV3(deployment.frxUsdPegKeeper).expansion_paused());
        assertFalse(IPegKeeperV3(deployment.frxUsdPegKeeper).contraction_paused());
        assertFalse(IPegKeeperV3(deployment.frxUsdPegKeeper).all_execution_paused());
        assertEq(
            IPegKeeperV3(deployment.frxUsdPegKeeper).max_expansion_burst_bps(),
            config.maxExpansionBurstBps
        );
        assertEq(
            IPegKeeperV3(deployment.frxUsdPegKeeper).expansion_refill_period(),
            config.expansionRefillPeriod
        );

        vm.prank(config.owner);
        vm.expectRevert(IPegKeeperV3Factory.OwnershipHandoffPending.selector);
        factory.setDefaults(defaults_);
        vm.prank(config.owner);
        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_primary_utilization_bps(config.primaryUtilizationBps);
        vm.prank(config.owner);
        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_keeper_profit_share_bps(config.keeperProfitShareBps);
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
        assertEq(vm.parseJsonAddress(json, ".initialOwner"), deployment.initialOwner);
        assertEq(vm.parseJsonAddress(json, ".frxUsdPegKeeper"), deployment.frxUsdPegKeeper);
        assertEq(vm.parseJsonAddress(json, ".sUsdePegKeeper"), deployment.sUsdePegKeeper);
        assertEq(vm.parseJsonAddress(json, ".usdcPegKeeper"), deployment.usdcPegKeeper);
        assertEq(vm.parseJsonAddress(json, ".usdtPegKeeper"), deployment.usdtPegKeeper);
        assertEq(vm.parseJsonUint(json, ".factoryOwnershipNonce"), deployment.factoryOwnershipNonce);
        assertEq(vm.parseJsonUint(json, ".policyOwnershipNonce"), deployment.policyOwnershipNonce);
        vm.removeFile(TEST_OUTPUT);
    }

    function test_mainnetConfigurationIsExplicitAndEnvironmentFree() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        address initialOwner = makeAddr("deployer");
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig(initialOwner);

        assertEq(config.owner, initialOwner);
        assertEq(config.finalOwner, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.controllerFactory, deployer.CRVUSD_CONTROLLER_FACTORY());
        assertEq(config.aggregateCrvUsdOracle, deployer.CRVUSD_AGGREGATE_ORACLE());
        assertEq(config.admin, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.emergencyAdmin, deployer.EMERGENCY_ADMIN());
        assertEq(config.feeReceiver, deployer.FEE_SPLITTER());
        assertEq(config.primaryUtilizationBps, 8_000);
        assertEq(config.keeperProfitShareBps, 3_000);
        assertEq(config.maxDeployedCrvUsd, 20_000_000e18);
        assertEq(config.maxExpansionBurstBps, 500);
        assertEq(config.expansionRefillPeriod, 5 minutes);
        assertEq(config.ammExecutionBufferBps, 3);
        assertEq(config.frxUsdProxy, deployer.FRXUSD_USD_PROXY());
        assertEq(config.usdeProxy, deployer.USDE_USD_PROXY());
        assertEq(config.usdcProxy, deployer.USDC_USD_PROXY());
        assertEq(config.usdtProxy, deployer.USDT_USD_PROXY());
        assertEq(config.frxUsdMaxDelay, 26 hours);
        assertEq(config.usdeMaxDelay, 25 hours);
        assertEq(config.usdcMaxDelay, 26 hours);
        assertEq(config.usdtMaxDelay, 26 hours);
        assertEq(config.frxUsdCrvUsdPool, deployer.FRXUSD_CRVUSD_POOL());
        assertEq(config.sUsdeCrvUsdPool, deployer.SUSDE_CRVUSD_POOL());
        assertEq(config.usdcCrvUsdPool, deployer.USDC_CRVUSD_POOL());
        assertEq(config.usdtCrvUsdPool, deployer.USDT_CRVUSD_POOL());
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.max_delay(), maxDelay);
        assertGt(oracle.price(), 0);
    }

    function _localConfig(
        DeployPegKeeperV3 deployer,
        address finalOwner,
        LpYieldFactory controllerFactory,
        LpYieldOracle aggregateCrvUsdOracle,
        MockChainlinkProxy chainlinkProxy,
        LpYieldToken crvUsd
    ) internal returns (DeployPegKeeperV3.Config memory config) {
        config.owner = address(deployer);
        config.finalOwner = finalOwner;
        config.controllerFactory = address(controllerFactory);
        config.aggregateCrvUsdOracle = address(aggregateCrvUsdOracle);
        config.admin = finalOwner;
        config.emergencyAdmin = makeAddr("emergencyAdmin");
        config.feeReceiver = makeAddr("feeReceiver");
        config.primaryUtilizationBps = 8_000;
        config.keeperProfitShareBps = 3_000;
        config.maxDeployedCrvUsd = 2_500_000e18;
        config.maxExpansionBurstBps = 700;
        config.expansionRefillPeriod = 7 minutes;
        config.ammExecutionBufferBps = 7;
        config.frxUsdProxy = address(chainlinkProxy);
        config.frxUsdMaxDelay = 26 hours;
        config.usdeProxy = address(chainlinkProxy);
        config.usdeMaxDelay = 25 hours;
        config.usdcProxy = address(chainlinkProxy);
        config.usdcMaxDelay = 26 hours;
        config.usdtProxy = address(chainlinkProxy);
        config.usdtMaxDelay = 26 hours;

        LpYieldToken frxUsd = new LpYieldToken(18);
        config.frxUsdCrvUsdPool = address(new LpYieldAmm(address(frxUsd), address(crvUsd)));
        LpYieldToken usde = new LpYieldToken(18);
        LpYieldVault sUsde = new LpYieldVault(address(usde));
        config.sUsdeCrvUsdPool = address(new LpYieldAmm(address(sUsde), address(crvUsd)));
        LpYieldToken usdc = new LpYieldToken(6);
        config.usdcCrvUsdPool = address(new LpYieldAmm(address(usdc), address(crvUsd)));
        LpYieldToken usdt = new LpYieldToken(6);
        config.usdtCrvUsdPool = address(new LpYieldAmm(address(usdt), address(crvUsd)));
    }
}
