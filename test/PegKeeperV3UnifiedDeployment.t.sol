// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {ICurveStablecoinOracle} from "../src/interfaces/ICurveStablecoinOracle.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {MockCurveOraclePool} from "./CurveStablecoinOracle.t.sol";
import {MockChainlinkAggregator, MockChainlinkProxy} from "./ChainlinkStablecoinOracle.t.sol";
import {MockFactory, MockToken} from "./PegKeeperV3Foundation.t.sol";

contract PegKeeperV3UnifiedDeploymentTest is Test {
    string internal constant TEST_OUTPUT = "deployments/mainnet/PegKeeperV3-deployment.test.json";

    address internal usdc = makeAddr("USDC");
    address internal usdt = makeAddr("USDT");

    function test_deploysCompleteReleaseAndWritesEveryAddressToJson() public {
        MockToken crvUsd = new MockToken(18);
        MockFactory controllerFactory =
            new MockFactory(address(crvUsd), address(this), address(0xBEEF), address(0xFEE));
        MockCurveOraclePool usdcUsdtPool = new MockCurveOraclePool(usdc, usdt);
        MockChainlinkAggregator chainlinkAggregator = new MockChainlinkAggregator();
        MockChainlinkProxy chainlinkProxy = new MockChainlinkProxy(chainlinkAggregator);
        vm.warp(10_000);
        chainlinkAggregator.setRound(7, 99_990_000, block.timestamp, 7);

        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = DeployPegKeeperV3.Config({
            owner: address(this),
            controllerFactory: address(controllerFactory),
            admin: makeAddr("admin"),
            emergencyAdmin: makeAddr("emergencyAdmin"),
            feeReceiver: makeAddr("feeReceiver"),
            maxDeployedCrvUsd: 2_500_000e18,
            targetAmmExecutionBufferBps: 5,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100,
            usdcUsdtPool: address(usdcUsdtPool),
            usdc: usdc,
            usdt: usdt,
            frxUsdProxy: address(chainlinkProxy),
            frxUsdMaxDelay: 26 hours,
            usdsProxy: address(chainlinkProxy),
            usdsMaxDelay: 26 hours
        });

        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);
        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);

        assertGt(deployment.previewModule.code.length, 0);
        assertGt(deployment.implementation.code.length, 0);
        assertGt(deployment.factory.code.length, 0);
        assertEq(factory.implementation(), deployment.implementation);
        assertEq(IPegKeeperV3(deployment.implementation).preview_module(), deployment.previewModule);
        assertEq(factory.owner(), config.owner);
        assertEq(factory.controllerFactory(), config.controllerFactory);
        assertEq(factory.admin(), config.admin);
        assertEq(factory.keeperCount(), 0);
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.admin, config.admin);
        assertEq(defaults_.emergencyAdmin, config.emergencyAdmin);
        assertEq(defaults_.feeReceiver, config.feeReceiver);
        assertEq(defaults_.maxDeployedCrvUsd, config.maxDeployedCrvUsd);
        assertEq(defaults_.targetAmmExecutionBufferBps, config.targetAmmExecutionBufferBps);
        assertEq(defaults_.minDownstreamAttemptGas, config.minDownstreamAttemptGas);
        assertEq(defaults_.fallbackSettlementGasReserve, config.fallbackSettlementGasReserve);
        assertEq(defaults_.expansionMaxRouteLossBps, config.expansionMaxRouteLossBps);

        assertEq(deployment.previewModule, vm.computeCreateAddress(address(deployer), 1));
        assertEq(deployment.implementation, vm.computeCreateAddress(address(deployer), 2));
        assertEq(deployment.factory, vm.computeCreateAddress(address(deployer), 3));
        assertEq(deployment.usdcTargetOracle, vm.computeCreateAddress(address(deployer), 4));
        assertEq(deployment.usdtTargetOracle, vm.computeCreateAddress(address(deployer), 5));
        assertEq(deployment.frxUsdUsdOracle, vm.computeCreateAddress(address(deployer), 6));
        assertEq(deployment.usdsUsdOracle, vm.computeCreateAddress(address(deployer), 7));
        _assertCurveOracle(
            deployment.usdcTargetOracle, config.usdcUsdtPool, config.usdc, config.usdt, true
        );
        _assertCurveOracle(
            deployment.usdtTargetOracle, config.usdcUsdtPool, config.usdt, config.usdc, false
        );
        _assertChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _assertChainlinkOracle(deployment.usdsUsdOracle, config.usdsProxy, config.usdsMaxDelay);

        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);
        string memory json = vm.readFile(TEST_OUTPUT);
        assertEq(vm.parseJsonAddress(json, ".previewModule"), deployment.previewModule);
        assertEq(vm.parseJsonAddress(json, ".implementation"), deployment.implementation);
        assertEq(vm.parseJsonAddress(json, ".factory"), deployment.factory);
        assertEq(vm.parseJsonAddress(json, ".usdcTargetOracle"), deployment.usdcTargetOracle);
        assertEq(vm.parseJsonAddress(json, ".usdtTargetOracle"), deployment.usdtTargetOracle);
        assertEq(vm.parseJsonAddress(json, ".frxUsdUsdOracle"), deployment.frxUsdUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdsUsdOracle"), deployment.usdsUsdOracle);
        vm.removeFile(TEST_OUTPUT);
    }

    function test_mainnetConfigurationIsExplicitAndEnvironmentFree() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();

        assertEq(config.owner, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.controllerFactory, deployer.CRVUSD_CONTROLLER_FACTORY());
        assertEq(config.admin, deployer.CURVE_OWNERSHIP_AGENT());
        assertEq(config.emergencyAdmin, deployer.CURVE_EMERGENCY_ADMIN());
        assertEq(config.feeReceiver, deployer.FEE_SPLITTER());
        assertEq(config.maxDeployedCrvUsd, 2_500_000e18);
        assertEq(config.targetAmmExecutionBufferBps, 3);
        assertEq(config.minDownstreamAttemptGas, 1_500_000);
        assertEq(config.fallbackSettlementGasReserve, 300_000);
        assertEq(config.expansionMaxRouteLossBps, 5);
        assertEq(config.usdcUsdtPool, deployer.USDC_USDT_ORACLE_POOL());
        assertEq(config.frxUsdProxy, deployer.FRXUSD_USD_PROXY());
        assertEq(config.frxUsdMaxDelay, 26 hours);
        assertEq(config.usdsProxy, deployer.USDS_USD_PROXY());
        assertEq(config.usdsMaxDelay, 26 hours);
    }

    function test_mainnetConfigurationUsesCanonicalChainlinkProxyFeeds() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();

        assertEq(deployer.FRXUSD_USD_PROXY(), 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83);
        assertEq(deployer.USDS_USD_PROXY(), 0xfF30586cD0F29eD462364C7e81375FC0C71219b1);
    }

    function _assertCurveOracle(
        address adapter,
        address pool,
        address asset,
        address referenceAsset,
        bool inverted
    ) internal view {
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.pool(), pool);
        assertEq(oracle.asset(), asset);
        assertEq(oracle.reference_asset(), referenceAsset);
        assertEq(oracle.inverted(), inverted);
        assertEq(oracle.price(), 1e18);
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.max_delay(), maxDelay);
        assertGt(oracle.price(), 0);
    }
}
