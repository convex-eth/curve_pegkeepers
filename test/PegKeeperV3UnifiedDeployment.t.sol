// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperRegistry} from "../src/interfaces/IPegKeeperRegistry.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {MockChainlinkAggregator, MockChainlinkProxy} from "./ChainlinkStablecoinOracle.t.sol";
import {
    LpYieldAmm,
    LpYieldControllerAndPolicy,
    LpYieldOracle,
    LpYieldToken
} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3UnifiedDeploymentTest is Test {
    string internal constant TEST_OUTPUT = "deployments/mainnet/PegKeeperV3-deployment.test.json";

    function test_deploysCompleteStandaloneReleaseAndWritesEveryAddressToJson() public {
        LpYieldToken crvUsd = new LpYieldToken(18);
        LpYieldOracle aggregateCrvUsdOracle = new LpYieldOracle();
        LpYieldControllerAndPolicy controllerFactory = new LpYieldControllerAndPolicy(
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
        address keeperAdmin = makeAddr("keeperAdmin");
        DeployPegKeeperV3.Config memory config = _localConfig(
            keeperAdmin, controllerFactory, aggregateCrvUsdOracle, chainlinkProxy, crvUsd
        );

        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);
        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        IPegKeeperRegistry registry = IPegKeeperRegistry(deployment.registry);

        assertGt(deployment.policy.code.length, 0);
        assertGt(deployment.registry.code.length, 0);
        assertGt(deployment.frxUsdPegKeeper.code.length, 45);
        assertGt(deployment.usdcPegKeeper.code.length, 45);
        assertGt(deployment.usdtPegKeeper.code.length, 45);
        assertEq(policy.admin(), config.admin);
        assertEq(policy.future_admin(), address(0));
        assertEq(policy.new_admin_deadline(), 0);
        assertEq(policy.aggregateCrvUsdOracle(), config.aggregateCrvUsdOracle);
        assertEq(policy.fee_receiver(), config.feeReceiver);
        assertTrue(policy.can_expand());
        assertTrue(policy.can_contract());
        assertEq(registry.admin(), config.admin);
        assertEq(registry.future_admin(), address(0));
        assertEq(registry.new_admin_deadline(), 0);
        assertEq(registry.peg_keeper_count(), 0);
        assertFalse(registry.is_active(deployment.frxUsdPegKeeper));

        assertEq(deployment.policy, vm.computeCreateAddress(address(deployer), 1));
        assertEq(deployment.registry, vm.computeCreateAddress(address(deployer), 2));
        assertEq(deployment.frxUsdUsdOracle, vm.computeCreateAddress(address(deployer), 3));
        assertEq(deployment.usdcUsdOracle, vm.computeCreateAddress(address(deployer), 4));
        assertEq(deployment.usdtUsdOracle, vm.computeCreateAddress(address(deployer), 5));
        assertEq(deployment.frxUsdPegKeeper, vm.computeCreateAddress(address(deployer), 6));
        assertEq(deployment.usdcPegKeeper, vm.computeCreateAddress(address(deployer), 7));
        assertEq(deployment.usdtPegKeeper, vm.computeCreateAddress(address(deployer), 8));

        _assertKeeper(deployment.frxUsdPegKeeper, deployment.policy, config, 1, 10, 150, true);
        _assertKeeper(deployment.usdcPegKeeper, deployment.policy, config, 2, 300, 80, false);
        _assertKeeper(deployment.usdtPegKeeper, deployment.policy, config, 3, 300, 80, false);

        _assertChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _assertChainlinkOracle(deployment.usdcUsdOracle, config.usdcProxy, config.usdcMaxDelay);
        _assertChainlinkOracle(deployment.usdtUsdOracle, config.usdtProxy, config.usdtMaxDelay);

        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);
        string memory json = vm.readFile(TEST_OUTPUT);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(json, ".policy"), deployment.policy);
        assertEq(vm.parseJsonAddress(json, ".registry"), deployment.registry);
        assertEq(vm.parseJsonAddress(json, ".frxUsdUsdOracle"), deployment.frxUsdUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdcUsdOracle"), deployment.usdcUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdtUsdOracle"), deployment.usdtUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".frxUsdPegKeeper"), deployment.frxUsdPegKeeper);
        assertEq(vm.parseJsonAddress(json, ".usdcPegKeeper"), deployment.usdcPegKeeper);
        assertEq(vm.parseJsonAddress(json, ".usdtPegKeeper"), deployment.usdtPegKeeper);
        assertFalse(vm.keyExistsJson(json, ".implementation"));
        assertFalse(vm.keyExistsJson(json, ".factory"));
        assertFalse(vm.keyExistsJson(json, ".initialOwner"));
        assertFalse(vm.keyExistsJson(json, ".factoryOwnershipNonce"));
        assertFalse(vm.keyExistsJson(json, ".policyOwnershipNonce"));
        assertFalse(vm.keyExistsJson(json, ".usdeUsdOracle"));
        assertFalse(vm.keyExistsJson(json, ".sUsdePegKeeper"));
        vm.removeFile(TEST_OUTPUT);
    }

    function test_mainnetConfigurationIsExplicitAndEnvironmentFree() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();

        assertEq(config.controllerFactory, deployer.CRVUSD_CONTROLLER_FACTORY());
        assertEq(config.aggregateCrvUsdOracle, deployer.CRVUSD_AGGREGATE_ORACLE());
        assertEq(config.admin, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.emergencyAdmin, deployer.EMERGENCY_ADMIN());
        assertEq(config.feeReceiver, deployer.FEE_SPLITTER());
        assertEq(config.keeperProfitShareBps, 3_000);
        assertEq(config.maxDebt, 150_000_000e18);
        assertEq(config.ammExecutionBufferBps, 3);
        assertEq(config.frxUsdProxy, deployer.FRXUSD_USD_PROXY());
        assertEq(config.usdcProxy, deployer.USDC_USD_PROXY());
        assertEq(config.usdtProxy, deployer.USDT_USD_PROXY());
        assertEq(config.frxUsdMaxDelay, 26 hours);
        assertEq(config.usdcMaxDelay, 26 hours);
        assertEq(config.usdtMaxDelay, 26 hours);
        assertEq(config.frxUsdCrvUsdPool, deployer.FRXUSD_CRVUSD_POOL());
        assertEq(config.usdcCrvUsdPool, deployer.USDC_CRVUSD_POOL());
        assertEq(config.usdtCrvUsdPool, deployer.USDT_CRVUSD_POOL());
    }

    function _assertKeeper(
        address keeperAddress,
        address policy,
        DeployPegKeeperV3.Config memory config,
        uint256 index,
        uint256 entryProfit,
        uint256 exitProfit,
        bool dynamicArrays
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.policy(), policy);
        assertEq(keeper.controller_factory(), config.controllerFactory);
        assertEq(keeper.admin(), config.admin);
        assertEq(keeper.future_admin(), address(0));
        assertEq(keeper.new_admin_deadline(), 0);
        assertEq(keeper.emergency_admin(), config.emergencyAdmin);
        assertEq(keeper.keeper_index(), index);
        assertEq(keeper.entry_min_profit_ppm(), entryProfit);
        assertEq(keeper.normal_exit_min_profit_ppm(), exitProfit);
        assertEq(keeper.keeper_profit_share_bps(), config.keeperProfitShareBps);
        assertEq(keeper.max_debt(), config.maxDebt);
        assertEq(keeper.amm_execution_buffer_bps(), config.ammExecutionBufferBps);
        assertEq(keeper.pool_uses_dynamic_arrays(), dynamicArrays);
        assertFalse(keeper.expansion_paused());
        assertFalse(keeper.contraction_paused());
        assertFalse(keeper.all_execution_paused());
        (bool factoryGetterExists,) = keeperAddress.staticcall(abi.encodeWithSignature("factory()"));
        assertFalse(factoryGetterExists);
        (bool initializedGetterExists,) =
            keeperAddress.staticcall(abi.encodeWithSignature("initialized()"));
        assertFalse(initializedGetterExists);
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.max_delay(), maxDelay);
        assertGt(oracle.price(), 0);
    }

    function _localConfig(
        address keeperAdmin,
        LpYieldControllerAndPolicy controllerFactory,
        LpYieldOracle aggregateCrvUsdOracle,
        MockChainlinkProxy chainlinkProxy,
        LpYieldToken crvUsd
    ) internal returns (DeployPegKeeperV3.Config memory config) {
        config.controllerFactory = address(controllerFactory);
        config.aggregateCrvUsdOracle = address(aggregateCrvUsdOracle);
        config.admin = keeperAdmin;
        config.emergencyAdmin = makeAddr("emergencyAdmin");
        config.feeReceiver = makeAddr("feeReceiver");
        config.keeperProfitShareBps = 3_000;
        config.maxDebt = 2_500_000e18;
        config.ammExecutionBufferBps = 7;
        config.frxUsdProxy = address(chainlinkProxy);
        config.frxUsdMaxDelay = 26 hours;
        config.usdcProxy = address(chainlinkProxy);
        config.usdcMaxDelay = 26 hours;
        config.usdtProxy = address(chainlinkProxy);
        config.usdtMaxDelay = 26 hours;

        LpYieldToken frxUsd = new LpYieldToken(18);
        config.frxUsdCrvUsdPool = address(new LpYieldAmm(address(frxUsd), address(crvUsd)));
        LpYieldToken usdc = new LpYieldToken(6);
        config.usdcCrvUsdPool = address(new LpYieldAmm(address(usdc), address(crvUsd)));
        LpYieldToken usdt = new LpYieldToken(6);
        config.usdtCrvUsdPool = address(new LpYieldAmm(address(usdt), address(crvUsd)));
    }
}
