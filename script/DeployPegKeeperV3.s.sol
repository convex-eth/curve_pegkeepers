// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";

/// @notice Deploys the direct-liquidity PegKeeperV3 dependencies. It does not deploy keepers.
contract DeployPegKeeperV3 is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    string public constant DEPLOYMENT_OUTPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    address public constant CURVE_OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address public constant CRVUSD_CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address public constant CRVUSD_AGGREGATE_ORACLE = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;
    address public constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    address public constant USDE_USD_PROXY = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address public constant USDC_USD_PROXY = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDT_USD_PROXY = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 public constant RECOMMENDED_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant RECOMMENDED_USDE_CHAINLINK_MAX_DELAY = 25 hours;
    uint256 public constant PRIMARY_UTILIZATION_BPS = 8_000;
    uint256 public constant INITIAL_MAX_DEPLOYED_CRVUSD = 20_000_000e18;
    uint256 public constant AMM_EXECUTION_BUFFER_BPS = 3;

    struct Config {
        address owner;
        address controllerFactory;
        address aggregateCrvUsdOracle;
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 primaryUtilizationBps;
        uint256 maxDeployedCrvUsd;
        uint256 ammExecutionBufferBps;
        address frxUsdProxy;
        uint256 frxUsdMaxDelay;
        address usdeProxy;
        uint256 usdeMaxDelay;
        address usdcProxy;
        uint256 usdcMaxDelay;
        address usdtProxy;
        uint256 usdtMaxDelay;
    }

    struct Deployment {
        address implementation;
        address policy;
        address factory;
        address frxUsdUsdOracle;
        address usdeUsdOracle;
        address usdcUsdOracle;
        address usdtUsdOracle;
    }

    function run() external virtual returns (Deployment memory deployment) {
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
        config.aggregateCrvUsdOracle = CRVUSD_AGGREGATE_ORACLE;
        config.admin = CURVE_OWNERSHIP_AGENT;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.primaryUtilizationBps = PRIMARY_UTILIZATION_BPS;
        config.maxDeployedCrvUsd = INITIAL_MAX_DEPLOYED_CRVUSD;
        config.ammExecutionBufferBps = AMM_EXECUTION_BUFFER_BPS;
        config.frxUsdProxy = FRXUSD_USD_PROXY;
        config.frxUsdMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.usdeProxy = USDE_USD_PROXY;
        config.usdeMaxDelay = RECOMMENDED_USDE_CHAINLINK_MAX_DELAY;
        config.usdcProxy = USDC_USD_PROXY;
        config.usdcMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.usdtProxy = USDT_USD_PROXY;
        config.usdtMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
    }

    function deploy(Config memory config) public virtual returns (Deployment memory deployment) {
        console2.log("Deploying PegKeeperV3 implementation");
        deployment.implementation = _create(vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"));

        console2.log("Deploying PegKeeperPolicy");
        deployment.policy = _deployPolicy(config);

        console2.log("Deploying PegKeeperV3Factory");
        deployment.factory = _deployFactory(config, deployment.implementation, deployment.policy);

        console2.log("Deploying Chainlink frxUSD/USD oracle");
        deployment.frxUsdUsdOracle =
            _deployChainlinkAdapter(config.frxUsdProxy, config.frxUsdMaxDelay);

        console2.log("Deploying Chainlink USDe/USD oracle");
        deployment.usdeUsdOracle = _deployChainlinkAdapter(config.usdeProxy, config.usdeMaxDelay);

        console2.log("Deploying Chainlink USDC/USD oracle");
        deployment.usdcUsdOracle = _deployChainlinkAdapter(config.usdcProxy, config.usdcMaxDelay);

        console2.log("Deploying Chainlink USDT/USD oracle");
        deployment.usdtUsdOracle = _deployChainlinkAdapter(config.usdtProxy, config.usdtMaxDelay);

        _verifyDeployment(deployment, config);
    }

    function writeDeploymentJson(Deployment memory deployment, string memory outputPath) public {
        string memory objectKey = "pegKeeperV3";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "implementation", deployment.implementation);
        vm.serializeAddress(objectKey, "policy", deployment.policy);
        vm.serializeAddress(objectKey, "factory", deployment.factory);
        vm.serializeAddress(objectKey, "frxUsdUsdOracle", deployment.frxUsdUsdOracle);
        vm.serializeAddress(objectKey, "usdeUsdOracle", deployment.usdeUsdOracle);
        vm.serializeAddress(objectKey, "usdcUsdOracle", deployment.usdcUsdOracle);
        string memory json =
            vm.serializeAddress(objectKey, "usdtUsdOracle", deployment.usdtUsdOracle);
        vm.writeJson(json, outputPath);
    }

    function _deployPolicy(Config memory config) internal returns (address) {
        bytes memory creationCode = vm.getCode("out/PegKeeperPolicy.vy/PegKeeperPolicy.json");
        return _create(
            bytes.concat(
                creationCode,
                abi.encode(config.owner, config.aggregateCrvUsdOracle, config.primaryUtilizationBps)
            )
        );
    }

    function _deployFactory(Config memory config, address implementation, address policy)
        internal
        returns (address)
    {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: config.admin,
                emergencyAdmin: config.emergencyAdmin,
                feeReceiver: config.feeReceiver,
                maxDeployedCrvUsd: config.maxDeployedCrvUsd,
                ammExecutionBufferBps: config.ammExecutionBufferBps
            });
        bytes memory creationCode = vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json");
        return _create(
            bytes.concat(
                creationCode,
                abi.encode(
                    config.owner, config.controllerFactory, implementation, policy, defaults_
                )
            )
        );
    }

    function _deployChainlinkAdapter(address feed, uint256 maxDelay)
        internal
        virtual
        returns (address)
    {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        return _create(bytes.concat(creationCode, abi.encode(feed, maxDelay)));
    }

    function _create(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "CREATE failed");
    }

    function _verifyDeployment(Deployment memory deployment, Config memory config) internal view {
        require(
            deployment.implementation.code.length <= EIP_170_RUNTIME_LIMIT,
            "implementation too large"
        );
        require(deployment.policy.code.length <= EIP_170_RUNTIME_LIMIT, "policy too large");
        require(deployment.factory.code.length <= EIP_170_RUNTIME_LIMIT, "factory too large");

        IPegKeeperV3 implementation = IPegKeeperV3(deployment.implementation);
        require(implementation.initialized(), "implementation not locked");

        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        require(policy.owner() == config.owner, "policy owner mismatch");
        require(policy.pendingOwner() == address(0), "unexpected policy pending owner");
        require(policy.factory() == address(0), "policy bound before governance");
        require(
            policy.aggregateCrvUsdOracle() == config.aggregateCrvUsdOracle,
            "aggregate oracle mismatch"
        );
        require(
            policy.primaryUtilizationBps() == config.primaryUtilizationBps,
            "primary threshold mismatch"
        );

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);
        require(factory.owner() == config.owner, "factory owner mismatch");
        require(factory.controllerFactory() == config.controllerFactory, "controller mismatch");
        require(factory.implementation() == deployment.implementation, "implementation mismatch");
        require(factory.policy() == deployment.policy, "factory policy mismatch");
        require(factory.activePegKeeperCount() == 0, "unexpected active keeper");

        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        require(defaults_.admin == config.admin, "default admin mismatch");
        require(defaults_.emergencyAdmin == config.emergencyAdmin, "emergency mismatch");
        require(defaults_.feeReceiver == config.feeReceiver, "fee receiver mismatch");
        require(
            defaults_.maxDeployedCrvUsd == config.maxDeployedCrvUsd, "default capacity mismatch"
        );
        require(
            defaults_.ammExecutionBufferBps == config.ammExecutionBufferBps,
            "default AMM buffer mismatch"
        );

        _verifyChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _verifyChainlinkOracle(deployment.usdeUsdOracle, config.usdeProxy, config.usdeMaxDelay);
        _verifyChainlinkOracle(deployment.usdcUsdOracle, config.usdcProxy, config.usdcMaxDelay);
        _verifyChainlinkOracle(deployment.usdtUsdOracle, config.usdtProxy, config.usdtMaxDelay);
    }

    function _verifyChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(adapter.code.length > 0, "Chainlink oracle code missing");
        require(oracle.feed() == feed, "Chainlink oracle feed mismatch");
        require(oracle.max_delay() == maxDelay, "Chainlink oracle delay mismatch");
    }

    function _logPlan(Config memory config) internal view {
        console2.log("Network chain id", block.chainid);
        console2.log("Factory owner", config.owner);
        console2.log("ControllerFactory", config.controllerFactory);
        console2.log("Aggregate crvUSD oracle", config.aggregateCrvUsdOracle);
        console2.log("Factory admin", config.admin);
        console2.log("Emergency admin", config.emergencyAdmin);
        console2.log("Fee receiver", config.feeReceiver);
        console2.log("Primary utilization (bps)", config.primaryUtilizationBps);
        console2.log("Initial max deployed crvUSD", config.maxDeployedCrvUsd);
        console2.log("AMM execution buffer (bps)", config.ammExecutionBufferBps);
        console2.log("frxUSD Chainlink proxy", config.frxUsdProxy);
        console2.log("USDe Chainlink proxy", config.usdeProxy);
        console2.log("USDC Chainlink proxy", config.usdcProxy);
        console2.log("USDT Chainlink proxy", config.usdtProxy);
        console2.log("Output", DEPLOYMENT_OUTPUT_PATH);
    }

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("Implementation", deployment.implementation);
        console2.log("Policy", deployment.policy);
        console2.log("Factory", deployment.factory);
        console2.log("Chainlink frxUSD/USD oracle", deployment.frxUsdUsdOracle);
        console2.log("Chainlink USDe/USD oracle", deployment.usdeUsdOracle);
        console2.log("Chainlink USDC/USD oracle", deployment.usdcUsdOracle);
        console2.log("Chainlink USDT/USD oracle", deployment.usdtUsdOracle);
        console2.log("Deployment JSON", DEPLOYMENT_OUTPUT_PATH);
    }
}
