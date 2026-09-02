// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {DeployPegKeeperV3} from "./DeployPegKeeperV3.s.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IFrxUsdRedeemer {
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
}

contract SuperstateTokenHarness {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function seed(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function offchainRedeem(uint256 amount) external {
        uint256 balance = balanceOf[msg.sender];
        require(balance >= amount, "balance");
        balanceOf[msg.sender] = balance - amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 balance = balanceOf[from];
        require(balance >= amount, "balance");
        balanceOf[from] = balance - amount;
        balanceOf[to] += amount;
    }
}

/// @notice Pinned-block mainnet simulation. This script never broadcasts.
contract PegKeeperV3ReleaseCanary is Script, StdCheats {
    uint256 internal constant PINNED_MAINNET_BLOCK = 25_868_730;
    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant FRXUSD_CUSTODIAN = 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;
    address internal constant FRAXNET_DEPOSIT_FACTORY = 0xA3D62f83C433e2A56Af392E08a705A52DEd63696;
    address internal constant RWA_CUSTODIAN = 0x5fbAa3A3B489199338fbD85F7E3D444dc0504F33;
    address internal constant SUPERSTATE_TOKEN = 0x43415eB6ff9DB7E26A15b704e7A3eDCe97d31C4e;
    address internal constant RWA_USDC_REDEEMER = 0x4c21B7577C8FE8b0B0669165ee7C8f67fa1454Cf;
    address internal constant FRAXNET_ACCOUNT_TEMPLATE = 0xBf0D3Bb1266795a7752fd4c265041046A4E1156C;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address internal constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address internal constant CANARY_ADMIN = address(0xC0FFEE01);
    address internal constant CANARY_TRADER = address(0xC0FFEE02);
    address internal constant CANARY_KEEPER = address(0xC0FFEE03);
    address internal constant CANARY_FACTORY_OWNER = address(0xC0FFEE04);
    address internal constant CANARY_FRAXNET_ACCOUNT = address(0xC0FFEE05);
    address internal constant CANARY_CUSTODIAN_DRAINER = address(0xC0FFEE06);
    bytes32 internal constant EIP1967_BEACON_SLOT =
        0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant FRXUSD_MINT = 4;
    uint256 internal constant FRXUSD_REDEEM = 5;
    uint256 internal constant CURVE_EXECUTION_BUFFER_BPS = 3;
    uint256 internal constant FRXUSD_MINT_EXECUTION_BUFFER_BPS = 1;
    uint256 internal constant FRAXNET_REDEMPTION_EXECUTION_BUFFER_BPS = 2;
    uint256 internal constant ALLOCATION = 2_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;
    uint256 internal constant CONTRACTION_MARKET_TRADE = 30_000_000e18;

    function run() external {
        require(block.chainid == 1, "mainnet fork required");
        require(block.number == PINNED_MAINNET_BLOCK, "pinned mainnet block required");

        (IPegKeeperV3 pegKeeper, address fraxNetDeposit) = _deployCanary();
        IPegKeeperV3.RouteStep[] memory expansionPath = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contractionPath = _contractionPath(fraxNetDeposit);

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(CANARY_ADMIN);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(4, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(0, false);
        // Exercise the normal contraction branch in the same pinned transaction timeline.
        pegKeeper.set_policy(
            pegKeeper.entry_min_profit_ppm(),
            pegKeeper.normal_exit_min_profit_ppm(),
            pegKeeper.early_exit_min_profit_ppm(),
            pegKeeper.keeper_profit_share_bps(),
            0,
            pegKeeper.min_expansion_amount(),
            pegKeeper.max_deployed_crvusd()
        );
        vm.stopPrank();

        deal(USDT, CANARY_TRADER, 10_000_000e6);
        vm.startPrank(CANARY_TRADER);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);
        vm.stopPrank();

        (,,,, uint256 expectedYieldToken, bool expectedToDeploy) =
            pegKeeper.previewExpansion(EXPANSION_AMOUNT);
        require(expectedToDeploy, "current route preview selected fallback");
        require(expectedYieldToken > 0, "current route preview returned zero frxUSD");

        (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,,
            bool deployedToYield
        ) = _expandAsKeeper(pegKeeper);
        require(crvUsdSold == EXPANSION_AMOUNT, "unexpected crvUSD spend");
        require(backingRetained == 0, "unexpected fallback backing");
        require(deployedToYield, "live expansion selected fallback");
        require(yieldTokenReceived > 0, "live expansion returned zero frxUSD");
        require(
            pegKeeper.trusted_backing_value() >= pegKeeper.deployed_crvusd(), "principal invariant"
        );
        require(
            IERC20Allowance(CRVUSD).allowance(address(pegKeeper), USDT_POOL) == 0,
            "target allowance"
        );
        require(
            IERC20Allowance(USDT).allowance(address(pegKeeper), THREE_POOL) == 0, "USDT allowance"
        );
        require(
            IERC20Allowance(USDC).allowance(address(pegKeeper), FRXUSD_CUSTODIAN) == 0,
            "USDC allowance"
        );
        require(
            IERC20(FRXUSD).balanceOf(address(pegKeeper)) == yieldTokenReceived, "frxUSD accounting"
        );

        _drainDirectCustodian();
        _installSuperstateTokenHarness();

        deal(CRVUSD, CANARY_TRADER, CONTRACTION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        IERC20(CRVUSD).approve(USDT_POOL, CONTRACTION_MARKET_TRADE);
        IStableSwap2Pool(USDT_POOL).exchange(1, 0, CONTRACTION_MARKET_TRADE, 0);
        vm.stopPrank();

        uint256 contractionQuoteAmount = yieldTokenReceived / 10;
        (uint256 expectedCrvUsd,,,) = pegKeeper.previewKeeperBuyback(contractionQuoteAmount);
        require(expectedCrvUsd > 0, "current contraction route returned zero crvUSD");

        uint256 rwaUsdcBefore = IERC20(USDC).balanceOf(RWA_USDC_REDEEMER);
        uint256 crvUsdReceived =
            _contractAsKeeper(pegKeeper, fraxNetDeposit, contractionQuoteAmount);
        require(
            IERC20(USDC).balanceOf(RWA_USDC_REDEEMER) < rwaUsdcBefore, "RWA redemption route unused"
        );

        console2.log("mainnet block", block.number);
        console2.log("simulated PegKeeperV3", address(pegKeeper));
        console2.log("crvUSD sold", crvUsdSold);
        console2.log("frxUSD received", yieldTokenReceived);
        console2.log("contraction quote frxUSD", contractionQuoteAmount);
        console2.log("contraction quote crvUSD", expectedCrvUsd);
        console2.log("contraction received crvUSD", crvUsdReceived);
        console2.log("FraxNet redemption account", fraxNetDeposit);
        console2.log("expansion path hash");
        console2.logBytes32(keccak256(abi.encode(expansionPath)));
        console2.log("contraction path hash");
        console2.logBytes32(keccak256(abi.encode(contractionPath)));
    }

    function _deployCanary() internal returns (IPegKeeperV3 pegKeeper, address fraxNetDeposit) {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();
        config.owner = CANARY_FACTORY_OWNER;
        config.controllerFactory = FACTORY;
        config.admin = CANARY_ADMIN;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = ALLOCATION;
        config.targetAmmExecutionBufferBps = CURVE_EXECUTION_BUFFER_BPS;
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);

        IPegKeeperV3Factory deploymentFactory = IPegKeeperV3Factory(deployment.factory);
        address expectedKeeper = _computeCreateAddress(deployment.factory, 1);
        fraxNetDeposit = _cloneFraxNetAccount(expectedKeeper);
        // The clone cannot be present in the live factory's deployment registry; mock only that
        // membership read so V3's onchain route validation is exercised before live routing.
        vm.mockCall(
            FRAXNET_DEPOSIT_FACTORY,
            abi.encodeWithSignature("isFraxNetDeposit(address)", fraxNetDeposit),
            abi.encode(true)
        );
        IPegKeeperV3.RouteStep[] memory expansionPath = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contractionPath = _contractionPath(fraxNetDeposit);
        vm.prank(CANARY_FACTORY_OWNER);
        pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(
                USDT_POOL,
                FRXUSD,
                false,
                deployment.usdtTargetOracle,
                deployment.frxUsdUsdOracle,
                expansionPath,
                contractionPath
            )
        );
        require(address(pegKeeper) == expectedKeeper, "unexpected canary keeper");
    }

    function _cloneFraxNetAccount(address recipient) internal returns (address account) {
        // The live factory's address-prediction code uses a post-Shanghai opcode. Clone a real
        // factory account's beacon proxy and initialization slots so this Shanghai canary still
        // executes the live FraxNet V4 implementation and its factory-configured route.
        account = CANARY_FRAXNET_ACCOUNT;
        vm.etch(account, FRAXNET_ACCOUNT_TEMPLATE.code);
        vm.store(
            account, EIP1967_BEACON_SLOT, vm.load(FRAXNET_ACCOUNT_TEMPLATE, EIP1967_BEACON_SLOT)
        );
        vm.store(
            account, bytes32(uint256(0)), vm.load(FRAXNET_ACCOUNT_TEMPLATE, bytes32(uint256(0)))
        );
        vm.store(account, bytes32(uint256(1)), bytes32(uint256(uint160(recipient))));
    }

    function _expandAsKeeper(IPegKeeperV3 pegKeeper)
        internal
        returns (uint256, uint256, uint256, uint256, bool)
    {
        vm.prank(CANARY_KEEPER);
        return pegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _contractAsKeeper(IPegKeeperV3 pegKeeper, address fraxNetDeposit, uint256 amount)
        internal
        returns (uint256 crvUsdReceived)
    {
        vm.prank(CANARY_KEEPER);
        (uint256 frxUsdSpent, uint256 received, uint256 keeperReward) =
            pegKeeper.contractViaAmm(amount);
        require(frxUsdSpent == amount, "unexpected frxUSD spend");
        require(received > 0, "aggregated redemption returned no crvUSD");
        require(keeperReward > 0, "contraction keeper reward missing");
        require(
            IERC20Allowance(FRXUSD).allowance(address(pegKeeper), fraxNetDeposit) == 0,
            "FraxNet allowance"
        );
        return received;
    }

    function _drainDirectCustodian() internal {
        uint256 directUsdc = IERC20(USDC).balanceOf(FRXUSD_CUSTODIAN);
        require(directUsdc > 0, "direct custodian already empty");
        uint256 redeemable = IFrxUsdRedeemer(FRXUSD_CUSTODIAN).previewWithdraw(directUsdc);
        deal(FRXUSD, CANARY_CUSTODIAN_DRAINER, redeemable);
        vm.startPrank(CANARY_CUSTODIAN_DRAINER);
        IERC20(FRXUSD).approve(FRXUSD_CUSTODIAN, redeemable);
        IFrxUsdRedeemer(FRXUSD_CUSTODIAN)
            .redeem(redeemable, CANARY_CUSTODIAN_DRAINER, CANARY_CUSTODIAN_DRAINER);
        vm.stopPrank();
    }

    function _installSuperstateTokenHarness() internal {
        // The live USTB implementation also uses a post-Shanghai opcode. Preserve its pinned
        // custodian inventory behind an ABI-equivalent ERC-20/offchainRedeem harness; the Frax
        // coordinator, price/cap logic, USDC redeemer, and USDC inventory remain live contracts.
        uint256 rwaInventory = IERC20(SUPERSTATE_TOKEN).balanceOf(RWA_CUSTODIAN);
        SuperstateTokenHarness harness = new SuperstateTokenHarness();
        vm.etch(SUPERSTATE_TOKEN, address(harness).code);
        SuperstateTokenHarness(SUPERSTATE_TOKEN).seed(RWA_CUSTODIAN, rwaInventory);
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = _curveStep(THREE_POOL, USDT, USDC, 2, 1, CURVE_EXECUTION_BUFFER_BPS);
        path[1] = _frxUsdStep(FRXUSD_MINT, USDC, FRXUSD);
    }

    function _contractionPath(address fraxNetDeposit)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _frxUsdRedeemStep(fraxNetDeposit);
        path[1] = _curveStep(THREE_POOL, USDC, USDT, 1, 2, CURVE_EXECUTION_BUFFER_BPS);
        path[2] = _curveStep(USDT_POOL, USDT, CRVUSD, 0, 1, CURVE_EXECUTION_BUFFER_BPS);
    }

    function _frxUsdStep(uint256 kind, address tokenIn, address tokenOut)
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

    function _frxUsdRedeemStep(address fraxNetDeposit)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: FRXUSD_REDEEM,
            venue: fraxNetDeposit,
            tokenIn: FRXUSD,
            tokenOut: USDC,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: FRAXNET_REDEMPTION_EXECUTION_BUFFER_BPS
        });
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut,
        uint256 executionBufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: poolIndexIn,
            poolIndexOut: poolIndexOut,
            executionBufferBps: executionBufferBps
        });
    }
}
