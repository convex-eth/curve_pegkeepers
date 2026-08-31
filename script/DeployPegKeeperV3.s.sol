// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {ICurveStablecoinOracle} from "../src/interfaces/ICurveStablecoinOracle.sol";
import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";

/// @notice Monotonic mainnet deployer for every PegKeeperV3 release dependency.
/// @dev Deploys both oracle families so governance can select one after independent feed review.
contract DeployPegKeeperV3 is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    string public constant DEPLOYMENT_OUTPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    address public constant CURVE_OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address public constant CRVUSD_CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address public constant CURVE_EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    address public constant USDC_USDT_ORACLE_POOL = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant FRXUSD_SUSDS_ORACLE_POOL = 0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7;
    address public constant SFRXUSD_FRXUSD_ORACLE_POOL = 0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978;

    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    address public constant USDS_USD_PROXY = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;

    /// @dev Provisional heartbeat-plus-grace value. Reconfirm both feeds before broadcast.
    uint256 public constant RECOMMENDED_CHAINLINK_MAX_DELAY = 26 hours;

    uint256 public constant INITIAL_MAX_DEPLOYED_CRVUSD = 2_500_000e18;
    uint256 public constant TARGET_AMM_EXECUTION_BUFFER_BPS = 5;
    uint256 public constant MIN_DOWNSTREAM_ATTEMPT_GAS = 1_500_000;
    uint256 public constant FALLBACK_SETTLEMENT_GAS_RESERVE = 300_000;
    uint256 public constant EXPANSION_MAX_ROUTE_LOSS_BPS = 100;

    struct Config {
        address owner;
        address controllerFactory;
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 maxDeployedCrvUsd;
        uint256 targetAmmExecutionBufferBps;
        uint256 minDownstreamAttemptGas;
        uint256 fallbackSettlementGasReserve;
        uint256 expansionMaxRouteLossBps;
        address usdcUsdtPool;
        address frxUsdSusdsPool;
        address sfrxUsdFrxUsdPool;
        address frxUsd;
        address sfrxUsd;
        address susds;
        address usdc;
        address usdt;
        address frxUsdProxy;
        uint256 frxUsdMaxDelay;
        address usds;
        address usdsProxy;
        uint256 usdsMaxDelay;
    }

    struct Deployment {
        address previewModule;
        address implementation;
        address factory;
        address frxUsdTargetOracle;
        address sfrxUsdBackingOracle;
        address usdcTargetOracle;
        address usdtTargetOracle;
        address susdsBackingOracle;
        address frxUsdChainlinkOracle;
        address usdsChainlinkOracle;
    }

    function run() external returns (Deployment memory deployment) {
        require(block.chainid == 1, "mainnet required");
        Config memory config = mainnetConfig();
        _logPlan(config);

        vm.startBroadcast();
        deployment = deploy(config);
        vm.stopBroadcast();

        writeDeploymentJson(deployment, DEPLOYMENT_OUTPUT_PATH);
        _logDeployment(deployment);
    }

    function mainnetConfig() public pure returns (Config memory config) {
        config.owner = CURVE_OWNERSHIP_AGENT;
        config.controllerFactory = CRVUSD_CONTROLLER_FACTORY;
        config.admin = CURVE_OWNERSHIP_AGENT;
        config.emergencyAdmin = CURVE_EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = INITIAL_MAX_DEPLOYED_CRVUSD;
        config.targetAmmExecutionBufferBps = TARGET_AMM_EXECUTION_BUFFER_BPS;
        config.minDownstreamAttemptGas = MIN_DOWNSTREAM_ATTEMPT_GAS;
        config.fallbackSettlementGasReserve = FALLBACK_SETTLEMENT_GAS_RESERVE;
        config.expansionMaxRouteLossBps = EXPANSION_MAX_ROUTE_LOSS_BPS;
        config.usdcUsdtPool = USDC_USDT_ORACLE_POOL;
        config.frxUsdSusdsPool = FRXUSD_SUSDS_ORACLE_POOL;
        config.sfrxUsdFrxUsdPool = SFRXUSD_FRXUSD_ORACLE_POOL;
        config.frxUsd = FRXUSD;
        config.sfrxUsd = SFRXUSD;
        config.susds = SUSDS;
        config.usdc = USDC;
        config.usdt = USDT;
        config.frxUsdProxy = FRXUSD_USD_PROXY;
        config.frxUsdMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.usds = USDS;
        config.usdsProxy = USDS_USD_PROXY;
        config.usdsMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
    }

    function deploy(Config memory config) public returns (Deployment memory deployment) {
        console2.log("Deploying PegKeeperV3PreviewModule");
        deployment.previewModule = _deployPreviewModule();

        console2.log("Deploying locked PegKeeperV3 implementation");
        deployment.implementation = _deployImplementation(deployment.previewModule);

        console2.log("Deploying immutable PegKeeperV3Factory");
        deployment.factory = _deployFactory(config, deployment.implementation);

        console2.log("Deploying Curve frxUSD target oracle");
        deployment.frxUsdTargetOracle =
            _deployCurveAdapter(config.frxUsdSusdsPool, config.frxUsd, config.susds);
        console2.log("Deploying Curve sfrxUSD backing oracle");
        deployment.sfrxUsdBackingOracle =
            _deployCurveAdapter(config.sfrxUsdFrxUsdPool, config.sfrxUsd, config.frxUsd);
        console2.log("Deploying Curve USDC target oracle");
        deployment.usdcTargetOracle =
            _deployCurveAdapter(config.usdcUsdtPool, config.usdc, config.usdt);
        console2.log("Deploying Curve USDT target oracle");
        deployment.usdtTargetOracle =
            _deployCurveAdapter(config.usdcUsdtPool, config.usdt, config.usdc);
        console2.log("Deploying Curve sUSDS backing oracle");
        deployment.susdsBackingOracle =
            _deployCurveAdapter(config.frxUsdSusdsPool, config.susds, config.frxUsd);

        console2.log("Deploying Chainlink frxUSD/USD oracle");
        deployment.frxUsdChainlinkOracle =
            _deployChainlinkAdapter(config.frxUsdProxy, config.frxUsdMaxDelay);
        console2.log("Deploying Chainlink USDS/USD oracle");
        deployment.usdsChainlinkOracle =
            _deployChainlinkAdapter(config.usdsProxy, config.usdsMaxDelay);

        _verifyDeployment(deployment, config);
    }

    function writeDeploymentJson(Deployment memory deployment, string memory outputPath) public {
        string memory objectKey = "pegKeeperV3Deployment";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "previewModule", deployment.previewModule);
        vm.serializeAddress(objectKey, "implementation", deployment.implementation);
        vm.serializeAddress(objectKey, "factory", deployment.factory);
        vm.serializeAddress(objectKey, "frxUsdTargetOracle", deployment.frxUsdTargetOracle);
        vm.serializeAddress(objectKey, "sfrxUsdBackingOracle", deployment.sfrxUsdBackingOracle);
        vm.serializeAddress(objectKey, "usdcTargetOracle", deployment.usdcTargetOracle);
        vm.serializeAddress(objectKey, "usdtTargetOracle", deployment.usdtTargetOracle);
        vm.serializeAddress(objectKey, "susdsBackingOracle", deployment.susdsBackingOracle);
        vm.serializeAddress(objectKey, "frxUsdChainlinkOracle", deployment.frxUsdChainlinkOracle);
        string memory json =
            vm.serializeAddress(objectKey, "usdsChainlinkOracle", deployment.usdsChainlinkOracle);
        vm.writeJson(json, outputPath);
    }

    function _deployPreviewModule() internal returns (address deployed) {
        bytes memory creationCode =
            vm.getCode("out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json");
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployImplementation(address previewModule) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(previewModule));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployFactory(Config memory config, address implementation)
        internal
        returns (address deployed)
    {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: config.admin,
                emergencyAdmin: config.emergencyAdmin,
                feeReceiver: config.feeReceiver,
                maxDeployedCrvUsd: config.maxDeployedCrvUsd,
                targetAmmExecutionBufferBps: config.targetAmmExecutionBufferBps,
                minDownstreamAttemptGas: config.minDownstreamAttemptGas,
                fallbackSettlementGasReserve: config.fallbackSettlementGasReserve,
                expansionMaxRouteLossBps: config.expansionMaxRouteLossBps
            });
        bytes memory creationCode = vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json");
        bytes memory initCode = bytes.concat(
            creationCode,
            abi.encode(config.owner, config.controllerFactory, implementation, defaults_)
        );
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployCurveAdapter(address pool, address asset, address referenceAsset)
        internal
        returns (address deployed)
    {
        bytes memory creationCode =
            vm.getCode("out/CurveStablecoinOracle.vy/CurveStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(pool, asset, referenceAsset));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployChainlinkAdapter(address feed, uint256 maxDelay)
        internal
        returns (address deployed)
    {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(feed, maxDelay));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _verifyDeployment(Deployment memory deployment, Config memory config) internal view {
        require(
            deployment.implementation.code.length <= EIP_170_RUNTIME_LIMIT,
            "implementation too large"
        );
        require(deployment.previewModule.code.length > 0, "preview module missing");
        require(IPegKeeperV3(deployment.implementation).initialized(), "implementation not locked");
        require(
            IPegKeeperV3(deployment.implementation).preview_module() == deployment.previewModule,
            "preview module mismatch"
        );

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);
        require(factory.owner() == config.owner, "factory owner mismatch");
        require(
            factory.controllerFactory() == config.controllerFactory, "controller factory mismatch"
        );
        require(factory.implementation() == deployment.implementation, "implementation mismatch");
        require(factory.admin() == config.admin, "factory admin mismatch");
        require(factory.keeperCount() == 0, "initial keeper count");
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        require(defaults_.admin == config.admin, "default admin mismatch");
        require(
            defaults_.emergencyAdmin == config.emergencyAdmin, "default emergency admin mismatch"
        );
        require(defaults_.feeReceiver == config.feeReceiver, "default fee receiver mismatch");
        require(
            defaults_.maxDeployedCrvUsd == config.maxDeployedCrvUsd, "default capacity mismatch"
        );
        require(
            defaults_.targetAmmExecutionBufferBps == config.targetAmmExecutionBufferBps,
            "default AMM buffer mismatch"
        );
        require(
            defaults_.minDownstreamAttemptGas == config.minDownstreamAttemptGas,
            "default attempt gas mismatch"
        );
        require(
            defaults_.fallbackSettlementGasReserve == config.fallbackSettlementGasReserve,
            "default fallback gas mismatch"
        );
        require(
            defaults_.expansionMaxRouteLossBps == config.expansionMaxRouteLossBps,
            "default route loss mismatch"
        );

        _verifyCurveOracle(
            deployment.frxUsdTargetOracle, config.frxUsdSusdsPool, config.frxUsd, config.susds, true
        );
        _verifyCurveOracle(
            deployment.sfrxUsdBackingOracle,
            config.sfrxUsdFrxUsdPool,
            config.sfrxUsd,
            config.frxUsd,
            true
        );
        _verifyCurveOracle(
            deployment.usdcTargetOracle, config.usdcUsdtPool, config.usdc, config.usdt, true
        );
        _verifyCurveOracle(
            deployment.usdtTargetOracle, config.usdcUsdtPool, config.usdt, config.usdc, false
        );
        _verifyCurveOracle(
            deployment.susdsBackingOracle,
            config.frxUsdSusdsPool,
            config.susds,
            config.frxUsd,
            false
        );
        _verifyChainlinkOracle(
            deployment.frxUsdChainlinkOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _verifyChainlinkOracle(
            deployment.usdsChainlinkOracle, config.usdsProxy, config.usdsMaxDelay
        );
    }

    function _verifyCurveOracle(
        address adapter,
        address pool,
        address asset,
        address referenceAsset,
        bool inverted
    ) internal view {
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(adapter);
        require(adapter.code.length > 0, "Curve oracle code missing");
        require(oracle.pool() == pool, "Curve oracle pool mismatch");
        require(oracle.asset() == asset, "Curve oracle asset mismatch");
        require(oracle.reference_asset() == referenceAsset, "Curve oracle reference mismatch");
        require(oracle.inverted() == inverted, "Curve oracle orientation mismatch");
        require(oracle.price() > 0, "Curve oracle price invalid");
    }

    function _verifyChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(adapter.code.length > 0, "Chainlink oracle code missing");
        require(oracle.feed() == feed, "Chainlink oracle feed mismatch");
        require(oracle.feed_decimals() <= 18, "Chainlink oracle decimals invalid");
        require(oracle.max_delay() == maxDelay, "Chainlink oracle delay mismatch");
        require(oracle.price() > 0, "Chainlink oracle price invalid");
    }

    function _logPlan(Config memory config) internal pure {
        console2.log("PegKeeperV3 monotonic mainnet deployment");
        console2.log("Factory owner", config.owner);
        console2.log("ControllerFactory", config.controllerFactory);
        console2.log("Admin", config.admin);
        console2.log("Emergency admin", config.emergencyAdmin);
        console2.log("Fee receiver", config.feeReceiver);
        console2.log("Initial max deployed crvUSD", config.maxDeployedCrvUsd);
        console2.log("Target AMM execution buffer (bps)", config.targetAmmExecutionBufferBps);
        console2.log("Minimum downstream attempt gas", config.minDownstreamAttemptGas);
        console2.log("Fallback settlement gas reserve", config.fallbackSettlementGasReserve);
        console2.log("Expansion max route loss (bps)", config.expansionMaxRouteLossBps);
        console2.log("frxUSD", config.frxUsd);
        console2.log("sfrxUSD", config.sfrxUsd);
        console2.log("sUSDS", config.susds);
        console2.log("USDC", config.usdc);
        console2.log("USDT", config.usdt);
        console2.log("USDS", config.usds);
        console2.log("USDC/USDT Curve oracle pool", config.usdcUsdtPool);
        console2.log("frxUSD/sUSDS Curve oracle pool", config.frxUsdSusdsPool);
        console2.log("sfrxUSD/frxUSD Curve oracle pool", config.sfrxUsdFrxUsdPool);
        console2.log("frxUSD Chainlink proxy", config.frxUsdProxy);
        console2.log("frxUSD max delay (provisional)", config.frxUsdMaxDelay);
        console2.log("USDS Chainlink proxy", config.usdsProxy);
        console2.log("USDS max delay (provisional)", config.usdsMaxDelay);
        console2.log("Output", DEPLOYMENT_OUTPUT_PATH);
    }

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("Preview module", deployment.previewModule);
        console2.log("Implementation", deployment.implementation);
        console2.log("Factory", deployment.factory);
        console2.log("Curve frxUSD target oracle", deployment.frxUsdTargetOracle);
        console2.log("Curve sfrxUSD backing oracle", deployment.sfrxUsdBackingOracle);
        console2.log("Curve USDC target oracle", deployment.usdcTargetOracle);
        console2.log("Curve USDT target oracle", deployment.usdtTargetOracle);
        console2.log("Curve sUSDS backing oracle", deployment.susdsBackingOracle);
        console2.log("Chainlink frxUSD/USD oracle", deployment.frxUsdChainlinkOracle);
        console2.log("Chainlink USDS/USD oracle", deployment.usdsChainlinkOracle);
        console2.log("Deployment JSON", DEPLOYMENT_OUTPUT_PATH);
    }
}
