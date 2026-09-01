// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {ExpansionFactory, ExpansionPool, ExpansionToken} from "./PegKeeperV3Expansion.t.sol";

contract ExecutionRoutePool {
    uint256 internal constant PPM = 1_000_000;

    ExpansionToken public immutable coin0;
    ExpansionToken public immutable coin1;
    uint256 public quotePricePpm = PPM;
    uint256 public executionPricePpm = PPM;

    constructor(ExpansionToken coin0_, ExpansionToken coin1_) {
        coin0 = coin0_;
        coin1 = coin1_;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return address(coin0);
        require(index == 1, "coin index");
        return address(coin1);
    }

    function setPrices(uint256 quotePricePpm_, uint256 executionPricePpm_) external {
        quotePricePpm = quotePricePpm_;
        executionPricePpm = executionPricePpm_;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        return _quote(i, j, dx, quotePricePpm);
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut)
    {
        amountOut = _quote(i, j, dx, executionPricePpm);
        require(amountOut >= minDy, "route slippage");
        if (i == 0 && j == 1) {
            require(coin0.transferFrom(msg.sender, address(this), dx), "transfer");
            coin1.mint(msg.sender, amountOut);
        } else {
            require(i == 1 && j == 0, "indices");
            require(coin1.transferFrom(msg.sender, address(this), dx), "transfer");
            coin0.mint(msg.sender, amountOut);
        }
    }

    function _quote(int128 i, int128 j, uint256 dx, uint256 pricePpm)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 inputDecimals;
        uint256 outputDecimals;
        if (i == 0 && j == 1) {
            inputDecimals = coin0.decimals();
            outputDecimals = coin1.decimals();
        } else {
            require(i == 1 && j == 0, "indices");
            inputDecimals = coin1.decimals();
            outputDecimals = coin0.decimals();
        }
        amountOut = dx * pricePpm / PPM;
        if (outputDecimals > inputDecimals) {
            amountOut *= 10 ** (outputDecimals - inputDecimals);
        } else if (inputDecimals > outputDecimals) {
            amountOut /= 10 ** (inputDecimals - outputDecimals);
        }
    }
}

contract ExecutionDaiUsds {
    ExpansionToken public immutable daiToken;
    ExpansionToken public immutable usdsToken;
    uint256 public outputPpm = 1_000_000;

    constructor(ExpansionToken dai_, ExpansionToken usds_) {
        daiToken = dai_;
        usdsToken = usds_;
    }

    function dai() external view returns (address) {
        return address(daiToken);
    }

    function usds() external view returns (address) {
        return address(usdsToken);
    }

    function setOutputPpm(uint256 outputPpm_) external {
        outputPpm = outputPpm_;
    }

    function daiToUsds(address receiver, uint256 amount) external {
        require(daiToken.transferFrom(msg.sender, address(this), amount), "transfer");
        usdsToken.mint(receiver, amount * outputPpm / 1_000_000);
    }

    function usdsToDai(address receiver, uint256 amount) external {
        require(usdsToken.transferFrom(msg.sender, address(this), amount), "transfer");
        daiToken.mint(receiver, amount * outputPpm / 1_000_000);
    }
}

contract ExecutionFrxUsdMinter {
    ExpansionToken public immutable assetToken;
    ExpansionToken public immutable frxUsdToken;
    uint256 public previewPpm = 1_000_000;
    uint256 public executionPpm = 1_000_000;
    uint256 public reportedPpm = 1_000_000;
    bool public depositsPaused;

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

    function setRates(uint256 previewPpm_, uint256 executionPpm_) external {
        previewPpm = previewPpm_;
        executionPpm = executionPpm_;
    }

    function setReportedPpm(uint256 reportedPpm_) external {
        reportedPpm = reportedPpm_;
    }

    function setDepositsPaused(bool paused_) external {
        depositsPaused = paused_;
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        shares = assets * 1e12 * previewPpm / 1_000_000;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!depositsPaused, "mint paused");
        require(assetToken.transferFrom(msg.sender, address(this), assets), "transfer");
        frxUsdToken.mint(receiver, assets * 1e12 * executionPpm / 1_000_000);
        shares = assets * 1e12 * reportedPpm / 1_000_000;
    }
}

