// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
import {ICurveStablecoinOracle} from "../../../src/interfaces/ICurveStablecoinOracle.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Deploy and register three initially paused PegKeeperV3 instances for frxUSD, USDC, and USDT.
/// @dev Mirrors `docs/pegkeeper-v3-suggested-launch-parameters.md`. The audited V3 implementation and
///      a fresh deployment factory owned by the Curve Ownership Agent must already be deployed.
///      This proposal configures no V2 PegKeepers and performs no activation actions.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant IMPLEMENTATION_CORE_SIZE = 21_298;
    uint256 public constant IMPLEMENTATION_RUNTIME_SIZE = 21_330;
    bytes32 public constant EXPECTED_IMPLEMENTATION_CORE_HASH =
        0x7fb0edd85971d51b9e069dd4c3d08c538c7b0197da7ebb7f0771cd98d1b45828;
    bytes32 public constant EXPECTED_PREVIEW_MODULE_RUNTIME_HASH =
        0x4522452266ef8341fd822456f78b2d8978fe2c89c730090ae7932fe822572324;

    uint256 public constant ROUTE_CURVE_SWAP = 0;
    uint256 public constant ROUTE_DAI_USDS_CONVERTER = 1;
    uint256 public constant ROUTE_ERC4626_DEPOSIT = 2;
    uint256 public constant ROUTE_ERC4626_REDEEM = 3;

    uint256 public constant ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant NORMAL_EXIT_MIN_PROFIT_PPM = 1_000;
    uint256 public constant EARLY_EXIT_MIN_PROFIT_PPM = 5_000;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant MIN_DEPLOYMENT_TIME = 2 days;
    uint256 public constant MIN_EXPANSION_AMOUNT = 10_000e18;
    uint256 public constant MIN_ORACLE_PRICE = 999_700_000_000_000_000;

    uint256 public constant FRXUSD_CAP = 2_500_000e18;
    uint256 public constant USDC_CAP = 2_500_000e18;
    uint256 public constant USDT_CAP = 5_000_000e18;

    address public constant CURVE_EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address public constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address public constant CRVUSD_MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address public constant CRVUSD_LEGACY_MONETARY_POLICY =
        0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;

    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    address public constant USDC_USDT_ORACLE_POOL = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant FRXUSD_SUSDS_ORACLE_POOL = 0x81A2612F6dEA269a6Dd1F6DeAb45C5424EE2c4b7;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant FRXUSD_SFRXUSD_POOL = 0xF292eB6c5dcb693Eaaf392D0562a01C3710E5978;
    address public constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant DAI_USDS_CONVERTER = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    address public deploymentFactory;
    address public frxUsdOracle;
    address public frxUsdBackingOracle;
    address public usdcOracle;
    address public usdtOracle;
    address public susdsBackingOracle;

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
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdTargetOracle");
        frxUsdBackingOracle = vm.parseJsonAddress(json, ".sfrxUsdBackingOracle");
        usdcOracle = vm.parseJsonAddress(json, ".usdcTargetOracle");
        usdtOracle = vm.parseJsonAddress(json, ".usdtTargetOracle");
        susdsBackingOracle = vm.parseJsonAddress(json, ".susdsBackingOracle");
    }

    function setDeploymentFactory(address factory) external {
        require(factory != address(0), "zero factory");
        deploymentFactory = factory;
    }

    function setOracleAdapters(
        address frxUsdOracle_,
        address frxUsdBackingOracle_,
        address usdcOracle_,
        address usdtOracle_,
        address susdsBackingOracle_
    ) external {
        require(
            frxUsdOracle_ != address(0) && frxUsdBackingOracle_ != address(0)
                && usdcOracle_ != address(0) && usdtOracle_ != address(0)
                && susdsBackingOracle_ != address(0),
            "zero oracle"
        );
        frxUsdOracle = frxUsdOracle_;
        frxUsdBackingOracle = frxUsdBackingOracle_;
        usdcOracle = usdcOracle_;
        usdtOracle = usdtOracle_;
        susdsBackingOracle = susdsBackingOracle_;
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
        actions = new Action[](17);

        actions[0] = _setDefaultsAction(FRXUSD_CAP);
        actions[1] = _deployAction(
            FRXUSD_CRVUSD_POOL,
            SFRXUSD,
            frxUsdOracle,
            frxUsdBackingOracle,
            _frxUsdExpansion(),
            _frxUsdContraction()
        );
        actions[2] = _setPolicyAction(frxUsdKeeper, FRXUSD_CAP);
        actions[3] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[4] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, frxUsdKeeper);
        actions[5] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, frxUsdKeeper);

        actions[6] = _deployAction(
            USDC_CRVUSD_POOL,
            SUSDS,
            usdcOracle,
            susdsBackingOracle,
            _susdsExpansion(USDC, 1),
            _susdsContraction(USDC, 1)
        );
        actions[7] = _setPolicyAction(usdcKeeper, USDC_CAP);
        actions[8] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[9] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdcKeeper);
        actions[10] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdcKeeper);

        actions[11] = _setDefaultsAction(USDT_CAP);
        actions[12] = _deployAction(
            USDT_CRVUSD_POOL,
            SUSDS,
            usdtOracle,
            susdsBackingOracle,
            _susdsExpansion(USDT, 2),
            _susdsContraction(USDT, 2)
        );
        actions[13] = _setPolicyAction(usdtKeeper, USDT_CAP);
        actions[14] = _debtCeilingAction(usdtKeeper, USDT_CAP);
        actions[15] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdtKeeper);
        actions[16] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdtKeeper);
    }

    function _validateFactory() internal view {
        require(deploymentFactory != address(0), "factory not set");
        IPegKeeperV3Factory factory = IPegKeeperV3Factory(deploymentFactory);
        require(factory.owner() == CURVE_OWNERSHIP_AGENT, "factory owner");
        require(
            factory.controllerFactory() == CURVE_CRVUSD_CONTROLLER_FACTORY, "controller factory"
        );
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
        _validateOracle(frxUsdOracle, FRXUSD_SUSDS_ORACLE_POOL, FRXUSD, SUSDS, true);
        _validateOracle(frxUsdBackingOracle, FRXUSD_SFRXUSD_POOL, SFRXUSD, FRXUSD, true);
        _validateOracle(usdcOracle, USDC_USDT_ORACLE_POOL, USDC, USDT, true);
        _validateOracle(usdtOracle, USDC_USDT_ORACLE_POOL, USDT, USDC, false);
        _validateOracle(susdsBackingOracle, FRXUSD_SUSDS_ORACLE_POOL, SUSDS, FRXUSD, false);
    }

    function _validateOracle(
        address adapter,
        address expectedPool,
        address expectedAsset,
        address expectedReference,
        bool expectedInverted
    ) internal view {
        require(adapter.code.length > 0, "oracle code");
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(adapter);
        require(oracle.pool() == expectedPool, "oracle pool");
        require(oracle.asset() == expectedAsset, "oracle asset");
        require(oracle.reference_asset() == expectedReference, "oracle reference");
        require(oracle.inverted() == expectedInverted, "oracle orientation");
        require(oracle.price() >= MIN_ORACLE_PRICE, "oracle price");
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
        address targetOracle,
        address yieldOracle,
        IPegKeeperV3.RouteStep[] memory expansion,
        IPegKeeperV3.RouteStep[] memory contraction
    ) internal view returns (Action memory) {
        return Action({
            target: deploymentFactory,
            data: abi.encodeWithSelector(
                IPegKeeperV3Factory.deployPegKeeper.selector,
                targetAmm,
                yieldToken,
                targetOracle,
                yieldOracle,
                expansion,
                contraction
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
                EARLY_EXIT_MIN_PROFIT_PPM,
                KEEPER_PROFIT_SHARE_BPS,
                MIN_DEPLOYMENT_TIME,
                MIN_EXPANSION_AMOUNT,
                cap
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
            targetAmmExecutionBufferBps: 5,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100
        });
    }

    function _frxUsdExpansion() internal pure returns (IPegKeeperV3.RouteStep[] memory route) {
        route = new IPegKeeperV3.RouteStep[](1);
        route[0] = _curve(FRXUSD_SFRXUSD_POOL, FRXUSD, SFRXUSD, 1, 0);
    }

    function _frxUsdContraction() internal pure returns (IPegKeeperV3.RouteStep[] memory route) {
        route = new IPegKeeperV3.RouteStep[](2);
        route[0] = _curve(FRXUSD_SFRXUSD_POOL, SFRXUSD, FRXUSD, 0, 1);
        route[1] = _curve(FRXUSD_CRVUSD_POOL, FRXUSD, CRVUSD, 0, 1);
    }

    function _susdsExpansion(address targetAsset, int128 targetIndex)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory route)
    {
        route = new IPegKeeperV3.RouteStep[](3);
        route[0] = _curve(THREE_POOL, targetAsset, DAI, targetIndex, 0);
        route[1] = _converter(DAI, USDS);
        route[2] = _vault(ROUTE_ERC4626_DEPOSIT, USDS, SUSDS);
    }

    function _susdsContraction(address targetAsset, int128 targetIndex)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory route)
    {
        route = new IPegKeeperV3.RouteStep[](4);
        route[0] = _vault(ROUTE_ERC4626_REDEEM, SUSDS, USDS);
        route[1] = _converter(USDS, DAI);
        route[2] = _curve(THREE_POOL, DAI, targetAsset, 0, targetIndex);
        route[3] = _curve(
            targetAsset == USDC ? USDC_CRVUSD_POOL : USDT_CRVUSD_POOL, targetAsset, CRVUSD, 0, 1
        );
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
            executionBufferBps: 5
        });
    }

    function _converter(address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: ROUTE_DAI_USDS_CONVERTER,
            venue: DAI_USDS_CONVERTER,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _vault(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: SUSDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // The bound above makes the uint8 cast exact for this single-byte RLP nonce encoding.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
    }
}
