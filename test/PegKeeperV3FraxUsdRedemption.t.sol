// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    ExpansionFactory,
    ExpansionOracle,
    ExpansionPool,
    ExpansionToken
} from "./PegKeeperV3Expansion.t.sol";

contract ExecutionFrxUsdExternalShare {
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant SCALE = 1e12;

    ExpansionToken public immutable assetToken;
    ExpansionToken public immutable frxUsdToken;
    uint256 public previewDepositPpm = PPM;
    uint256 public executionDepositPpm = PPM;
    uint256 public previewRedeemPpm = 999_900;
    uint256 public executionRedeemPpm = 999_900;

    constructor(ExpansionToken asset_, ExpansionToken frxUsd_) {
        assetToken = asset_;
        frxUsdToken = frxUsd_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function frxUSD() external view returns (address) {
        return address(frxUsdToken);
    }

    function setRedeemRates(uint256 previewPpm_, uint256 executionPpm_) external {
        previewRedeemPpm = previewPpm_;
        executionRedeemPpm = executionPpm_;
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        shares = assets * SCALE * previewDepositPpm / PPM;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "asset transfer");
        shares = assets * SCALE * executionDepositPpm / PPM;
        frxUsdToken.mint(receiver, shares);
    }

    function previewRedeem(uint256 shares) external view returns (uint256 assets) {
        assets = shares * previewRedeemPpm / PPM / SCALE;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        require(frxUsdToken.transferFrom(owner, address(this), shares), "share transfer");
        assets = shares * executionRedeemPpm / PPM / SCALE;
        assetToken.mint(receiver, assets);
    }
}

contract ExecutionFraxNetDeposit {
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant SCALE = 1e12;

    ExpansionToken public immutable frxUsdToken;
    ExpansionToken public immutable usdcToken;
    address public immutable recipient;
    uint256 public executionRedeemPpm = 999_900;

    constructor(ExpansionToken frxUsd_, ExpansionToken usdc_, address recipient_) {
        frxUsdToken = frxUsd_;
        usdcToken = usdc_;
        recipient = recipient_;
    }

    function asset() external view returns (address) {
        return address(frxUsdToken);
    }

    function frxUSD() external view returns (address) {
        return address(frxUsdToken);
    }

    function USDC() external view returns (address) {
        return address(usdcToken);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function isFraxNetDeposit(address account) external view returns (bool) {
        return account == address(this);
    }

    function targetEid() external pure returns (uint32) {
        return 30_101;
    }

    function targetAddress() external view returns (bytes32) {
        return bytes32(uint256(uint160(recipient)));
    }

    function setExecutionRedeemRate(uint256 executionPpm_) external {
        executionRedeemPpm = executionPpm_;
    }

    function processRedemption(uint256 amount) external returns (uint256 usdcOut) {
        require(frxUsdToken.balanceOf(address(this)) >= amount, "frxUSD transfer");
        usdcOut = amount * executionRedeemPpm / PPM / SCALE;
        usdcToken.mint(recipient, usdcOut);
    }
}

contract PegKeeperV3FraxUsdRedemptionTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant FRXUSD_MINT = 4;
    uint256 internal constant FRXUSD_REDEEM = 5;

    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal expansionKeeper = makeAddr("expansionKeeper");
    address internal contractionKeeper = makeAddr("contractionKeeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal usdc;
    ExpansionToken internal frxUsd;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExpansionOracle internal targetOracle;
    ExpansionOracle internal yieldOracle;
    ExecutionFrxUsdExternalShare internal frax;
    ExecutionFraxNetDeposit internal fraxNetDeposit;
    IPegKeeperV3 internal pegKeeper;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        usdc = new ExpansionToken(6);
        frxUsd = new ExpansionToken(18);
        factory = new ExpansionFactory(address(crvUsd), address(this), emergencyAdmin, feeReceiver);
        targetPool = new ExpansionPool(crvUsd, usdc);
        targetOracle = new ExpansionOracle();
        yieldOracle = new ExpansionOracle();
        frax = new ExecutionFrxUsdExternalShare(usdc, frxUsd);

        pegKeeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetPool),
            address(usdc),
            address(frxUsd),
            address(frxUsd),
            MAX_DEPLOYED,
            1,
            address(targetOracle),
            address(yieldOracle)
        );
        fraxNetDeposit = new ExecutionFraxNetDeposit(frxUsd, usdc, address(pegKeeper));
    }

    function test_fraxRedemptionRoutePreviewsAndExecutesThroughFraxNetAggregator() public {
        _installPathsAndExpand();
        _enableYieldContraction();

        uint256 frxUsdAmount = 1_000e18;
        (uint256 previewOut, uint256 previewProfit, uint256 previewReward, bool earlyExit) =
            pegKeeper.previewKeeperBuyback(frxUsdAmount);
        assertTrue(earlyExit);
        assertGt(previewOut, frxUsdAmount);
        assertGt(previewProfit, 0);
        assertGt(previewReward, 0);

        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received, uint256 reward) = pegKeeper.contractViaAmm(frxUsdAmount);

        assertEq(spent, frxUsdAmount);
        assertGe(received, previewOut * 9_999 / 10_000);
        assertLe(received, previewOut);
        assertGt(reward, 0);
        assertLe(reward, previewReward);
        assertEq(crvUsd.balanceOf(contractionKeeper), reward);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore - frxUsdAmount);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore - (received - reward));
        assertEq(frxUsd.allowance(address(pegKeeper), address(fraxNetDeposit)), 0);
        assertEq(frxUsd.balanceOf(address(fraxNetDeposit)), frxUsdAmount);
        assertEq(usdc.allowance(address(pegKeeper), address(targetPool)), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_fraxRedemptionExecutionUnderDeliveryRevertsWithoutAccountingDrift() public {
        _installPathsAndExpand();
        _enableYieldContraction();

        uint256 frxUsdAmount = 1_000e18;
        (uint256 previewOut,,,) = pegKeeper.previewKeeperBuyback(frxUsdAmount);
        assertGt(previewOut, 0);

        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 frxBalanceBefore = frxUsd.balanceOf(address(pegKeeper));
        fraxNetDeposit.setExecutionRedeemRate(990_000);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        pegKeeper.contractViaAmm(frxUsdAmount);

        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
        assertEq(frxUsd.balanceOf(address(pegKeeper)), frxBalanceBefore);
        assertEq(frxUsd.allowance(address(pegKeeper), address(fraxNetDeposit)), 0);
    }

    function _installPathsAndExpand() internal {
        pegKeeper.setPaths(_expansionPath(), 5, _contractionPath());
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
        pegKeeper.set_expansion_config(5, 1_500_000, 300_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(0, false);

        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        assertGt(pegKeeper.accounted_yield_token_units(), 0);
    }

    function _enableYieldContraction() internal {
        pegKeeper.set_direction_paused(4, false);
    }

    function _expansionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](1);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_MINT,
            venue: address(frax),
            tokenIn: address(usdc),
            tokenOut: address(frxUsd),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 1
        });
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_REDEEM,
            venue: address(fraxNetDeposit),
            tokenIn: address(frxUsd),
            tokenOut: address(usdc),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 1
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(targetPool),
            tokenIn: address(usdc),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 3
        });
    }
}
