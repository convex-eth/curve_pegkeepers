// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperRegistry} from "../src/interfaces/IPegKeeperRegistry.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

/// @notice Deploys the complete standalone direct-liquidity PegKeeperV3 candidate set.
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
    address public constant USDC_USD_PROXY = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDT_USD_PROXY = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    uint256 public constant RECOMMENDED_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant INITIAL_MAX_DEBT = 150_000_000e18;
    uint256 public constant AMM_EXECUTION_BUFFER_BPS = 3;
    uint256 public constant MIN_BACKING_ORACLE_PRICE = 999_000_000_000_000_000;
    uint256 public constant FRXUSD_ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant FRXUSD_EXIT_MIN_PROFIT_PPM = 150;
    uint256 public constant STABLECOIN_ENTRY_MIN_PROFIT_PPM = 300;
    uint256 public constant STABLECOIN_EXIT_MIN_PROFIT_PPM = 80;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant ACTION_IMBALANCE_BPS = 2_000;
    uint256 public constant ACTION_DELAY = 12 seconds;

    struct Config {
        address controllerFactory;
        address aggregateCrvUsdOracle;
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 keeperProfitShareBps;
        uint256 maxDebt;
        uint256 ammExecutionBufferBps;
        address frxUsdProxy;
        uint256 frxUsdMaxDelay;
        address usdcProxy;
        uint256 usdcMaxDelay;
        address usdtProxy;
        uint256 usdtMaxDelay;
        address frxUsdCrvUsdPool;
        address usdcCrvUsdPool;
        address usdtCrvUsdPool;
    }

    struct Deployment {
        address policy;
        address registry;
        address frxUsdUsdOracle;
        address usdcUsdOracle;
        address usdtUsdOracle;
        address frxUsdPegKeeper;
        address usdcPegKeeper;
        address usdtPegKeeper;
    }

    struct KeeperConfig {
        address pool;
        bool pairedTokenIsErc4626;
        bool poolUsesDynamicArrays;
        uint256 keeperIndex;
        address backingOracle;
        uint256 entryMinProfitPpm;
        uint256 exitMinProfitPpm;
    }

    function run() external virtual returns (Deployment memory deployment) {
        require(block.chainid == 1, "mainnet required");
        vm.startBroadcast();
        Config memory config = mainnetConfig();
        _logPlan(config);
        deployment = deploy(config);
        vm.stopBroadcast();

        writeDeploymentJson(deployment, DEPLOYMENT_OUTPUT_PATH);
        _logDeployment(deployment);
    }

    function mainnetConfig() public pure returns (Config memory config) {
        config.controllerFactory = CRVUSD_CONTROLLER_FACTORY;
        config.aggregateCrvUsdOracle = CRVUSD_AGGREGATE_ORACLE;
        config.admin = CURVE_OWNERSHIP_AGENT;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.keeperProfitShareBps = KEEPER_PROFIT_SHARE_BPS;
        config.maxDebt = INITIAL_MAX_DEBT;
        config.ammExecutionBufferBps = AMM_EXECUTION_BUFFER_BPS;
        config.frxUsdProxy = FRXUSD_USD_PROXY;
        config.frxUsdMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.usdcProxy = USDC_USD_PROXY;
        config.usdcMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.usdtProxy = USDT_USD_PROXY;
        config.usdtMaxDelay = RECOMMENDED_CHAINLINK_MAX_DELAY;
        config.frxUsdCrvUsdPool = FRXUSD_CRVUSD_POOL;
        config.usdcCrvUsdPool = USDC_CRVUSD_POOL;
        config.usdtCrvUsdPool = USDT_CRVUSD_POOL;
    }

    function deploy(Config memory config) public virtual returns (Deployment memory deployment) {
        console2.log("Deploying PegKeeperPolicy");
        deployment.policy = _deployPolicy(config);

        console2.log("Deploying PegKeeperRegistry");
        deployment.registry = _deployRegistry(config);

        console2.log("Deploying Chainlink frxUSD/USD oracle");
        deployment.frxUsdUsdOracle =
            _deployChainlinkAdapter(config.frxUsdProxy, config.frxUsdMaxDelay);

        console2.log("Deploying Chainlink USDC/USD oracle");
        deployment.usdcUsdOracle = _deployChainlinkAdapter(config.usdcProxy, config.usdcMaxDelay);

        console2.log("Deploying Chainlink USDT/USD oracle");
        deployment.usdtUsdOracle = _deployChainlinkAdapter(config.usdtProxy, config.usdtMaxDelay);

        console2.log("Deploying standalone frxUSD PegKeeperV3");
        deployment.frxUsdPegKeeper = _deployKeeper(
            config,
            deployment.policy,
            KeeperConfig({
                pool: config.frxUsdCrvUsdPool,
                pairedTokenIsErc4626: false,
                poolUsesDynamicArrays: true,
                keeperIndex: 1,
                backingOracle: deployment.frxUsdUsdOracle,
                entryMinProfitPpm: FRXUSD_ENTRY_MIN_PROFIT_PPM,
                exitMinProfitPpm: FRXUSD_EXIT_MIN_PROFIT_PPM
            })
        );

        console2.log("Deploying standalone USDC PegKeeperV3");
        deployment.usdcPegKeeper = _deployKeeper(
            config,
            deployment.policy,
            KeeperConfig({
                pool: config.usdcCrvUsdPool,
                pairedTokenIsErc4626: false,
                poolUsesDynamicArrays: false,
                keeperIndex: 2,
                backingOracle: deployment.usdcUsdOracle,
                entryMinProfitPpm: STABLECOIN_ENTRY_MIN_PROFIT_PPM,
                exitMinProfitPpm: STABLECOIN_EXIT_MIN_PROFIT_PPM
            })
        );

        console2.log("Deploying standalone USDT PegKeeperV3");
        deployment.usdtPegKeeper = _deployKeeper(
            config,
            deployment.policy,
            KeeperConfig({
                pool: config.usdtCrvUsdPool,
                pairedTokenIsErc4626: false,
                poolUsesDynamicArrays: false,
                keeperIndex: 3,
                backingOracle: deployment.usdtUsdOracle,
                entryMinProfitPpm: STABLECOIN_ENTRY_MIN_PROFIT_PPM,
                exitMinProfitPpm: STABLECOIN_EXIT_MIN_PROFIT_PPM
            })
        );

        _verifyDependencyDeployment(deployment, config);
        _verifyConfiguredDeployment(deployment, config);
    }

    function writeDeploymentJson(Deployment memory deployment, string memory outputPath) public {
        string memory objectKey = "pegKeeperV3";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "policy", deployment.policy);
        vm.serializeAddress(objectKey, "registry", deployment.registry);
        vm.serializeAddress(objectKey, "frxUsdUsdOracle", deployment.frxUsdUsdOracle);
        vm.serializeAddress(objectKey, "usdcUsdOracle", deployment.usdcUsdOracle);
        vm.serializeAddress(objectKey, "usdtUsdOracle", deployment.usdtUsdOracle);
        vm.serializeAddress(objectKey, "frxUsdPegKeeper", deployment.frxUsdPegKeeper);
        vm.serializeAddress(objectKey, "usdcPegKeeper", deployment.usdcPegKeeper);
        string memory json =
            vm.serializeAddress(objectKey, "usdtPegKeeper", deployment.usdtPegKeeper);
        vm.writeJson(json, outputPath);
    }

    function _deployPolicy(Config memory config) internal returns (address) {
        bytes memory creationCode = vm.getCode("out/PegKeeperPolicy.vy/PegKeeperPolicy.json");
        return _create(
            bytes.concat(
                creationCode,
                abi.encode(config.admin, config.aggregateCrvUsdOracle, config.feeReceiver)
            )
        );
    }

    function _deployRegistry(Config memory config) internal returns (address) {
        bytes memory creationCode = vm.getCode("out/PegKeeperRegistry.vy/PegKeeperRegistry.json");
        return _create(bytes.concat(creationCode, abi.encode(config.admin)));
    }

    function _deployKeeper(Config memory config, address policy, KeeperConfig memory keeperConfig)
        internal
        returns (address)
    {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory coreConfig = abi.encode(
            config.controllerFactory,
            keeperConfig.pool,
            keeperConfig.pairedTokenIsErc4626,
            keeperConfig.poolUsesDynamicArrays,
            config.maxDebt,
            keeperConfig.keeperIndex,
            keeperConfig.backingOracle
        );
        bytes memory governanceConfig = abi.encode(
            keeperConfig.entryMinProfitPpm,
            keeperConfig.exitMinProfitPpm,
            config.ammExecutionBufferBps,
            config.keeperProfitShareBps,
            config.admin,
            config.emergencyAdmin,
            policy
        );
        return _create(bytes.concat(creationCode, coreConfig, governanceConfig));
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
        require(deployment.policy.code.length <= EIP_170_RUNTIME_LIMIT, "policy too large");
        require(deployment.registry.code.length <= EIP_170_RUNTIME_LIMIT, "registry too large");
        require(deployment.frxUsdPegKeeper.code.length <= EIP_170_RUNTIME_LIMIT, "frxUSD too large");
        require(deployment.usdcPegKeeper.code.length <= EIP_170_RUNTIME_LIMIT, "USDC too large");
        require(deployment.usdtPegKeeper.code.length <= EIP_170_RUNTIME_LIMIT, "USDT too large");

        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        require(policy.owner() == config.admin, "policy owner mismatch");
        require(policy.pendingOwner() == address(0), "unexpected policy pending owner");
        require(
            policy.aggregateCrvUsdOracle() == config.aggregateCrvUsdOracle,
            "aggregate oracle mismatch"
        );
        require(policy.fee_receiver() == config.feeReceiver, "fee receiver mismatch");
        IPegKeeperRegistry registry = IPegKeeperRegistry(deployment.registry);
        require(registry.owner() == config.admin, "registry owner mismatch");
        require(registry.pendingOwner() == address(0), "unexpected registry pending owner");
        require(registry.peg_keeper_count() == 0, "registry not empty");
        _verifyChainlinkOracle(
            deployment.frxUsdUsdOracle, config.frxUsdProxy, config.frxUsdMaxDelay
        );
        _verifyChainlinkOracle(deployment.usdcUsdOracle, config.usdcProxy, config.usdcMaxDelay);
        _verifyChainlinkOracle(deployment.usdtUsdOracle, config.usdtProxy, config.usdtMaxDelay);
    }

    function _verifyConfiguredDeployment(Deployment memory deployment, Config memory config)
        internal
        view
    {
        _verifyConfiguredKeeper(
            deployment.frxUsdPegKeeper,
            deployment.policy,
            config.frxUsdCrvUsdPool,
            deployment.frxUsdUsdOracle,
            FRXUSD_ENTRY_MIN_PROFIT_PPM,
            FRXUSD_EXIT_MIN_PROFIT_PPM,
            1,
            config
        );
        _verifyConfiguredKeeper(
            deployment.usdcPegKeeper,
            deployment.policy,
            config.usdcCrvUsdPool,
            deployment.usdcUsdOracle,
            STABLECOIN_ENTRY_MIN_PROFIT_PPM,
            STABLECOIN_EXIT_MIN_PROFIT_PPM,
            2,
            config
        );
        _verifyConfiguredKeeper(
            deployment.usdtPegKeeper,
            deployment.policy,
            config.usdtCrvUsdPool,
            deployment.usdtUsdOracle,
            STABLECOIN_ENTRY_MIN_PROFIT_PPM,
            STABLECOIN_EXIT_MIN_PROFIT_PPM,
            3,
            config
        );
    }

    function _verifyConfiguredKeeper(
        address keeperAddress,
        address expectedPolicy,
        address expectedPool,
        address expectedOracle,
        uint256 expectedEntryProfit,
        uint256 expectedExitProfit,
        uint256 expectedIndex,
        Config memory config
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(keeper.policy() == expectedPolicy, "keeper policy mismatch");
        require(keeper.controller_factory() == config.controllerFactory, "controller mismatch");
        require(
            keeper.crv_usd() == IControllerFactory(config.controllerFactory).stablecoin(),
            "keeper crvUSD mismatch"
        );
        require(keeper.pool() == expectedPool, "keeper pool mismatch");
        require(keeper.backing_oracle() == expectedOracle, "keeper oracle mismatch");
        require(keeper.min_backing_oracle_price() == MIN_BACKING_ORACLE_PRICE, "oracle floor");
        require(keeper.entry_min_profit_ppm() == expectedEntryProfit, "entry profit mismatch");
        require(keeper.normal_exit_min_profit_ppm() == expectedExitProfit, "exit profit mismatch");
        require(keeper.keeper_index() == expectedIndex, "keeper index mismatch");
        require(
            keeper.keeper_profit_share_bps() == config.keeperProfitShareBps,
            "keeper profit share mismatch"
        );
        require(keeper.max_debt() == config.maxDebt, "local cap");
        require(keeper.action_imbalance_bps() == ACTION_IMBALANCE_BPS, "imbalance share");
        require(keeper.action_delay() == ACTION_DELAY, "action delay");
        require(
            keeper.amm_execution_buffer_bps() == config.ammExecutionBufferBps, "execution buffer"
        );
        require(keeper.admin() == config.admin, "keeper admin mismatch");
        require(keeper.emergency_admin() == config.emergencyAdmin, "emergency admin mismatch");
        require(!keeper.expansion_paused(), "expansion paused");
        require(!keeper.contraction_paused(), "contraction paused");
        require(!keeper.all_execution_paused(), "execution paused");
        require(keeper.debt() == 0, "keeper debt");
        address crvUsd = IControllerFactory(config.controllerFactory).stablecoin();
        require(
            IERC20(crvUsd).allowance(keeperAddress, config.controllerFactory) == type(uint256).max,
            "controller factory allowance"
        );
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
        console2.log("Policy / Registry owner / keeper admin", config.admin);
        console2.log("ControllerFactory", config.controllerFactory);
        console2.log("Aggregate crvUSD oracle", config.aggregateCrvUsdOracle);
        console2.log("Emergency admin", config.emergencyAdmin);
        console2.log("Fee receiver", config.feeReceiver);
        console2.log("Keeper profit share (bps)", config.keeperProfitShareBps);
        console2.log("Initial max debt", config.maxDebt);
        console2.log("AMM execution buffer (bps)", config.ammExecutionBufferBps);
        console2.log("frxUSD Chainlink proxy", config.frxUsdProxy);
        console2.log("USDC Chainlink proxy", config.usdcProxy);
        console2.log("USDT Chainlink proxy", config.usdtProxy);
        console2.log("frxUSD/crvUSD pool", config.frxUsdCrvUsdPool);
        console2.log("USDC/crvUSD pool", config.usdcCrvUsdPool);
        console2.log("USDT/crvUSD pool", config.usdtCrvUsdPool);
        console2.log("Output", DEPLOYMENT_OUTPUT_PATH);
    }

    function _logDeployment(Deployment memory deployment) internal pure {
        console2.log("Policy", deployment.policy);
        console2.log("Registry", deployment.registry);
        console2.log("Chainlink frxUSD/USD oracle", deployment.frxUsdUsdOracle);
        console2.log("Chainlink USDC/USD oracle", deployment.usdcUsdOracle);
        console2.log("Chainlink USDT/USD oracle", deployment.usdtUsdOracle);
        console2.log("frxUSD PegKeeperV3", deployment.frxUsdPegKeeper);
        console2.log("USDC PegKeeperV3", deployment.usdcPegKeeper);
        console2.log("USDT PegKeeperV3", deployment.usdtPegKeeper);
        console2.log("Deployment JSON", DEPLOYMENT_OUTPUT_PATH);
    }
}
