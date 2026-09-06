// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IPegKeeperPolicy} from "../../../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Deploys four fully paused direct-liquidity keepers with a three-tier priority policy.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant IMPLEMENTATION_RUNTIME_SIZE = 17_764;
    bytes32 public constant EXPECTED_IMPLEMENTATION_RUNTIME_HASH =
        0xcef94a7ce7d9c25978a7866c4fb82045191148e8fdc05f97e24bfbc9cb4292ff;
    uint256 public constant POLICY_RUNTIME_SIZE = 4_394;
    bytes32 public constant EXPECTED_POLICY_RUNTIME_HASH =
        0x958aef56c99aefc7f1f3fd7a39097d71d04a5dcfe51993a6488f1df53e7c7078;
    uint256 public constant FACTORY_CORE_SIZE = 3_875;
    uint256 public constant FACTORY_RUNTIME_SIZE = 3_939;
    bytes32 public constant EXPECTED_FACTORY_CORE_HASH =
        0x73b019397ebccae92946c77188a3cf07577efc3b3ded1fb331774cae36a1bbb0;
    uint256 public constant CHAINLINK_ORACLE_CORE_SIZE = 460;
    uint256 public constant CHAINLINK_ORACLE_RUNTIME_SIZE = 556;
    bytes32 public constant EXPECTED_CHAINLINK_ORACLE_CORE_HASH =
        0xe03c54b8bf499010cf16ccbd53437316c3fe05e6cc35ef26b042fa36efcc64b3;

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

    address public deploymentFactory;
    address public pegKeeperPolicy;
    address public frxUsdOracle;
    address public usdeOracle;
    address public usdcOracle;
    address public usdtOracle;

    function run() external returns (uint256 proposalId) {
        loadDeployment(DEPLOYMENT_INPUT_PATH);
        vm.startBroadcast();
        proposalId = proposeOwnershipVote(
            buildProposalScript(),
            "Deploy four paused direct PegKeeperV3 keepers with three-tier priority"
        );
        vm.stopBroadcast();
    }

    function loadDeployment(string memory path) public {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment chain");
        deploymentFactory = vm.parseJsonAddress(json, ".factory");
        pegKeeperPolicy = vm.parseJsonAddress(json, ".policy");
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle");
        usdeOracle = vm.parseJsonAddress(json, ".usdeUsdOracle");
        usdcOracle = vm.parseJsonAddress(json, ".usdcUsdOracle");
        usdtOracle = vm.parseJsonAddress(json, ".usdtUsdOracle");
    }

    function setDeployment(
        address factory,
        address policy,
        address frxUsdUsdOracle,
        address usdeUsdOracle,
        address usdcUsdOracle,
        address usdtUsdOracle
    ) external {
        require(
            factory != address(0) && policy != address(0) && frxUsdUsdOracle != address(0)
                && usdeUsdOracle != address(0) && usdcUsdOracle != address(0)
                && usdtUsdOracle != address(0),
            "zero dependency"
        );
        deploymentFactory = factory;
        pegKeeperPolicy = policy;
        frxUsdOracle = frxUsdUsdOracle;
        usdeOracle = usdeUsdOracle;
        usdcOracle = usdcUsdOracle;
        usdtOracle = usdtUsdOracle;
    }

    function expectedKeeper(uint256 keeperNumber) public view returns (address) {
        require(deploymentFactory != address(0), "factory not set");
        require(keeperNumber > 0 && keeperNumber <= 4, "keeper number");
        return _computeCreateAddress(deploymentFactory, keeperNumber);
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        script = buildScript(CURVE_OWNERSHIP_AGENT, buildProposalActions());
    }

    function buildProposalActions() public view returns (Action[] memory actions) {
        _validateDependencies();
        _validateMonetaryPolicies();

        address frxUsdKeeper = expectedKeeper(1);
        address sUsdeKeeper = expectedKeeper(2);
        address usdcKeeper = expectedKeeper(3);
        address usdtKeeper = expectedKeeper(4);
        actions = new Action[](33);

        actions[0] = Action({
            target: pegKeeperPolicy,
            data: abi.encodeWithSelector(IPegKeeperPolicy.set_factory.selector, deploymentFactory)
        });
        actions[1] = _setDefaultsAction(FRXUSD_CAP);

        actions[2] = _deployAction(FRXUSD_CRVUSD_POOL, false, true, frxUsdOracle);
        actions[3] = _setTierAction(frxUsdKeeper, TIER_PRIMARY);
        actions[4] = _setBackingOraclePolicyAction(frxUsdKeeper, frxUsdOracle);
        actions[5] = _setKeeperPolicyAction(
            frxUsdKeeper, FRXUSD_CAP, ENTRY_MIN_PROFIT_PPM, NORMAL_EXIT_MIN_PROFIT_PPM
        );
        actions[6] = _setInterventionPolicyAction(frxUsdKeeper);
        actions[7] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[8] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, frxUsdKeeper);
        actions[9] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, frxUsdKeeper);

        actions[10] = _deployAction(SUSDE_CRVUSD_POOL, true, true, usdeOracle);
        actions[11] = _setTierAction(sUsdeKeeper, TIER_SECONDARY);
        actions[12] = _setBackingOraclePolicyAction(sUsdeKeeper, usdeOracle);
        actions[13] = _setKeeperPolicyAction(
            sUsdeKeeper, SUSDE_LOCAL_CAP, ENTRY_MIN_PROFIT_PPM, NORMAL_EXIT_MIN_PROFIT_PPM
        );
        actions[14] = _setInterventionPolicyAction(sUsdeKeeper);
        actions[15] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, sUsdeKeeper);
        actions[16] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, sUsdeKeeper);

        actions[17] = _deployAction(USDC_CRVUSD_POOL, false, false, usdcOracle);
        actions[18] = _setTierAction(usdcKeeper, TIER_TERTIARY);
        actions[19] = _setBackingOraclePolicyAction(usdcKeeper, usdcOracle);
        actions[20] = _setKeeperPolicyAction(
            usdcKeeper, USDC_CAP, LAST_RESORT_ENTRY_MIN_PROFIT_PPM, LAST_RESORT_EXIT_MIN_PROFIT_PPM
        );
        actions[21] = _setInterventionPolicyAction(usdcKeeper);
        actions[22] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[23] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdcKeeper);
        actions[24] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdcKeeper);

        actions[25] = _deployAction(USDT_CRVUSD_POOL, false, false, usdtOracle);
        actions[26] = _setTierAction(usdtKeeper, TIER_TERTIARY);
        actions[27] = _setBackingOraclePolicyAction(usdtKeeper, usdtOracle);
        actions[28] = _setKeeperPolicyAction(
            usdtKeeper, USDT_CAP, LAST_RESORT_ENTRY_MIN_PROFIT_PPM, LAST_RESORT_EXIT_MIN_PROFIT_PPM
        );
        actions[29] = _setInterventionPolicyAction(usdtKeeper);
        actions[30] = _debtCeilingAction(usdtKeeper, USDT_CAP);
        actions[31] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdtKeeper);
        actions[32] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdtKeeper);
    }

    function _validateDependencies() internal view {
        require(deploymentFactory != address(0), "factory not set");
        require(pegKeeperPolicy != address(0), "policy not set");

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deploymentFactory);
        require(factory.owner() == CURVE_OWNERSHIP_AGENT, "factory owner");
        require(factory.pendingOwner() == address(0), "factory pending owner");
        require(
            factory.controllerFactory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "controller factory"
        );
        require(factory.policy() == pegKeeperPolicy, "factory policy");
        require(factory.activePegKeeperCount() == 0, "factory not fresh");
        for (uint256 i = 1; i <= 4; ++i) {
            require(expectedKeeper(i).code.length == 0, "keeper address already used");
        }

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
        require(policy.owner() == CURVE_OWNERSHIP_AGENT, "policy owner");
        require(policy.pendingOwner() == address(0), "policy pending owner");
        require(policy.factory() == address(0), "policy already bound");
        require(policy.aggregateCrvUsdOracle() == CRVUSD_AGGREGATE_ORACLE, "aggregate oracle");
        require(policy.primaryUtilizationBps() == 8_000, "primary threshold");
        require(policy.primary() == address(0), "primary already set");
        require(policy.secondaryCount() == 0, "secondary already set");
        require(policy.tertiaryCount() == 0, "tertiary already set");
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

        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY, FRXUSD_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdeOracle, USDE_USD_PROXY, USDE_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdcOracle, USDC_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usdtOracle, USDT_USD_PROXY, STABLECOIN_CHAINLINK_MAX_DELAY);
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

    function _setDefaultsAction(uint256 cap) internal view returns (Action memory) {
        return Action({
            target: deploymentFactory,
            data: abi.encodeWithSelector(
                IPegKeeperV3Factory.setDefaults.selector, _deploymentDefaults(cap)
            )
        });
    }

    function _deployAction(
        address amm,
        bool pairedTokenIsErc4626,
        bool poolUsesDynamicArrays,
        address backingOracle
    ) internal view returns (Action memory) {
        return Action({
            target: deploymentFactory,
            data: abi.encodeWithSelector(
                IPegKeeperV3Factory.deployPegKeeper.selector,
                amm,
                pairedTokenIsErc4626,
                poolUsesDynamicArrays,
                backingOracle
            )
        });
    }

    function _setTierAction(address keeper, uint256 tier) internal view returns (Action memory) {
        return Action({
            target: pegKeeperPolicy,
            data: abi.encodeWithSelector(IPegKeeperPolicy.set_tier.selector, keeper, tier)
        });
    }

    function _setBackingOraclePolicyAction(address keeper, address oracle)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_backing_oracle_policy.selector, oracle, MIN_BACKING_ORACLE_PRICE
            )
        });
    }

    function _setKeeperPolicyAction(
        address keeper,
        uint256 cap,
        uint256 entryMinProfitPpm,
        uint256 exitMinProfitPpm
    ) internal pure returns (Action memory) {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_policy.selector,
                entryMinProfitPpm,
                exitMinProfitPpm,
                KEEPER_PROFIT_SHARE_BPS,
                MIN_EXPANSION_AMOUNT,
                cap
            )
        });
    }

    function _setInterventionPolicyAction(address keeper) internal pure returns (Action memory) {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_intervention_policy.selector,
                MAX_INTERVENTION_SHARE_BPS,
                MIN_INTERVENTION_DELAY
            )
        });
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

    function _deploymentDefaults(uint256 cap)
        internal
        pure
        returns (IPegKeeperV3Factory.DeploymentDefaults memory)
    {
        return IPegKeeperV3Factory.DeploymentDefaults({
            admin: CURVE_OWNERSHIP_AGENT,
            emergencyAdmin: CURVE_EMERGENCY_ADMIN,
            feeReceiver: FEE_SPLITTER,
            maxDeployedCrvUsd: cap,
            ammExecutionBufferBps: AMM_EXECUTION_BUFFER_BPS
        });
    }

    function _coreHash(address target, uint256 size) internal view returns (bytes32 result) {
        assembly {
            let pointer := mload(0x40)
            extcodecopy(target, pointer, 0, size)
            result := keccak256(pointer, size)
        }
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
    }
}
