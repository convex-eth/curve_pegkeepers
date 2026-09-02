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

contract DeploymentFraxNetAccount {
    address public constant asset = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant frxUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public immutable factory;
    uint32 public constant targetEid = 30_101;
    bytes32 public immutable targetAddress;

    constructor(bytes32 targetAddress_) {
        factory = msg.sender;
        targetAddress = targetAddress_;
    }
}

contract DeploymentFraxNetFactoryHarness {
    mapping(address => bool) public isFraxNetDeposit;

    function isPaused() external pure returns (bool) {
        return false;
    }

    function frxUSDCustodian() external pure returns (address) {
        return 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;
    }

    function rwaRedeemer() external pure returns (address) {
        return address(0x19D7);
    }

    function getDeploymentAddress(uint32 targetEid, bytes32 targetAddress, bytes32 targetUsdcAta)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(targetEid, targetAddress, targetUsdcAta));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(DeploymentFraxNetAccount).creationCode, abi.encode(targetAddress))
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }

    function createFraxNetDeposit(uint32 targetEid, bytes32 targetAddress, bytes32 targetUsdcAta)
        external
        returns (address account)
    {
        bytes32 salt = keccak256(abi.encode(targetEid, targetAddress, targetUsdcAta));
        account = address(new DeploymentFraxNetAccount{salt: salt}(targetAddress));
        isFraxNetDeposit[account] = true;
    }
}

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
            frxUsdMaxDelay: 26 hours
        });

        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);
        DeploymentFraxNetFactoryHarness fraxNetHarness = new DeploymentFraxNetFactoryHarness();
        vm.etch(deployer.FRAXNET_DEPOSIT_FACTORY(), address(fraxNetHarness).code);
        deployment = deployer.prepareFraxNetAccounts(deployment);
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
        assertGt(deployment.usdcFraxNetDeposit.code.length, 0);
        assertGt(deployment.usdtFraxNetDeposit.code.length, 0);
        assertEq(
            DeploymentFraxNetAccount(deployment.usdcFraxNetDeposit).targetAddress(),
            bytes32(uint256(uint160(vm.computeCreateAddress(deployment.factory, 2))))
        );
        assertEq(
            DeploymentFraxNetAccount(deployment.usdtFraxNetDeposit).targetAddress(),
            bytes32(uint256(uint160(vm.computeCreateAddress(deployment.factory, 3))))
        );
        _assertCurveOracle(
            deployment.usdcTargetOracle, config.usdcUsdtPool, config.usdc, config.usdt, true
        );
        _assertCurveOracle(
            deployment.usdtTargetOracle, config.usdcUsdtPool, config.usdt, config.usdc, false
        );
        _assertChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );

        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);
        string memory json = vm.readFile(TEST_OUTPUT);
        assertEq(vm.parseJsonAddress(json, ".previewModule"), deployment.previewModule);
        assertEq(vm.parseJsonAddress(json, ".implementation"), deployment.implementation);
        assertEq(vm.parseJsonAddress(json, ".factory"), deployment.factory);
        assertEq(vm.parseJsonAddress(json, ".usdcTargetOracle"), deployment.usdcTargetOracle);
        assertEq(vm.parseJsonAddress(json, ".usdtTargetOracle"), deployment.usdtTargetOracle);
        assertEq(vm.parseJsonAddress(json, ".frxUsdUsdOracle"), deployment.frxUsdUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usdcFraxNetDeposit"), deployment.usdcFraxNetDeposit);
        assertEq(vm.parseJsonAddress(json, ".usdtFraxNetDeposit"), deployment.usdtFraxNetDeposit);
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
    }

    function test_mainnetConfigurationUsesCanonicalFrxUsdChainlinkProxyFeed() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();

        assertEq(deployer.FRXUSD_USD_PROXY(), 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83);
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
