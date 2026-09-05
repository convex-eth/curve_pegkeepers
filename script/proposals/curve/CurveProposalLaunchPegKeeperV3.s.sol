// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Deploy and register three initially paused PegKeeperV3 instances for frxUSD, USDC, and USDT.
/// @dev Mirrors `docs/pegkeeper-v3-suggested-launch-parameters.md`. The audited V3 implementation and
///      a fresh deployment factory owned by the Curve Ownership Agent must already be deployed.
///      All three keepers use the selected canonical-proxy Chainlink adapter for retained frxUSD
///      backing. Transient USDC/USDT route assets are protected by atomic settlement and route-loss
///      bounds rather than target-token oracle gates. No V2 keeper or activation action is included.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant IMPLEMENTATION_CORE_SIZE = 22_061;
    uint256 public constant IMPLEMENTATION_RUNTIME_SIZE = 22_093;
    bytes32 public constant EXPECTED_IMPLEMENTATION_CORE_HASH =
        0xaa16d47a35d38a859fb474ef0cab2035ef68cc1675ed2bd70e84fda30ba70a0c;
    bytes32 public constant EXPECTED_PREVIEW_MODULE_RUNTIME_HASH =
        0x674fbb58d7dfc925fdbaa37ab81800f8f8859ab10f3988cd301940f8edb29868;
    uint256 public constant FACTORY_CORE_SIZE = 3_780;
    uint256 public constant FACTORY_RUNTIME_SIZE = 3_844;
    bytes32 public constant EXPECTED_FACTORY_CORE_HASH =
        0x1f882cc187980d543448ec94a136200097092aee18b8903962fcb44d03448c8c;
    uint256 public constant CHAINLINK_ORACLE_CORE_SIZE = 460;
    uint256 public constant CHAINLINK_ORACLE_RUNTIME_SIZE = 556;
    bytes32 public constant EXPECTED_CHAINLINK_ORACLE_CORE_HASH =
        0xe03c54b8bf499010cf16ccbd53437316c3fe05e6cc35ef26b042fa36efcc64b3;

    uint256 public constant ROUTE_CURVE_SWAP = 0;
    uint256 public constant ROUTE_FRXUSD_MINT = 4;
    uint256 public constant CURVE_EXECUTION_BUFFER_BPS = 3;
    uint256 public constant FRXUSD_MINT_EXECUTION_BUFFER_BPS = 1;

    uint256 public constant ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant NORMAL_EXIT_MIN_PROFIT_PPM = 500;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant MIN_EXPANSION_AMOUNT = 10_000e18;
    uint256 public constant MAX_INTERVENTION_SHARE_BPS = 3_333;
    uint256 public constant MIN_INTERVENTION_DELAY = 12 seconds;
    uint256 public constant MIN_YIELD_ORACLE_PRICE = 999_000_000_000_000_000;
    uint256 public constant CHAINLINK_MAX_DELAY = 26 hours;

    uint256 public constant FRXUSD_CAP = 20_000_000e18;
    uint256 public constant USDC_CAP = 20_000_000e18;
    uint256 public constant USDT_CAP = 20_000_000e18;

    address public constant CURVE_EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant CRVUSD_AGGREGATE_ORACLE = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address public constant CRVUSD_MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address public constant CRVUSD_LEGACY_MONETARY_POLICY =
        0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;

    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant FRXUSD_CUSTODIAN = 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;

    address public deploymentFactory;
    address public frxUsdOracle;

    function run() external returns (uint256 proposalId) {
        loadDeployment(DEPLOYMENT_INPUT_PATH);
        vm.startBroadcast();
        bytes memory script = buildProposalScript();
        proposalId = proposeOwnershipVote(
            script,
            "Deploy and register three paused PegKeeperV3 keepers for frxUSD, USDC, and USDT"
        );
        vm.stopBroadcast();
    }

    function loadDeployment(string memory path) public {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment chain");
        deploymentFactory = vm.parseJsonAddress(json, ".factory");
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle");
    }

    function setDeploymentFactory(address factory) external {
        require(factory != address(0), "zero factory");
        deploymentFactory = factory;
    }

    function setOracleAdapter(address frxUsdUsdOracle_) external {
        require(frxUsdUsdOracle_ != address(0), "zero oracle");
        frxUsdOracle = frxUsdUsdOracle_;
    }

    function expectedKeeper(uint256 keeperNumber) public view returns (address) {
        require(deploymentFactory != address(0), "factory not set");
        require(keeperNumber > 0 && keeperNumber <= 3, "keeper number");
        return _computeCreateAddress(deploymentFactory, keeperNumber);
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        script = buildScript(CURVE_OWNERSHIP_AGENT, buildProposalActions());
    }

    function buildProposalActions() public view returns (Action[] memory actions) {
        _validateFactory();
        _validateOracles();
        _validateMonetaryPolicies();

        address frxUsdKeeper = expectedKeeper(1);
        address usdcKeeper = expectedKeeper(2);
        address usdtKeeper = expectedKeeper(3);
        actions = new Action[](22);

        actions[0] = _setDefaultsAction(FRXUSD_CAP);
        actions[1] = _deployAction(
            FRXUSD_CRVUSD_POOL, FRXUSD, FRXUSD_CRVUSD_POOL, false, frxUsdOracle, _frxUsdExpansion()
        );
        actions[2] = _setYieldOraclePolicyAction(frxUsdKeeper);
        actions[3] = _setPolicyAction(frxUsdKeeper, FRXUSD_CAP);
        actions[4] = _setInterventionPolicyAction(frxUsdKeeper);
        actions[5] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[6] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, frxUsdKeeper);
        actions[7] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, frxUsdKeeper);

        actions[8] = _deployAction(
            USDC_CRVUSD_POOL,
            FRXUSD,
            FRXUSD_CRVUSD_POOL,
            false,
            frxUsdOracle,
            _frxUsdExpansion(USDC, 1)
        );
        actions[9] = _setYieldOraclePolicyAction(usdcKeeper);
        actions[10] = _setPolicyAction(usdcKeeper, USDC_CAP);
        actions[11] = _setInterventionPolicyAction(usdcKeeper);
        actions[12] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[13] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdcKeeper);
        actions[14] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdcKeeper);

        actions[15] = _deployAction(
            USDT_CRVUSD_POOL,
            FRXUSD,
            FRXUSD_CRVUSD_POOL,
            false,
            frxUsdOracle,
            _frxUsdExpansion(USDT, 2)
        );
        actions[16] = _setYieldOraclePolicyAction(usdtKeeper);
        actions[17] = _setPolicyAction(usdtKeeper, USDT_CAP);
        actions[18] = _setInterventionPolicyAction(usdtKeeper);
        actions[19] = _debtCeilingAction(usdtKeeper, USDT_CAP);
        actions[20] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdtKeeper);
        actions[21] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdtKeeper);
    }

    function _validateFactory() internal view {
        require(deploymentFactory != address(0), "factory not set");
        address factoryAddress = deploymentFactory;
        require(factoryAddress.code.length == FACTORY_RUNTIME_SIZE, "factory size");
        bytes32 factoryCoreHash;
        assembly {
            let pointer := mload(0x40)
            extcodecopy(factoryAddress, pointer, 0, FACTORY_CORE_SIZE)
            factoryCoreHash := keccak256(pointer, FACTORY_CORE_SIZE)
        }
        require(factoryCoreHash == EXPECTED_FACTORY_CORE_HASH, "factory hash");

        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deploymentFactory);
        require(factory.owner() == CURVE_OWNERSHIP_AGENT, "factory owner");
        require(factory.pendingOwner() == address(0), "factory pending owner");
        require(
            factory.controllerFactory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "controller factory"
        );
        require(factory.aggregateCrvUsdOracle() == CRVUSD_AGGREGATE_ORACLE, "aggregate oracle");
        require(factory.keeperCount() == 0, "factory not fresh");

        address implementation = factory.implementation();
        require(implementation.code.length == IMPLEMENTATION_RUNTIME_SIZE, "implementation size");
        bytes32 coreHash;
        assembly {
            let pointer := mload(0x40)
            extcodecopy(implementation, pointer, 0, IMPLEMENTATION_CORE_SIZE)
            coreHash := keccak256(pointer, IMPLEMENTATION_CORE_SIZE)
        }
        require(coreHash == EXPECTED_IMPLEMENTATION_CORE_HASH, "implementation hash");
        require(IPegKeeperV3(implementation).initialized(), "implementation unlocked");
        address previewModule = IPegKeeperV3(implementation).preview_module();
        require(previewModule.codehash == EXPECTED_PREVIEW_MODULE_RUNTIME_HASH, "preview hash");
    }

    function _validateOracles() internal view {
        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY);
    }

    function _validateChainlinkOracle(address adapter, address expectedFeed) internal view {
        require(adapter.code.length == CHAINLINK_ORACLE_RUNTIME_SIZE, "chainlink oracle size");
        bytes32 coreHash;
        assembly {
            let pointer := mload(0x40)
            extcodecopy(adapter, pointer, 0, CHAINLINK_ORACLE_CORE_SIZE)
            coreHash := keccak256(pointer, CHAINLINK_ORACLE_CORE_SIZE)
        }
        require(coreHash == EXPECTED_CHAINLINK_ORACLE_CORE_HASH, "chainlink oracle hash");
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(oracle.feed() == expectedFeed, "oracle feed");
        require(oracle.feed_decimals() == 8, "oracle decimals");
        require(oracle.max_delay() == CHAINLINK_MAX_DELAY, "oracle delay");
        require(oracle.price() >= MIN_YIELD_ORACLE_PRICE, "oracle price");
    }

    function _validateMonetaryPolicies() internal view {
        _validateMonetaryPolicy(CRVUSD_MONETARY_POLICY);
        _validateMonetaryPolicy(CRVUSD_LEGACY_MONETARY_POLICY);
    }

    function _validateMonetaryPolicy(address policy) internal view {
        IAggMonetaryPolicy monetaryPolicy = IAggMonetaryPolicy(policy);
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
        address targetAmm,
        address yieldToken,
        address yieldAmm,
        bool yieldTokenIsErc4626,
        address yieldOracle,
        IPegKeeperV3.RouteStep[] memory expansion
    ) internal view returns (Action memory) {
        return Action({
            target: deploymentFactory,
            data: abi.encodeWithSelector(
                IPegKeeperV3Factory.deployPegKeeper.selector,
                targetAmm,
                yieldToken,
                yieldAmm,
                yieldTokenIsErc4626,
                yieldOracle,
                expansion
            )
        });
    }

    function _setYieldOraclePolicyAction(address keeper) internal view returns (Action memory) {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_yield_oracle_policy.selector, frxUsdOracle, MIN_YIELD_ORACLE_PRICE
            )
        });
    }

    function _setPolicyAction(address keeper, uint256 cap) internal pure returns (Action memory) {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_policy.selector,
                ENTRY_MIN_PROFIT_PPM,
                NORMAL_EXIT_MIN_PROFIT_PPM,
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

    function _monetaryPolicyAction(address policy, address keeper)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            target: policy,
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
            targetAmmExecutionBufferBps: CURVE_EXECUTION_BUFFER_BPS,
            yieldAmmExecutionBufferBps: CURVE_EXECUTION_BUFFER_BPS,
            expansionMaxRouteLossBps: 5
        });
    }

    function _frxUsdExpansion() internal pure returns (IPegKeeperV3.RouteStep[] memory route) {
        return new IPegKeeperV3.RouteStep[](0);
    }

    function _frxUsdExpansion(address targetAsset, int128 targetIndex)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory route)
    {
        bool isUsdt = targetAsset == USDT;
        route = new IPegKeeperV3.RouteStep[](isUsdt ? 2 : 1);
        uint256 mintIndex;
        if (isUsdt) {
            route[0] = _curve(THREE_POOL, USDT, USDC, targetIndex, 1);
            mintIndex = 1;
        }
        route[mintIndex] = _frxUsd(ROUTE_FRXUSD_MINT, USDC, FRXUSD);
    }

    function _curve(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: ROUTE_CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: poolIndexIn,
            poolIndexOut: poolIndexOut,
            executionBufferBps: CURVE_EXECUTION_BUFFER_BPS
        });
    }

    function _frxUsd(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: FRXUSD_CUSTODIAN,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: FRXUSD_MINT_EXECUTION_BUFFER_BPS
        });
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
    }
}