contract ExecutionYieldToken is ExpansionToken {
    ExpansionToken public immutable backing;
    uint256 public previewSharesPpm = 1_000_000;
    uint256 public executionSharesPpm = 1_000_000;
    uint256 public assetValuePpm = 1_000_000;
    uint256 public assetValueScale = 1_000_000;
    uint256 public previewRedeemPpm = 1_000_000;
    uint256 public executionRedeemPpm = 1_000_000;
    uint256 public postRedeemAssetValuePpm;
    uint256 public postTransferAssetValuePpm;

    constructor(ExpansionToken backing_) ExpansionToken(18) {
        backing = backing_;
    }

    function asset() external view returns (address) {
        return address(backing);
    }

    function setRates(uint256 previewPpm, uint256 executionPpm, uint256 valuePpm) external {
        previewSharesPpm = previewPpm;
        executionSharesPpm = executionPpm;
        assetValuePpm = valuePpm;
        assetValueScale = 1_000_000;
    }

    function setAssetValueRatio(uint256 numerator, uint256 denominator) external {
        assetValuePpm = numerator;
        assetValueScale = denominator;
    }

    function setRedeemRates(uint256 previewPpm, uint256 executionPpm) external {
        previewRedeemPpm = previewPpm;
        executionRedeemPpm = executionPpm;
    }

    function setPostRedeemAssetValue(uint256 postRedeemPpm) external {
        postRedeemAssetValuePpm = postRedeemPpm;
    }

    function setPostTransferAssetValue(uint256 postTransferPpm) external {
        postTransferAssetValuePpm = postTransferPpm;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (postTransferAssetValuePpm != 0) assetValuePpm = postTransferAssetValuePpm;
        return true;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return assets * previewSharesPpm / 1_000_000;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(backing.transferFrom(msg.sender, address(this), assets), "transfer");
        shares = assets * executionSharesPpm / 1_000_000;
        balanceOf[receiver] += shares;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return shares * previewRedeemPpm / 1_000_000;
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        require(owner == msg.sender, "owner");
        balanceOf[owner] -= shares;
        assets = shares * executionRedeemPpm / 1_000_000;
        backing.mint(receiver, assets);
        if (postRedeemAssetValuePpm != 0) assetValuePpm = postRedeemAssetValuePpm;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetValuePpm / assetValueScale;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * assetValueScale / assetValuePpm;
    }
}

