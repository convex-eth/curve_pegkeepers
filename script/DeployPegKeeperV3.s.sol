// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";

/// @notice Deploys and configures the complete direct-liquidity PegKeeperV3 candidate set.
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

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant SUSDE_CRVUSD_POOL = 0x57064F49Ad7123C92560882a45518374ad982e85;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    uint256 public constant RECOMMENDED_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant RECOMMENDED_USDE_CHAINLINK_MAX_DELAY = 25 hours;
    uint256 public constant PRIMARY_UTILIZATION_BPS = 8_000;
    uint256 public constant INITIAL_MAX_DEPLOYED_CRVUSD = 20_000_000e18;
    uint256 public constant AMM_EXECUTION_BUFFER_BPS = 3;
    uint256 public constant MIN_BACKING_ORACLE_PRICE = 999_000_000_000_000_000;
    uint256 public constant ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant NORMAL_EXIT_MIN_PROFIT_PPM = 500;
    uint256 public constant LAST_RESORT_ENTRY_MIN_PROFIT_PPM = 500;
    uint256 public constant LAST_RESORT_EXIT_MIN_PROFIT_PPM = 100;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant MIN_EXPANSION_AMOUNT = 10_000e18;
    uint256 public constant MAX_INTERVENTION_SHARE_BPS = 3_333;
    uint256 public constant MIN_INTERVENTION_DELAY = 12 seconds;

    uint256 public constant TIER_PRIMARY = 1;
    uint256 public constant TIER_SECONDARY = 2;
    uint256 public constant TIER_TERTIARY = 3;

    struct Config {
        address owner;
        address finalOwner;
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
        address frxUsdCrvUsdPool;
        address sUsdeCrvUsdPool;
        address usdcCrvUsdPool;
        address usdtCrvUsdPool;
    }

    struct Deployment {
        address initialOwner;
        address implementation;
        address policy;
        address factory;
        address frxUsdUsdOracle;
        address usdeUsdOracle;
        address usdcUsdOracle;
        address usdtUsdOracle;
        address frxUsdPegKeeper;
        address sUsdePegKeeper;
        address usdcPegKeeper;
        address usdtPegKeeper;
        uint256 factoryOwnershipNonce;
        uint256 policyOwnershipNonce;
    }

    function run() external virtual returns (Deployment memory deployment) {
        require(block.chainid == 1, "mainnet required");
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        Config memory config = mainnetConfig(broadcaster);
        _logPlan(config);
        deployment = deploy(config);
        vm.stopBroadcast();

        writeDeploymentJson(deployment, DEPLOYMENT_OUTPUT_PATH);
        _logDeployment(deployment);
    }

    function mainnetConfig(address initialOwner) public pure returns (Config memory config) {
        require(
            initialOwner != address(0) && initialOwner != CURVE_OWNERSHIP_AGENT, "initial owner"
        );
        config.owner = initialOwner;
        config.finalOwner = CURVE_OWNERSHIP_AGENT;
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
        config.frxUsdCrvUsdPool = FRXUSD_CRVUSD_POOL;
        config.sUsdeCrvUsdPool = SUSDE_CRVUSD_POOL;
        config.usdcCrvUsdPool = USDC_CRVUSD_POOL;
        config.usdtCrvUsdPool = USDT_CRVUSD_POOL;
    }

    function deploy(Config memory config) public virtual returns (Deployment memory deployment) {
        deployment = deployDependencies(config);
        _configureKeepersAndHandoff(deployment, config);
        _verifyConfiguredDeployment(deployment, config);
    }

    function deployDependencies(Config memory config)
        public
        virtual
        returns (Deployment memory deployment)
    {
        deployment.initialOwner = config.owner;
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

        _verifyDependencyDeployment(deployment, config);
    }

    function writeDeploymentJson(Deployment memory deployment, string memory outputPath) public {
        string memory objectKey = "pegKeeperV3";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "initialOwner", deployment.initialOwner);
        vm.serializeAddress(objectKey, "implementation", deployment.implementation);
        vm.serializeAddress(objectKey, "policy", deployment.policy);
        vm.serializeAddress(objectKey, "factory", deployment.factory);
        vm.serializeAddress(objectKey, "frxUsdUsdOracle", deployment.frxUsdUsdOracle);
        vm.serializeAddress(objectKey, "usdeUsdOracle", deployment.usdeUsdOracle);
        vm.serializeAddress(objectKey, "usdcUsdOracle", deployment.usdcUsdOracle);
        vm.serializeAddress(objectKey, "usdtUsdOracle", deployment.usdtUsdOracle);
        vm.serializeAddress(objectKey, "frxUsdPegKeeper", deployment.frxUsdPegKeeper);
        vm.serializeAddress(objectKey, "sUsdePegKeeper", deployment.sUsdePegKeeper);
        vm.serializeAddress(objectKey, "usdcPegKeeper", deployment.usdcPegKeeper);
        vm.serializeAddress(objectKey, "usdtPegKeeper", deployment.usdtPegKeeper);
        vm.serializeUint(objectKey, "factoryOwnershipNonce", deployment.factoryOwnershipNonce);
        string memory json =
            vm.serializeUint(objectKey, "policyOwnershipNonce", deployment.policyOwnershipNonce);
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
                admin: config.owner,
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

    function _configureKeepersAndHandoff(Deployment memory deployment, Config memory config)
        internal
    {
        require(config.finalOwner != address(0) && config.finalOwner != config.owner, "final owner");
        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);

        policy.set_factory(deployment.factory);

        deployment.frxUsdPegKeeper = factory.deployPegKeeper(
            config.frxUsdCrvUsdPool, false, true, deployment.frxUsdUsdOracle
        );
        policy.set_tier(deployment.frxUsdPegKeeper, TIER_PRIMARY);
        _configureKeeper(
            deployment.frxUsdPegKeeper,
            deployment.frxUsdUsdOracle,
            ENTRY_MIN_PROFIT_PPM,
            NORMAL_EXIT_MIN_PROFIT_PPM,
            config.maxDeployedCrvUsd
        );

        deployment.sUsdePegKeeper =
            factory.deployPegKeeper(config.sUsdeCrvUsdPool, true, true, deployment.usdeUsdOracle);
        policy.set_tier(deployment.sUsdePegKeeper, TIER_SECONDARY);
        _configureKeeper(
            deployment.sUsdePegKeeper,
            deployment.usdeUsdOracle,
            ENTRY_MIN_PROFIT_PPM,
            NORMAL_EXIT_MIN_PROFIT_PPM,
            config.maxDeployedCrvUsd
        );

        deployment.usdcPegKeeper =
            factory.deployPegKeeper(config.usdcCrvUsdPool, false, false, deployment.usdcUsdOracle);
        policy.set_tier(deployment.usdcPegKeeper, TIER_TERTIARY);
        _configureKeeper(
            deployment.usdcPegKeeper,
            deployment.usdcUsdOracle,
            LAST_RESORT_ENTRY_MIN_PROFIT_PPM,
            LAST_RESORT_EXIT_MIN_PROFIT_PPM,
            config.maxDeployedCrvUsd
        );

        deployment.usdtPegKeeper =
            factory.deployPegKeeper(config.usdtCrvUsdPool, false, false, deployment.usdtUsdOracle);
        policy.set_tier(deployment.usdtPegKeeper, TIER_TERTIARY);
        _configureKeeper(
            deployment.usdtPegKeeper,
            deployment.usdtUsdOracle,
            LAST_RESORT_ENTRY_MIN_PROFIT_PPM,
            LAST_RESORT_EXIT_MIN_PROFIT_PPM,
            config.maxDeployedCrvUsd
        );

        factory.setDefaults(
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: config.admin,
                emergencyAdmin: config.emergencyAdmin,
                feeReceiver: config.feeReceiver,
                maxDeployedCrvUsd: config.maxDeployedCrvUsd,
                ammExecutionBufferBps: config.ammExecutionBufferBps
            })
        );
        factory.transferOwnership(config.finalOwner);
        policy.transferOwnership(config.finalOwner);
        deployment.factoryOwnershipNonce = factory.ownershipTransferNonce();
        deployment.policyOwnershipNonce = policy.ownershipTransferNonce();
    }

    function _configureKeeper(
        address keeperAddress,
        address backingOracle,
        uint256 entryMinProfitPpm,
        uint256 exitMinProfitPpm,
        uint256 maxDeployedCrvUsd
    ) internal {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        keeper.set_backing_oracle_policy(backingOracle, MIN_BACKING_ORACLE_PRICE);
        keeper.set_policy(
            entryMinProfitPpm,
            exitMinProfitPpm,
            KEEPER_PROFIT_SHARE_BPS,
            MIN_EXPANSION_AMOUNT,
            maxDeployedCrvUsd
        );
        keeper.set_intervention_policy(MAX_INTERVENTION_SHARE_BPS, MIN_INTERVENTION_DELAY);
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

    function _verifyDependencyDeployment(Deployment memory deployment, Config memory config)
        internal
        view
    {
        require(deployment.initialOwner == config.owner, "initial owner mismatch");
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
        require(defaults_.admin == config.owner, "initial admin mismatch");
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

    function _verifyConfiguredDeployment(Deployment memory deployment, Config memory config)
        internal
        view
    {
        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        require(policy.owner() == config.owner, "policy owner mismatch");
        require(policy.pendingOwner() == config.finalOwner, "policy pending owner mismatch");
        require(
            policy.ownershipTransferNonce() == deployment.policyOwnershipNonce
                && deployment.policyOwnershipNonce != 0,
            "policy handoff nonce"
        );
        require(policy.factory() == deployment.factory, "policy factory mismatch");
        require(policy.primary() == deployment.frxUsdPegKeeper, "primary mismatch");
        require(policy.tier(deployment.frxUsdPegKeeper) == TIER_PRIMARY, "frxUSD tier mismatch");
        require(policy.tier(deployment.sUsdePegKeeper) == TIER_SECONDARY, "sUSDe tier mismatch");
        require(policy.tier(deployment.usdcPegKeeper) == TIER_TERTIARY, "USDC tier mismatch");
        require(policy.tier(deployment.usdtPegKeeper) == TIER_TERTIARY, "USDT tier mismatch");

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deployment.factory);
        require(factory.owner() == config.owner, "factory owner mismatch");
        require(factory.pendingOwner() == config.finalOwner, "factory pending owner mismatch");
        require(
            factory.ownershipTransferNonce() == deployment.factoryOwnershipNonce
                && deployment.factoryOwnershipNonce != 0,
            "factory handoff nonce"
        );
        require(factory.admin() == config.admin, "final admin mismatch");
        require(factory.activePegKeeperCount() == 4, "keeper count mismatch");
        require(factory.activePegKeeperAt(0) == deployment.frxUsdPegKeeper, "frxUSD order");
        require(factory.activePegKeeperAt(1) == deployment.sUsdePegKeeper, "sUSDe order");
        require(factory.activePegKeeperAt(2) == deployment.usdcPegKeeper, "USDC order");
        require(factory.activePegKeeperAt(3) == deployment.usdtPegKeeper, "USDT order");

        _verifyConfiguredKeeper(
            deployment.frxUsdPegKeeper,
            deployment.factory,
            config.frxUsdCrvUsdPool,
            deployment.frxUsdUsdOracle,
            ENTRY_MIN_PROFIT_PPM,
            NORMAL_EXIT_MIN_PROFIT_PPM,
            config
        );
        _verifyConfiguredKeeper(
            deployment.sUsdePegKeeper,
            deployment.factory,
            config.sUsdeCrvUsdPool,
            deployment.usdeUsdOracle,
            ENTRY_MIN_PROFIT_PPM,
            NORMAL_EXIT_MIN_PROFIT_PPM,
            config
        );
        _verifyConfiguredKeeper(
            deployment.usdcPegKeeper,
            deployment.factory,
            config.usdcCrvUsdPool,
            deployment.usdcUsdOracle,
            LAST_RESORT_ENTRY_MIN_PROFIT_PPM,
            LAST_RESORT_EXIT_MIN_PROFIT_PPM,
            config
        );
        _verifyConfiguredKeeper(
            deployment.usdtPegKeeper,
            deployment.factory,
            config.usdtCrvUsdPool,
            deployment.usdtUsdOracle,
            LAST_RESORT_ENTRY_MIN_PROFIT_PPM,
            LAST_RESORT_EXIT_MIN_PROFIT_PPM,
            config
        );
    }

    function _verifyConfiguredKeeper(
        address keeperAddress,
        address expectedFactory,
        address expectedPool,
        address expectedOracle,
        uint256 expectedEntryProfit,
        uint256 expectedExitProfit,
        Config memory config
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(keeper.factory() == expectedFactory, "keeper factory mismatch");
        require(keeper.pool() == expectedPool, "keeper pool mismatch");
        require(keeper.backing_oracle() == expectedOracle, "keeper oracle mismatch");
        require(keeper.min_backing_oracle_price() == MIN_BACKING_ORACLE_PRICE, "oracle floor");
        require(keeper.entry_min_profit_ppm() == expectedEntryProfit, "entry profit mismatch");
        require(keeper.normal_exit_min_profit_ppm() == expectedExitProfit, "exit profit mismatch");
        require(keeper.keeper_profit_share_bps() == KEEPER_PROFIT_SHARE_BPS, "profit share");
        require(keeper.min_expansion_amount() == MIN_EXPANSION_AMOUNT, "minimum expansion");
        require(keeper.max_deployed_crvusd() == config.maxDeployedCrvUsd, "local cap");
        require(keeper.max_intervention_share_bps() == MAX_INTERVENTION_SHARE_BPS, "share cap");
        require(keeper.min_intervention_delay() == MIN_INTERVENTION_DELAY, "intervention delay");
        require(keeper.admin() == config.admin, "keeper admin mismatch");
        require(!keeper.expansion_paused(), "expansion paused");
        require(!keeper.contraction_paused(), "contraction paused");
        require(!keeper.all_execution_paused(), "execution paused");
        require(keeper.debt() == 0, "keeper debt");
        require(
            IControllerFactory(config.controllerFactory).debt_ceiling(keeperAddress) == 0,
            "keeper prefunded"
        );
    }

    function _verifyChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(adapter.code.length > 0, "Chainlink oracle code missing");
        require(oracle.feed() == feed, "Chainlink oracle feed mismatch");
        require(oracle.max_delay() == maxDelay, "Chainlink oracle delay mismatch");
    }

    function _logPlan(Config memory config) internal view {
        console2.log("Network chain id", block.chainid);
        console2.log("Initial Factory/Policy owner", config.owner);
        console2.log("Pending Factory/Policy owner", config.finalOwner);
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
        console2.log("frxUSD/crvUSD pool", config.frxUsdCrvUsdPool);
        console2.log("sUSDe/crvUSD pool", config.sUsdeCrvUsdPool);
        console2.log("USDC/crvUSD pool", config.usdcCrvUsdPool);
        console2.log("USDT/crvUSD pool", config.usdtCrvUsdPool);
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
        console2.log("frxUSD PegKeeperV3", deployment.frxUsdPegKeeper);
        console2.log("sUSDe PegKeeperV3", deployment.sUsdePegKeeper);
        console2.log("USDC PegKeeperV3", deployment.usdcPegKeeper);
        console2.log("USDT PegKeeperV3", deployment.usdtPegKeeper);
        console2.log("Deployment JSON", DEPLOYMENT_OUTPUT_PATH);
    }
}
