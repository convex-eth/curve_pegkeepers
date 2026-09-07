// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../../../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Accepts Factory/policy ownership for four preconfigured keepers, registers them, and funds three.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant IMPLEMENTATION_RUNTIME_SIZE = 18_203;
    bytes32 public constant EXPECTED_IMPLEMENTATION_RUNTIME_HASH =
        0xdd3ea8d8aaa15acc2f26e7e7d0a5d433c29565a5f568006c3b410dba93541f0a;
    uint256 public constant POLICY_RUNTIME_SIZE = 4_862;
    bytes32 public constant EXPECTED_POLICY_RUNTIME_HASH =
        0x20f48aaea2b14836a961662bcae1706944b96dc17339a8e215a6fe3e82a608fd;
    uint256 public constant FACTORY_CORE_SIZE = 3_963;
    uint256 public constant FACTORY_RUNTIME_SIZE = 4_027;
    bytes32 public constant EXPECTED_FACTORY_CORE_HASH =
        0xcfc318147ad88458f19543d0a8001ed9b046e72c713501b96839d847b8f6799e;
    uint256 public constant CHAINLINK_ORACLE_CORE_SIZE = 431;
    uint256 public constant CHAINLINK_ORACLE_RUNTIME_SIZE = 527;
    bytes32 public constant EXPECTED_CHAINLINK_ORACLE_CORE_HASH =
        0xf2ae2f566e1a5cb82fd67cdf92523dfbb47e6a21347d35a57342cab36791287a;

    uint256 public constant TIER_PRIMARY = 1;
    uint256 public constant TIER_SECONDARY = 2;
    uint256 public constant TIER_TERTIARY = 3;

    uint256 public constant ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant NORMAL_EXIT_MIN_PROFIT_PPM = 500;
    uint256 public constant LAST_RESORT_ENTRY_MIN_PROFIT_PPM = 500;
    uint256 public constant LAST_RESORT_EXIT_MIN_PROFIT_PPM = 100;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant MIN_EXPANSION_AMOUNT = 10_000e18;
    uint256 public constant MAX_INTERVENTION_SHARE_BPS = 3_333;
    uint256 public constant MIN_INTERVENTION_DELAY = 12 seconds;
    uint256 public constant MAX_EXPANSION_BURST_BPS = 500;
    uint256 public constant EXPANSION_REFILL_PERIOD = 5 minutes;
    uint256 public constant MIN_BACKING_ORACLE_PRICE = 999_000_000_000_000_000;
    uint256 public constant FRXUSD_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant USDE_CHAINLINK_MAX_DELAY = 25 hours;
    uint256 public constant STABLECOIN_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant AMM_EXECUTION_BUFFER_BPS = 3;

    uint256 public constant FRXUSD_CAP = 20_000_000e18;
    uint256 public constant SUSDE_LOCAL_CAP = 20_000_000e18;
    uint256 public constant USDC_CAP = 20_000_000e18;
    uint256 public constant USDT_CAP = 20_000_000e18;

    address public constant CURVE_EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant CRVUSD_AGGREGATE_ORACLE = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address public constant CRVUSD_MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address public constant CRVUSD_LEGACY_MONETARY_POLICY =
        0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;

    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    address public constant USDE_USD_PROXY = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address public constant USDC_USD_PROXY = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDT_USD_PROXY = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant SUSDE_CRVUSD_POOL = 0x57064F49Ad7123C92560882a45518374ad982e85;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address public deploymentFactory;
    address public deploymentInitialOwner;
    address public pegKeeperPolicy;
    address public frxUsdOracle;
    address public usdeOracle;
    address public usdcOracle;
    address public usdtOracle;
    address public frxUsdKeeper;
    address public sUsdeKeeper;
    address public usdcKeeper;
    address public usdtKeeper;
    uint256 public factoryOwnershipNonce;
    uint256 public policyOwnershipNonce;

    function run() external returns (uint256 proposalId) {
        loadDeployment(DEPLOYMENT_INPUT_PATH);
        vm.startBroadcast();
        proposalId = proposeOwnershipVote(
            buildProposalScript(),
            "Accept and activate four direct PegKeeperV3 keepers with three-tier priority"
        );
        vm.stopBroadcast();
    }

    function loadDeployment(string memory path) public {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment chain");
        deploymentInitialOwner = vm.parseJsonAddress(json, ".initialOwner");
        deploymentFactory = vm.parseJsonAddress(json, ".factory");
        pegKeeperPolicy = vm.parseJsonAddress(json, ".policy");
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle");
        usdeOracle = vm.parseJsonAddress(json, ".usdeUsdOracle");
        usdcOracle = vm.parseJsonAddress(json, ".usdcUsdOracle");
        usdtOracle = vm.parseJsonAddress(json, ".usdtUsdOracle");
        frxUsdKeeper = vm.parseJsonAddress(json, ".frxUsdPegKeeper");
        sUsdeKeeper = vm.parseJsonAddress(json, ".sUsdePegKeeper");
        usdcKeeper = vm.parseJsonAddress(json, ".usdcPegKeeper");
        usdtKeeper = vm.parseJsonAddress(json, ".usdtPegKeeper");
        factoryOwnershipNonce = vm.parseJsonUint(json, ".factoryOwnershipNonce");
        policyOwnershipNonce = vm.parseJsonUint(json, ".policyOwnershipNonce");
    }

    function setDeployment(
        address initialOwner,
        address factory,
        address policy,
        address[4] calldata oracles,
        address[4] calldata keepers,
        uint256[2] calldata handoffNonces
    ) external {
        require(
            initialOwner != address(0) && factory != address(0) && policy != address(0)
                && oracles[0] != address(0) && oracles[1] != address(0) && oracles[2] != address(0)
                && oracles[3] != address(0) && keepers[0] != address(0) && keepers[1] != address(0)
                && keepers[2] != address(0) && keepers[3] != address(0) && handoffNonces[0] != 0
                && handoffNonces[1] != 0,
            "zero dependency"
        );
        deploymentInitialOwner = initialOwner;
        deploymentFactory = factory;
        pegKeeperPolicy = policy;
        frxUsdOracle = oracles[0];
        usdeOracle = oracles[1];
        usdcOracle = oracles[2];
        usdtOracle = oracles[3];
        frxUsdKeeper = keepers[0];
        sUsdeKeeper = keepers[1];
        usdcKeeper = keepers[2];
        usdtKeeper = keepers[3];
        factoryOwnershipNonce = handoffNonces[0];
        policyOwnershipNonce = handoffNonces[1];
    }

    function expectedKeeper(uint256 keeperNumber) public view returns (address) {
        require(deploymentFactory != address(0), "factory not set");
        require(keeperNumber > 0 && keeperNumber <= 4, "keeper number");
        if (keeperNumber == 1) return frxUsdKeeper;
        if (keeperNumber == 2) return sUsdeKeeper;
        if (keeperNumber == 3) return usdcKeeper;
        return usdtKeeper;
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        script = buildScript(CURVE_OWNERSHIP_AGENT, buildProposalActions());
    }

    function buildProposalActions() public view returns (Action[] memory actions) {
        _validateDependencies();
        _validateMonetaryPolicies();

        address[4] memory keepers = [frxUsdKeeper, sUsdeKeeper, usdcKeeper, usdtKeeper];
        actions = new Action[](13);
        actions[0] = Action({
            target: deploymentFactory,
            data: abi.encodeWithSelector(
                IPegKeeperV3Factory.acceptOwnership.selector, factoryOwnershipNonce
            )
        });
        actions[1] = Action({
            target: pegKeeperPolicy,
            data: abi.encodeWithSelector(
                IPegKeeperPolicy.acceptOwnership.selector, policyOwnershipNonce
            )
        });

        uint256 actionIndex = 2;
        for (uint256 i; i < keepers.length; ++i) {
            actions[actionIndex++] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, keepers[i]);
            actions[actionIndex++] =
                _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, keepers[i]);
        }

        actions[10] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[11] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[12] = _debtCeilingAction(usdtKeeper, USDT_CAP);
    }

    function _validateDependencies() internal view {
        require(deploymentInitialOwner != address(0), "initial owner not set");
        require(deploymentInitialOwner != CURVE_OWNERSHIP_AGENT, "initial owner already DAO");
        require(deploymentFactory != address(0), "factory not set");
        require(pegKeeperPolicy != address(0), "policy not set");

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deploymentFactory);
        require(factory.owner() == deploymentInitialOwner, "factory owner");
        require(factory.pendingOwner() == CURVE_OWNERSHIP_AGENT, "factory pending owner");
        require(factory.ownershipTransferNonce() == factoryOwnershipNonce, "factory handoff nonce");
        require(
            factory.controllerFactory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "controller factory"
        );
        require(factory.policy() == pegKeeperPolicy, "factory policy");
        require(factory.admin() == CURVE_OWNERSHIP_AGENT, "factory admin");
        require(factory.emergency_admin() == CURVE_EMERGENCY_ADMIN, "factory emergency admin");
        require(factory.fee_receiver() == FEE_SPLITTER, "factory fee receiver");
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        require(defaults_.maxDeployedCrvUsd == FRXUSD_CAP, "factory default cap");
        require(
            defaults_.ammExecutionBufferBps == AMM_EXECUTION_BUFFER_BPS, "factory default buffer"
        );
        require(factory.activePegKeeperCount() == 4, "factory keeper count");
        require(factory.activePegKeeperAt(0) == frxUsdKeeper, "frxUSD keeper order");
        require(factory.activePegKeeperAt(1) == sUsdeKeeper, "sUSDe keeper order");
        require(factory.activePegKeeperAt(2) == usdcKeeper, "USDC keeper order");
        require(factory.activePegKeeperAt(3) == usdtKeeper, "USDT keeper order");

        address implementation = factory.implementation();
        require(IPegKeeperV3(implementation).initialized(), "implementation unlocked");
        if (IMPLEMENTATION_RUNTIME_SIZE != 0) {
            require(
                implementation.code.length == IMPLEMENTATION_RUNTIME_SIZE, "implementation size"
            );
            require(
                implementation.codehash == EXPECTED_IMPLEMENTATION_RUNTIME_HASH,
                "implementation hash"
            );
        }

        IPegKeeperPolicy policy = IPegKeeperPolicy(pegKeeperPolicy);
        require(policy.owner() == deploymentInitialOwner, "policy owner");
        require(policy.pendingOwner() == CURVE_OWNERSHIP_AGENT, "policy pending owner");
        require(policy.ownershipTransferNonce() == policyOwnershipNonce, "policy handoff nonce");
        require(policy.factory() == deploymentFactory, "policy factory");
        require(policy.aggregateCrvUsdOracle() == CRVUSD_AGGREGATE_ORACLE, "aggregate oracle");
        require(policy.primaryUtilizationBps() == 8_000, "primary threshold");
        require(
            policy.keeper_profit_share_bps(frxUsdKeeper) == KEEPER_PROFIT_SHARE_BPS,
            "frxUSD profit share"
        );
        require(
            policy.keeper_profit_share_bps(sUsdeKeeper) == KEEPER_PROFIT_SHARE_BPS,
            "sUSDe profit share"
        );
        require(
            policy.keeper_profit_share_bps(usdcKeeper) == KEEPER_PROFIT_SHARE_BPS,
            "USDC profit share"
        );
        require(
            policy.keeper_profit_share_bps(usdtKeeper) == KEEPER_PROFIT_SHARE_BPS,
            "USDT profit share"
        );
        require(policy.primary() == frxUsdKeeper, "primary keeper");
        require(policy.tier(frxUsdKeeper) == TIER_PRIMARY, "frxUSD tier");
        require(policy.tier(sUsdeKeeper) == TIER_SECONDARY, "sUSDe tier");
        require(policy.tier(usdcKeeper) == TIER_TERTIARY, "USDC tier");
        require(policy.tier(usdtKeeper) == TIER_TERTIARY, "USDT tier");
        require(policy.secondaryCount() == 1, "secondary count");
        require(policy.secondaryAt(0) == sUsdeKeeper, "secondary keeper");
        require(policy.tertiaryCount() == 2, "tertiary count");
        require(policy.tertiaryAt(0) == usdcKeeper, "USDC tertiary order");
        require(policy.tertiaryAt(1) == usdtKeeper, "USDT tertiary order");
        if (POLICY_RUNTIME_SIZE != 0) {
            require(pegKeeperPolicy.code.length == POLICY_RUNTIME_SIZE, "policy size");
            require(pegKeeperPolicy.codehash == EXPECTED_POLICY_RUNTIME_HASH, "policy hash");
        }

        if (FACTORY_RUNTIME_SIZE != 0) {
            require(deploymentFactory.code.length == FACTORY_RUNTIME_SIZE, "factory size");
            require(
                _coreHash(deploymentFactory, FACTORY_CORE_SIZE) == EXPECTED_FACTORY_CORE_HASH,
                "factory hash"
            );
        }

        _validateKeeperAssets(
            frxUsdKeeper, FRXUSD_CRVUSD_POOL, FRXUSD, FRXUSD, frxUsdOracle, false, true
        );
        _validateKeeperConfig(
            frxUsdKeeper, ENTRY_MIN_PROFIT_PPM, NORMAL_EXIT_MIN_PROFIT_PPM, FRXUSD_CAP
        );
        _validateKeeperAssets(sUsdeKeeper, SUSDE_CRVUSD_POOL, SUSDE, USDE, usdeOracle, true, true);
        _validateKeeperConfig(
            sUsdeKeeper, ENTRY_MIN_PROFIT_PPM, NORMAL_EXIT_MIN_PROFIT_PPM, SUSDE_LOCAL_CAP
        );
        _validateKeeperAssets(usdcKeeper, USDC_CRVUSD_POOL, USDC, USDC, usdcOracle, false, false);
        _validateKeeperConfig(
            usdcKeeper, LAST_RESORT_ENTRY_MIN_PROFIT_PPM, LAST_RESORT_EXIT_MIN_PROFIT_PPM, USDC_CAP
        );
        _validateKeeperAssets(usdtKeeper, USDT_CRVUSD_POOL, USDT, USDT, usdtOracle, false, false);
        _validateKeeperConfig(
            usdtKeeper, LAST_RESORT_ENTRY_MIN_PROFIT_PPM, LAST_RESORT_EXIT_MIN_PROFIT_PPM, USDT_CAP
        );

        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY, FRXUSD_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdeOracle, USDE_USD_PROXY, USDE_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdcOracle, USDC_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdtOracle, USDT_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
    }

    function _validateKeeperAssets(
        address keeperAddress,
        address expectedPool,
        address expectedPairedToken,
        address expectedBackingAsset,
        address expectedOracle,
        bool expectedErc4626,
        bool expectedDynamicArrays
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(keeperAddress.code.length > 0, "keeper code");
        require(keeper.factory() == deploymentFactory, "keeper factory");
        require(keeper.controller_factory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "keeper controller");
        require(keeper.pool() == expectedPool, "keeper pool");
        require(keeper.paired_token() == expectedPairedToken, "keeper paired token");
        require(keeper.backing_asset() == expectedBackingAsset, "keeper backing asset");
        require(keeper.backing_oracle() == expectedOracle, "keeper oracle");
        require(keeper.paired_token_is_erc4626() == expectedErc4626, "keeper ERC4626 mode");
        require(keeper.pool_uses_dynamic_arrays() == expectedDynamicArrays, "keeper liquidity mode");
    }

    function _validateKeeperConfig(
        address keeperAddress,
        uint256 expectedEntryProfit,
        uint256 expectedExitProfit,
        uint256 expectedLocalCap
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        require(keeper.min_backing_oracle_price() == MIN_BACKING_ORACLE_PRICE, "oracle floor");
        require(keeper.entry_min_profit_ppm() == expectedEntryProfit, "entry profit");
        require(keeper.normal_exit_min_profit_ppm() == expectedExitProfit, "exit profit");
        require(keeper.min_expansion_amount() == MIN_EXPANSION_AMOUNT, "minimum expansion");
        require(keeper.max_deployed_crvusd() == expectedLocalCap, "local cap");
        require(keeper.max_intervention_share_bps() == MAX_INTERVENTION_SHARE_BPS, "share cap");
        require(keeper.min_intervention_delay() == MIN_INTERVENTION_DELAY, "intervention delay");
        require(keeper.max_expansion_burst_bps() == MAX_EXPANSION_BURST_BPS, "expansion burst");
        require(keeper.expansion_refill_period() == EXPANSION_REFILL_PERIOD, "expansion refill");
        require(keeper.amm_execution_buffer_bps() == AMM_EXECUTION_BUFFER_BPS, "AMM buffer");
        require(keeper.admin() == CURVE_OWNERSHIP_AGENT, "keeper admin");
        require(keeper.emergency_admin() == CURVE_EMERGENCY_ADMIN, "keeper emergency admin");
        require(keeper.fee_receiver() == FEE_SPLITTER, "keeper fee receiver");
        require(!keeper.expansion_paused(), "keeper expansion paused");
        require(!keeper.contraction_paused(), "keeper contraction paused");
        require(!keeper.all_execution_paused(), "keeper execution paused");
        require(keeper.debt() == 0, "keeper debt");
        require(
            IControllerFactory(CURVE_CRVUSD_CONTROLLER_FACTORY).debt_ceiling(keeperAddress) == 0,
            "keeper prefunded"
        );
        require(
            IERC20(IControllerFactory(CURVE_CRVUSD_CONTROLLER_FACTORY).stablecoin())
                .allowance(keeperAddress, CURVE_CRVUSD_CONTROLLER_FACTORY) == type(uint256).max,
            "keeper ControllerFactory allowance"
        );
    }

    function _validateChainlinkOracle(address adapter, address expectedFeed, uint256 maxDelay)
        internal
        view
    {
        require(adapter.code.length == CHAINLINK_ORACLE_RUNTIME_SIZE, "chainlink oracle size");
        require(
            _coreHash(adapter, CHAINLINK_ORACLE_CORE_SIZE) == EXPECTED_CHAINLINK_ORACLE_CORE_HASH,
            "chainlink oracle hash"
        );
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(oracle.feed() == expectedFeed, "oracle feed");
        require(oracle.feed_decimals() == 8, "oracle decimals");
        require(oracle.max_delay() == maxDelay, "oracle delay");
        require(oracle.price() >= MIN_BACKING_ORACLE_PRICE, "oracle price");
    }

    function _validateMonetaryPolicies() internal view {
        _validateMonetaryPolicy(CRVUSD_MONETARY_POLICY);
        _validateMonetaryPolicy(CRVUSD_LEGACY_MONETARY_POLICY);
    }

    function _validateMonetaryPolicy(address policyAddress) internal view {
        IAggMonetaryPolicy monetaryPolicy = IAggMonetaryPolicy(policyAddress);
        require(monetaryPolicy.admin() == CURVE_OWNERSHIP_AGENT, "monetary policy admin");
        require(
            monetaryPolicy.CONTROLLER_FACTORY() == CURVE_CRVUSD_CONTROLLER_FACTORY,
            "monetary policy factory"
        );
    }

    function _debtCeilingAction(address keeper, uint256 cap) internal view returns (Action memory) {
        return _executeViaCrvUsdEDAOProxy(
            CURVE_CRVUSD_CONTROLLER_FACTORY,
            abi.encodeWithSelector(IControllerFactory.set_debt_ceiling.selector, keeper, cap)
        );
    }

    function _monetaryPolicyAction(address policyAddress, address keeper)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            target: policyAddress,
            data: abi.encodeWithSelector(IAggMonetaryPolicy.add_peg_keeper.selector, keeper)
        });
    }

    function _coreHash(address target, uint256 size) internal view returns (bytes32 result) {
        assembly {
            let pointer := mload(0x40)
            extcodecopy(target, pointer, 0, size)
            result := keccak256(pointer, size)
        }
    }
}