contract PegKeeperV3BackingDeploymentTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant MIN_EXPANSION = 10_000e18;
    uint256 internal constant TARGET_MULTIPLIER = 1e12;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant FRXUSD_MINT = 4;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");
    address internal caller = makeAddr("caller");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExecutionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExecutionRoutePool internal targetToDaiPool;
    ExecutionRoutePool internal targetToBackingPool;
    ExecutionRoutePool internal daiToCrvUsdPool;
    ExecutionDaiUsds internal daiUsds;
    ExecutionFrxUsdMinter internal frxUsdMinter;
    IPegKeeperV3 internal pegKeeper;
    IPegKeeperV3 internal deployment;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        dai = new ExpansionToken(18);
        yieldToken = new ExecutionYieldToken(backingAsset);
        factory = new ExpansionFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        targetPool = new ExpansionPool(crvUsd, targetAsset);
        targetToDaiPool = new ExecutionRoutePool(targetAsset, dai);
        targetToBackingPool = new ExecutionRoutePool(targetAsset, backingAsset);
        daiToCrvUsdPool = new ExecutionRoutePool(dai, crvUsd);
        daiUsds = new ExecutionDaiUsds(dai, backingAsset);
        frxUsdMinter = new ExecutionFrxUsdMinter(targetAsset, backingAsset);
        pegKeeper = _deploy();
        deployment = IPegKeeperV3(address(pegKeeper));
        _installPaths(100);
        _createUndeployedBacking();
    }

    function test_deploysExactAccountedTargetThroughTypedRoute() public {
        uint256 targetAmount = 1_000e6;
        uint256 undeployedBefore = pegKeeper.undeployed_backing();
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 expansionTime = pegKeeper.last_expansion_at();

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.UndeployedBackingDeployed(caller, targetAmount, 1_000e18, 1_000e18, 0);
        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) =
            deployment.deployUndeployedBacking(targetAmount);

        assertEq(targetSpent, targetAmount);
        assertEq(yieldReceived, 1_000e18);
        assertEq(pegKeeper.undeployed_backing(), undeployedBefore - targetAmount);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldReceived);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), yieldReceived);
        assertEq(pegKeeper.trusted_backing_value(), trustedBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertEq(targetAsset.allowance(address(pegKeeper), address(targetToDaiPool)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiUsds)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(yieldToken)), 0);
    }

    function test_preExistingYieldDonationBecomesProtocolBackingWithoutChangingActionDelta()
        public
    {
        uint256 donation = 77e18;
        uint256 targetAmount = 100e6;
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        yieldToken.mint(address(pegKeeper), donation);

        assertEq(pegKeeper.accounted_yield_token_units(), donation);
        assertEq(pegKeeper.trusted_backing_value(), trustedBefore + donation);

        vm.prank(caller);
        (, uint256 yieldReceived) = deployment.deployUndeployedBacking(targetAmount);

        assertEq(yieldReceived, 100e18);
        assertEq(pegKeeper.accounted_yield_token_units(), donation + 100e18);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), donation + 100e18);
    }

    function test_backingDeploymentPauseMakesPreviewAndExpansionRetainTarget() public {
        uint256 targetBefore = targetAsset.balanceOf(address(pegKeeper));
        uint256 yieldBefore = yieldToken.balanceOf(address(pegKeeper));
        uint256 pathLength = pegKeeper.expansion_path_length();
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(governance);
        pegKeeper.set_direction_paused(1, true);

        (,,,, uint256 previewYield, bool previewDeploys) = pegKeeper.previewExpansion(MIN_EXPANSION);
        assertEq(previewYield, 0);
        assertFalse(previewDeploys);

        vm.prank(keeper);
        (, uint256 retained, uint256 yieldReceived,, bool deployedToYield) =
            pegKeeper.expand(MIN_EXPANSION);

        assertFalse(deployedToYield);
        assertEq(yieldReceived, 0);
        assertGt(retained, 0);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), targetBefore + retained);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), yieldBefore);
        assertEq(pegKeeper.undeployed_backing(), targetBefore + retained);
        assertEq(pegKeeper.expansion_path_length(), pathLength);
    }

    function test_unpauseDeploysRetainedBackingAndRestoresImmediateDownstreamRouting() public {
        vm.prank(governance);
        pegKeeper.set_direction_paused(1, true);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(keeper);
        (,,,, bool deployedWhilePaused) = pegKeeper.expand(MIN_EXPANSION);
        assertFalse(deployedWhilePaused);
        uint256 retainedInventory = pegKeeper.undeployed_backing();
        assertGt(retainedInventory, 0);

        vm.prank(governance);
        pegKeeper.set_direction_paused(1, false);
        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) =
            pegKeeper.deployUndeployedBacking(retainedInventory);

        assertEq(targetSpent, retainedInventory);
        assertGt(yieldReceived, 0);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldReceived);

        vm.prank(caller);
        vm.expectRevert();
        pegKeeper.deployUndeployedBacking(retainedInventory);

        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        vm.prank(keeper);
        (,, uint256 immediateYield,, bool deployedAfterUnpause) = pegKeeper.expand(MIN_EXPANSION);

        assertTrue(deployedAfterUnpause);
        assertGt(immediateYield, 0);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldReceived + immediateYield);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_preExistingIntermediateDonationsAreNotRoutedOrAccounted() public {
        dai.mint(address(pegKeeper), 11e18);
        backingAsset.mint(address(pegKeeper), 22e18);

        vm.prank(caller);
        (, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(yieldReceived, 100e18);
        assertEq(dai.balanceOf(address(pegKeeper)), 11e18);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 22e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
    }

    function test_executesExactlySixteenConfiguredSteps() public {
        IPegKeeperV3.RouteStep[] memory path = new IPegKeeperV3.RouteStep[](16);
        for (uint256 i; i < 14; ++i) {
            if (i % 2 == 0) {
                path[i] = _curveStep(
                    address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5
                );
            } else {
                path[i] = _curveStep(
                    address(targetToDaiPool), address(dai), address(targetAsset), 1, 0, 5
                );
            }
        }
        path[14] = _curveStep(
            address(targetToBackingPool), address(targetAsset), address(backingAsset), 0, 1, 5
        );
        path[15] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
        vm.prank(governance);
        pegKeeper.setPaths(path, 100, _contractionPath());

        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(targetSpent, 100e6);
        assertEq(yieldReceived, 100e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
    }

    function test_executesErc4626RedeemStepInsideConfiguredRoute() public {
        IPegKeeperV3.RouteStep[] memory path = new IPegKeeperV3.RouteStep[](4);
        path[0] = _curveStep(
            address(targetToBackingPool), address(targetAsset), address(backingAsset), 0, 1, 5
        );
        path[1] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
        path[2] = _vaultStep(ERC4626_REDEEM, address(yieldToken), address(backingAsset));
        path[3] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
        vm.prank(governance);
        pegKeeper.setPaths(path, 100, _contractionPath());

        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(targetSpent, 100e6);
        assertEq(yieldReceived, 100e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
    }

    function test_executesFrxUsdMintStepWithMeasuredDecimalAdjustedOutput() public {
        _installFrxUsdMintPath(100, 5);

        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(targetSpent, 100e6);
        assertEq(yieldReceived, 100e18);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
        assertEq(targetAsset.allowance(address(pegKeeper), address(frxUsdMinter)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(yieldToken)), 0);
    }

    function test_frxUsdMintFeeConsumesAbsoluteStepLossBudget() public {
        frxUsdMinter.setRates(999_000, 999_000);
        _installFrxUsdMintPath(20, 10);

        vm.prank(caller);
        (, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(yieldReceived, 99.9e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 99.9e18);
    }

    function test_frxUsdMintFeeAboveAbsoluteStepLossBudgetReverts() public {
        frxUsdMinter.setRates(999_000, 999_000);
        _installFrxUsdMintPath(20, 9);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);
    }

    function test_frxUsdMintStepExcludesPreExistingOutputDonation() public {
        backingAsset.mint(address(pegKeeper), 77e18);
        _installFrxUsdMintPath(100, 5);

        vm.prank(caller);
        (, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(yieldReceived, 100e18);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 77e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
    }

    function test_frxUsdMintStepIgnoresReportedOutput() public {
        frxUsdMinter.setReportedPpm(7_000_000);
        _installFrxUsdMintPath(100, 5);

        vm.prank(caller);
        (, uint256 yieldReceived) = deployment.deployUndeployedBacking(100e6);

        assertEq(yieldReceived, 100e18);
        assertEq(pegKeeper.accounted_yield_token_units(), 100e18);
    }

    function test_frxUsdMintStepEnforcesPreviewRelativeMinimumAndRollsBack() public {
        frxUsdMinter.setRates(1_000_000, 999_000);
        _installFrxUsdMintPath(100, 5);
        uint256 undeployedBefore = pegKeeper.undeployed_backing();
        uint256 targetBefore = targetAsset.balanceOf(address(pegKeeper));

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);

        assertEq(pegKeeper.undeployed_backing(), undeployedBefore);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), targetBefore);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(targetAsset.allowance(address(pegKeeper), address(frxUsdMinter)), 0);
    }

    function test_frxUsdMintStepExternalFailureRollsBack() public {
        frxUsdMinter.setDepositsPaused(true);
        _installFrxUsdMintPath(100, 5);
        uint256 undeployedBefore = pegKeeper.undeployed_backing();

        vm.prank(caller);
        vm.expectRevert("mint paused");
        deployment.deployUndeployedBacking(100e6);

        assertEq(pegKeeper.undeployed_backing(), undeployedBefore);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(targetAsset.allowance(address(pegKeeper), address(frxUsdMinter)), 0);
    }

    function test_revertsWhenBackingDeploymentDirectionIsPaused() public {
        vm.prank(governance);
        pegKeeper.set_direction_paused(1, true);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);
    }

    function test_revertsWhenAllExecutionIsPaused() public {
        vm.prank(governance);
        pegKeeper.set_direction_paused(5, true);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);
    }

    function test_rejectsZeroOrOverInventoryTargetAmount() public {
        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(0);

        uint256 overInventoryAmount = pegKeeper.undeployed_backing() + 1;
        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(overInventoryAmount);
    }

    function test_enforcesCurveQuoteRelativeMinimum() public {
        targetToDaiPool.setPrices(1_000_000, 990_000);

        vm.prank(caller);
        vm.expectRevert("route slippage");
        deployment.deployUndeployedBacking(100e6);
    }

    function test_requiresCanonicalConverterOneToOneOutput() public {
        daiUsds.setOutputPpm(999_999);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);
    }

    function test_enforcesErc4626PreviewMinimum() public {
        yieldToken.setRates(1_000_000, 990_000, 1_000_000);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);
    }

    function test_rejectsConversionCostAboveRouteLossLimit() public {
        targetPool.setPrices(1_100_000, 1_100_000);
        _createAdditionalUndeployedBacking();
        yieldToken.setRates(1_000_000, 1_000_000, 990_000);
        _installPaths(50);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(1_000e6);
    }

    function test_rejectsConversionCostAboveAvailableSurplus() public {
        yieldToken.setRates(1_000_000, 1_000_000, 950_000);
        _installPaths(10_000);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(1_000e6);
    }

    function test_postExposureYieldImpairmentBlocksFurtherBackingDeployment() public {
        vm.prank(caller);
        deployment.deployUndeployedBacking(1_000e6);
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);
        _installPaths(10_000);

        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 undeployedBefore = pegKeeper.undeployed_backing();
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 targetBalanceBefore = targetAsset.balanceOf(address(pegKeeper));
        assertLt(pegKeeper.trusted_backing_value(), deployedBefore);
        assertEq(pegKeeper.protocol_surplus(), 0);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);

        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
        assertEq(pegKeeper.undeployed_backing(), undeployedBefore);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), targetBalanceBefore);
        assertEq(targetAsset.allowance(address(pegKeeper), address(targetToDaiPool)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiUsds)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(yieldToken)), 0);
    }

    function test_failedDeploymentRollsBackInventoryAndAllowances() public {
        uint256 undeployedBefore = pegKeeper.undeployed_backing();
        uint256 targetBalanceBefore = targetAsset.balanceOf(address(pegKeeper));
        daiUsds.setOutputPpm(999_999);

        vm.prank(caller);
        vm.expectRevert();
        deployment.deployUndeployedBacking(100e6);

        assertEq(pegKeeper.undeployed_backing(), undeployedBefore);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), targetBalanceBefore);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(targetAsset.allowance(address(pegKeeper), address(targetToDaiPool)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiUsds)), 0);
    }

    function _createUndeployedBacking() internal {
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        daiUsds.setOutputPpm(999_999);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(1, false);
        vm.stopPrank();
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        daiUsds.setOutputPpm(1_000_000);
    }

    function _createAdditionalUndeployedBacking() internal {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        daiUsds.setOutputPpm(999_999);
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        daiUsds.setOutputPpm(1_000_000);
    }

    function _installPaths(uint256 maxRouteLossBps) internal {
        vm.prank(governance);
        pegKeeper.setPaths(_expansionPath(), maxRouteLossBps, _contractionPath());
    }

    function _installFrxUsdMintPath(uint256 maxRouteLossBps, uint256 executionBufferBps) internal {
        IPegKeeperV3.RouteStep[] memory path = new IPegKeeperV3.RouteStep[](2);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_MINT,
            venue: address(frxUsdMinter),
            tokenIn: address(targetAsset),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: executionBufferBps
        });
        path[1] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
        vm.prank(governance);
        pegKeeper.setPaths(path, maxRouteLossBps, _contractionPath());
    }

    function _expansionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5);
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(dai),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: address(yieldToken),
            tokenIn: address(yieldToken),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(backingAsset),
            tokenOut: address(dai),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = _curveStep(address(daiToCrvUsdPool), address(dai), address(crvUsd), 0, 1, 5);
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut,
        uint256 executionBufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory step) {
        step = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: poolIndexIn,
            poolIndexOut: poolIndexOut,
            executionBufferBps: executionBufferBps
        });
    }

    function _vaultStep(uint256 kind, address tokenIn, address tokenOut)
        internal
        view
        returns (IPegKeeperV3.RouteStep memory step)
    {
        step = IPegKeeperV3.RouteStep({
            kind: kind,
            venue: address(yieldToken),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        deployedPegKeeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetPool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            MAX_DEPLOYED,
            1
        );
    }
}
