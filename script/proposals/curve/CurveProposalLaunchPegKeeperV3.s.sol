// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCurveProposal} from "./BaseCurveProposal.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";
import {ICurveStablecoinOracle} from "../../../src/interfaces/ICurveStablecoinOracle.sol";
import {IFraxNetDeposit} from "../../../src/interfaces/IFraxNetDeposit.sol";
import {IFraxNetDepositFactory} from "../../../src/interfaces/IFraxNetDepositFactory.sol";

/// @title CurveProposalLaunchPegKeeperV3
/// @notice Deploy and register three initially paused PegKeeperV3 instances for frxUSD, USDC, and USDT.
/// @dev Mirrors `docs/pegkeeper-v3-suggested-launch-parameters.md`. The audited V3 implementation and
///      a fresh deployment factory owned by the Curve Ownership Agent must already be deployed.
///      frxUSD uses the selected canonical-proxy Chainlink adapter; USDC and USDT retain
///      opposite orientations of the external Curve EMA pool. This proposal configures no V2
///      PegKeepers and performs no activation actions.
contract CurveProposalLaunchPegKeeperV3 is BaseCurveProposal {
    string public constant DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-deployment.json";

    uint256 public constant IMPLEMENTATION_CORE_SIZE = 24_154;
    uint256 public constant IMPLEMENTATION_RUNTIME_SIZE = 24_186;
    bytes32 public constant EXPECTED_IMPLEMENTATION_CORE_HASH =
        0x5736c5cc1d0c99380a1a68e8aebdf17756906e5eb310dcb9387eed58fab53754;
    bytes32 public constant EXPECTED_PREVIEW_MODULE_RUNTIME_HASH =
        0xc20424f3497c62e9b297e777379dd16a820f6b0960a8defe7bc1b76de01b82ce;

    uint256 public constant ROUTE_CURVE_SWAP = 0;
    uint256 public constant ROUTE_FRXUSD_MINT = 4;
    uint256 public constant ROUTE_FRXUSD_REDEEM = 5;
    uint256 public constant CURVE_EXECUTION_BUFFER_BPS = 3;
    uint256 public constant FRXUSD_MINT_EXECUTION_BUFFER_BPS = 1;
    uint256 public constant FRAXNET_REDEMPTION_EXECUTION_BUFFER_BPS = 2;

    uint256 public constant ENTRY_MIN_PROFIT_PPM = 10;
    uint256 public constant NORMAL_EXIT_MIN_PROFIT_PPM = 1_000;
    uint256 public constant EARLY_EXIT_MIN_PROFIT_PPM = 5_000;
    uint256 public constant KEEPER_PROFIT_SHARE_BPS = 3_000;
    uint256 public constant MIN_DEPLOYMENT_TIME = 2 days;
    uint256 public constant MIN_EXPANSION_AMOUNT = 10_000e18;
    uint256 public constant MIN_ORACLE_PRICE = 999_700_000_000_000_000;
    uint256 public constant CHAINLINK_MAX_DELAY = 26 hours;

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
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address public constant USDC_USDT_ORACLE_POOL = 0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85;
    address public constant FRXUSD_USD_PROXY = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;

    address public constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address public constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address public constant USDT_CRVUSD_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address public constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address public constant FRXUSD_CUSTODIAN = 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;
    address public constant FRAXNET_DEPOSIT_FACTORY = 0xA3D62f83C433e2A56Af392E08a705A52DEd63696;
    uint32 public constant ETHEREUM_LAYERZERO_EID = 30_101;

    address public deploymentFactory;
    address public frxUsdOracle;
    address public frxUsdBackingOracle;
    address public usdcOracle;
    address public usdtOracle;
    address public usdcFraxNetDeposit;
    address public usdtFraxNetDeposit;

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
        frxUsdBackingOracle = frxUsdOracle;
        usdcOracle = vm.parseJsonAddress(json, ".usdcTargetOracle");
        usdtOracle = vm.parseJsonAddress(json, ".usdtTargetOracle");
        usdcFraxNetDeposit = vm.parseJsonAddress(json, ".usdcFraxNetDeposit");
        usdtFraxNetDeposit = vm.parseJsonAddress(json, ".usdtFraxNetDeposit");
    }

    function setDeploymentFactory(address factory) external {
        require(factory != address(0), "zero factory");
        deploymentFactory = factory;
    }

    function setOracleAdapters(address frxUsdUsdOracle_, address usdcOracle_, address usdtOracle_)
        external
    {
        require(
            frxUsdUsdOracle_ != address(0) && usdcOracle_ != address(0)
                && usdtOracle_ != address(0),
            "zero oracle"
        );
        frxUsdOracle = frxUsdUsdOracle_;
        frxUsdBackingOracle = frxUsdUsdOracle_;
        usdcOracle = usdcOracle_;
        usdtOracle = usdtOracle_;
    }

    function setFraxNetDeposits(address usdcAccount, address usdtAccount) external {
        require(usdcAccount != address(0) && usdtAccount != address(0), "zero FraxNet account");
        usdcFraxNetDeposit = usdcAccount;
        usdtFraxNetDeposit = usdtAccount;
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
        _validateFraxNetAccount(usdcFraxNetDeposit, usdcKeeper);
        _validateFraxNetAccount(usdtFraxNetDeposit, usdtKeeper);
        actions = new Action[](17);

        actions[0] = _setDefaultsAction(FRXUSD_CAP);
        actions[1] = _deployAction(
            FRXUSD_CRVUSD_POOL,
            FRXUSD,
            false,
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
            FRXUSD,
            false,
            usdcOracle,
            frxUsdBackingOracle,
            _frxUsdExpansion(USDC, 1),
            _frxUsdContraction(USDC, 1, usdcFraxNetDeposit)
        );
        actions[7] = _setPolicyAction(usdcKeeper, USDC_CAP);
        actions[8] = _debtCeilingAction(usdcKeeper, USDC_CAP);
        actions[9] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, usdcKeeper);
        actions[10] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, usdcKeeper);

        actions[11] = _setDefaultsAction(USDT_CAP);
        actions[12] = _deployAction(
            USDT_CRVUSD_POOL,
            FRXUSD,
            false,
            usdtOracle,
            frxUsdBackingOracle,
            _frxUsdExpansion(USDT, 2),
            _frxUsdContraction(USDT, 2, usdtFraxNetDeposit)
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
        require(frxUsdOracle == frxUsdBackingOracle, "frxUSD oracle mismatch");
        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY);
        _validateCurveOracle(usdcOracle, USDC_USDT_ORACLE_POOL, USDC, USDT, true);
        _validateCurveOracle(usdtOracle, USDC_USDT_ORACLE_POOL, USDT, USDC, false);
    }

    function _validateCurveOracle(
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

    function _validateChainlinkOracle(address adapter, address expectedFeed) internal view {
        require(adapter.code.length > 0, "oracle code");
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(oracle.feed() == expectedFeed, "oracle feed");
        require(oracle.feed_decimals() == 8, "oracle decimals");
        require(oracle.max_delay() == CHAINLINK_MAX_DELAY, "oracle delay");
        require(oracle.price() >= MIN_ORACLE_PRICE, "oracle price");
    }

    function _validateMonetaryPolicies() internal view {
        _validateMonetaryPolicy(CRVUSD_MONETARY_POLICY);
        _validateMonetaryPolicy(CRVUSD_LEGACY_MONETARY_POLICY);
    }

    function _validateFraxNetAccount(address account, address keeper) internal view {
        require(account.code.length > 0, "FraxNet account code");
        IFraxNetDepositFactory factory = IFraxNetDepositFactory(FRAXNET_DEPOSIT_FACTORY);
        require(!factory.isPaused(), "FraxNet factory paused");
        require(factory.isFraxNetDeposit(account), "unknown FraxNet account");
        require(factory.frxUSDCustodian() == FRXUSD_CUSTODIAN, "FraxNet custodian");
        require(factory.rwaRedeemer() != address(0), "FraxNet RWA route");
        IFraxNetDeposit deposit = IFraxNetDeposit(account);
        require(deposit.asset() == FRXUSD, "FraxNet asset");
        require(deposit.frxUSD() == FRXUSD, "FraxNet frxUSD");
        require(deposit.USDC() == USDC, "FraxNet USDC");
        require(deposit.factory() == FRAXNET_DEPOSIT_FACTORY, "FraxNet factory");
        require(deposit.targetEid() == ETHEREUM_LAYERZERO_EID, "FraxNet EID");
        require(deposit.targetAddress() == bytes32(uint256(uint160(keeper))), "FraxNet recipient");
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
        bool yieldTokenIsErc4626,
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
                yieldTokenIsErc4626,
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
            targetAmmExecutionBufferBps: CURVE_EXECUTION_BUFFER_BPS,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 5
        });
    }

    function _frxUsdExpansion() internal pure returns (IPegKeeperV3.RouteStep[] memory route) {
        return new IPegKeeperV3.RouteStep[](0);
    }

    function _frxUsdContraction() internal pure returns (IPegKeeperV3.RouteStep[] memory route) {
        route = new IPegKeeperV3.RouteStep[](1);
        route[0] = _curve(FRXUSD_CRVUSD_POOL, FRXUSD, CRVUSD, 0, 1);
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

    function _frxUsdContraction(address targetAsset, int128 targetIndex, address fraxNetAccount)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory route)
    {
        bool isUsdt = targetAsset == USDT;
        route = new IPegKeeperV3.RouteStep[](isUsdt ? 3 : 2);
        route[0] = _frxUsdRedeem(fraxNetAccount);
        uint256 targetAmmIndex = 1;
        if (isUsdt) {
            route[1] = _curve(THREE_POOL, USDC, USDT, 1, targetIndex);
            targetAmmIndex = 2;
        }
        route[targetAmmIndex] =
            _curve(isUsdt ? USDT_CRVUSD_POOL : USDC_CRVUSD_POOL, targetAsset, CRVUSD, 0, 1);
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

    function _frxUsdRedeem(address fraxNetAccount)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: ROUTE_FRXUSD_REDEEM,
            venue: fraxNetAccount,
            tokenIn: FRXUSD,
            tokenOut: USDC,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: FRAXNET_REDEMPTION_EXECUTION_BUFFER_BPS
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
