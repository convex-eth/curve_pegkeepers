// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {ExpansionFactory, ExpansionPool, ExpansionToken} from "./PegKeeperV3Expansion.t.sol";
import {
    ExecutionDaiUsds,
    ExecutionRoutePool,
    ExecutionYieldToken
} from "./PegKeeperV3BackingDeployment.t.sol";

contract PegKeeperV3YieldContractionTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;
    uint256 internal constant TARGET_TO_DEPLOY = 10_000e6;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal expansionKeeper = makeAddr("expansionKeeper");
    address internal contractionKeeper = makeAddr("contractionKeeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExecutionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExecutionRoutePool internal targetToDaiPool;
    ExecutionRoutePool internal daiToCrvUsdPool;
    ExecutionRoutePool internal backingToCrvUsdPool;
    ExecutionDaiUsds internal daiUsds;
    IPegKeeperV3 internal pegKeeper;
    IPegKeeperV3 internal yieldContraction;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        dai = new ExpansionToken(18);
        yieldToken = new ExecutionYieldToken(backingAsset);
        factory = new ExpansionFactory(address(crvUsd));
        targetPool = new ExpansionPool(crvUsd, targetAsset);
        targetToDaiPool = new ExecutionRoutePool(targetAsset, dai);
        daiToCrvUsdPool = new ExecutionRoutePool(dai, crvUsd);
        backingToCrvUsdPool = new ExecutionRoutePool(backingAsset, crvUsd);
        daiUsds = new ExecutionDaiUsds(dai, backingAsset);
        pegKeeper = _deploy();
        yieldContraction = IPegKeeperV3(address(pegKeeper));
        _installPaths(_contractionPath());
        _createYieldBacking();
        daiToCrvUsdPool.setPrices(1_010_000, 1_010_000);
        backingToCrvUsdPool.setPrices(1_010_000, 1_010_000);
    }

    function test_previewKeeperBuybackSelectsEarlyAndNormalState() public {
        uint256 yieldAmount = 1_000e18;
        (uint256 expectedOut, uint256 grossProfit, uint256 reward) = _expected(yieldAmount);

        (uint256 quotedOut, uint256 quotedGross, uint256 quotedReward, bool earlyExit) =
            yieldContraction.previewKeeperBuyback(yieldAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(quotedGross, grossProfit);
        assertEq(quotedReward, reward);
        assertTrue(earlyExit);

        vm.warp(pegKeeper.last_expansion_at() + 2 days);
        (quotedOut, quotedGross, quotedReward, earlyExit) =
            yieldContraction.previewKeeperBuyback(yieldAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(quotedGross, grossProfit);
        assertEq(quotedReward, reward);
        assertFalse(earlyExit);
    }

    function test_earlyYieldContractionPaysRewardAndReducesExposureByNetCrvUsd() public {
        _enableYieldContraction();
        uint256 yieldAmount = 1_000e18;
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 expansionTime = pegKeeper.last_expansion_at();
        (uint256 expectedOut, uint256 grossProfit, uint256 expectedReward) = _expected(yieldAmount);
        uint256 expectedNet = expectedOut - expectedReward;

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.KeeperBuyback(
            contractionKeeper,
            address(backingAsset),
            0,
            yieldAmount,
            expectedOut,
            grossProfit,
            expectedReward,
            true
        );
        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received, uint256 reward) =
            yieldContraction.contractViaAmm(yieldAmount);

        assertEq(spent, yieldAmount);
        assertEq(received, expectedOut);
        assertEq(reward, expectedReward);
        assertEq(crvUsd.balanceOf(contractionKeeper), expectedReward);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), expectedNet);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore - yieldAmount);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore - expectedNet);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertEq(yieldToken.allowance(address(pegKeeper), address(yieldToken)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(daiUsds)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiToCrvUsdPool)), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_sameBlockExpansionThenYieldContractionUsesEarlyExitAndFreshDeltas() public {
        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        uint256 resetAt = pegKeeper.last_expansion_at();
        uint256 exposureAfterExpansion = pegKeeper.deployed_crvusd();
        _enableYieldContraction();

        (,,, bool earlyExit) = yieldContraction.previewKeeperBuyback(1_000e18);
        assertTrue(earlyExit);
        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(1_000e18);

        assertEq(pegKeeper.last_expansion_at(), resetAt);
        assertLt(pegKeeper.deployed_crvusd(), exposureAfterExpansion);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_sameBlockYieldContractionThenExpansionCannotCreateBacking() public {
        _enableYieldContraction();
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(accounted);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertGt(crvUsd.balanceOf(address(pegKeeper)), EXPANSION_AMOUNT);

        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(pegKeeper.deployed_crvusd(), EXPANSION_AMOUNT);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
        assertEq(crvUsd.allowance(address(pegKeeper), address(targetPool)), 0);
    }

    function test_postExposureImpairmentBlocksGrowthAndPartialExitButAllowsFullRestoration()
        public
    {
        _enableYieldContraction();
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        uint256 exposure = pegKeeper.deployed_crvusd();
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);
        assertLt(pegKeeper.trusted_backing_value(), exposure);

        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        vm.expectRevert();
        pegKeeper.expand(EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        vm.expectRevert();
        pegKeeper.claimSurplus(1e18);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(accounted / 10);
        assertEq(pegKeeper.accounted_yield_token_units(), accounted);
        assertEq(pegKeeper.deployed_crvusd(), exposure);

        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(accounted);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_redemptionShutdownRollsBackImpairedPositionWithoutAccountingDrift() public {
        _enableYieldContraction();
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        uint256 exposure = pegKeeper.deployed_crvusd();
        uint256 yieldBalance = yieldToken.balanceOf(address(pegKeeper));
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);
        yieldToken.setRedeemRates(0, 0);

        (uint256 previewOut, uint256 previewProfit, uint256 previewReward, bool earlyExit) =
            yieldContraction.previewKeeperBuyback(accounted);
        assertEq(previewOut, 0);
        assertEq(previewProfit, 0);
        assertEq(previewReward, 0);
        assertTrue(earlyExit);
        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(accounted);

        assertEq(pegKeeper.accounted_yield_token_units(), accounted);
        assertEq(pegKeeper.deployed_crvusd(), exposure);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), yieldBalance);
        assertEq(yieldToken.allowance(address(pegKeeper), address(yieldToken)), 0);
        assertLt(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_normalYieldContractionRequiresMaturity() public {
        _enableYieldContraction();
        daiToCrvUsdPool.setPrices(1_002_000, 1_002_000);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);

        vm.warp(pegKeeper.last_expansion_at() + 2 days);
        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_rejectsZeroUnaccountedAndOverExposureAmounts() public {
        vm.expectRevert();
        yieldContraction.previewKeeperBuyback(0);

        uint256 unaccountedAmount = pegKeeper.accounted_yield_token_units() + 1;
        yieldToken.mint(address(pegKeeper), 1_000e18);
        vm.expectRevert();
        yieldContraction.previewKeeperBuyback(unaccountedAmount);

        yieldToken.setRates(1_000_000, 1_000_000, 2_000_000);
        uint256 fullAccountedAmount = pegKeeper.accounted_yield_token_units();
        vm.expectRevert();
        yieldContraction.previewKeeperBuyback(fullAccountedAmount);
    }

    function test_yieldContractionRequiresEnabledDirection() public {
        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_yieldContractionRequiresGlobalExecution() public {
        _enableYieldContraction();
        vm.prank(governance);
        pegKeeper.set_direction_paused(5, true);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_yieldContractionRemainsOpenAfterFactoryCeilingFallsBelowExposure() public {
        uint256 exposure = pegKeeper.deployed_crvusd();
        factory.setDebtCeiling(address(pegKeeper), exposure - 1);
        _enableYieldContraction();

        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(1_000e18);

        assertLt(pegKeeper.deployed_crvusd(), exposure);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_yieldContractionEnforcesCurveQuoteFloor() public {
        _enableYieldContraction();
        daiToCrvUsdPool.setPrices(1_010_000, 1_009_000);

        vm.prank(contractionKeeper);
        vm.expectRevert("route slippage");
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_yieldContractionRequiresCanonicalConverterOutput() public {
        _enableYieldContraction();
        daiUsds.setOutputPpm(999_999);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_yieldContractionEnforcesRedeemPreviewMinimum() public {
        _enableYieldContraction();
        yieldToken.setRedeemRates(1_000_000, 990_000);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);
    }

    function test_preExistingIntermediateAndCrvUsdDonationsAreExcluded() public {
        _enableYieldContraction();
        backingAsset.mint(address(pegKeeper), 11e18);
        dai.mint(address(pegKeeper), 22e18);
        crvUsd.mint(address(pegKeeper), 77e18);
        (uint256 expectedOut,, uint256 expectedReward) = _expected(1_000e18);

        vm.prank(contractionKeeper);
        (, uint256 received,) = yieldContraction.contractViaAmm(1_000e18);

        assertEq(received, expectedOut);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 11e18);
        assertEq(dai.balanceOf(address(pegKeeper)), 22e18);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 77e18 + expectedOut - expectedReward);
    }

    function test_wholePositionValueDifferenceControlsProfit() public {
        _enableYieldContraction();
        yieldToken.setRates(1_000_000, 1_000_000, 1_500_000);
        daiToCrvUsdPool.setPrices(3_000_000, 3_000_000);

        (uint256 expectedOut, uint256 grossProfit, uint256 reward,) =
            yieldContraction.previewKeeperBuyback(1);
        assertEq(expectedOut, 3);
        assertEq(grossProfit, 1);
        assertEq(reward, 0);

        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(1);
        uint256 trustedRemoved = trustedBefore - pegKeeper.trusted_backing_value();
        assertEq(trustedRemoved, 2);
    }

    function test_postRouteWholePositionValueControlsProfitAndReward() public {
        _enableYieldContraction();
        daiToCrvUsdPool.setPrices(1_920_000, 1_920_000);
        yieldToken.setPostRedeemAssetValue(900_000);
        uint256 amount = 1_000e18;

        (,,, bool earlyExit) = yieldContraction.previewKeeperBuyback(amount);
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        vm.expectEmit(true, true, true, true, address(pegKeeper));
        emit IPegKeeperV3.KeeperBuyback(
            contractionKeeper, address(backingAsset), 0, amount, 1_920e18, 20e18, 6e18, earlyExit
        );
        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received, uint256 reward) = yieldContraction.contractViaAmm(amount);

        assertEq(spent, amount);
        assertEq(received, 1_920e18);
        assertEq(reward, 6e18);
        assertEq(trustedBefore - pegKeeper.trusted_backing_value(), 1_900e18);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_fullYieldContractionCapsExposureReduction() public {
        _enableYieldContraction();
        uint256 amount = pegKeeper.accounted_yield_token_units();
        (uint256 expectedOut,, uint256 expectedReward) = _expected(amount);

        vm.prank(contractionKeeper);
        yieldContraction.contractViaAmm(amount);

        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), expectedOut - expectedReward);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function testFuzz_yieldContractionPreservesPrincipalAcrossAmountsAndRates(
        uint256 amountSeed,
        uint256 assetRateSeed,
        uint256 poolPriceSeed
    ) public {
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 yieldAmount = bound(amountSeed, 1e18, accountedBefore / 2);
        uint256 assetRatePpm = bound(assetRateSeed, 1_000_000, 1_500_000);
        uint256 poolPricePpm = bound(poolPriceSeed, 1_010_000, 1_100_000);
        yieldToken.setRates(1_000_000, 1_000_000, assetRatePpm);
        yieldToken.setRedeemRates(assetRatePpm, assetRatePpm);
        daiToCrvUsdPool.setPrices(poolPricePpm, poolPricePpm);
        _enableYieldContraction();

        uint256 exposureBefore = pegKeeper.deployed_crvusd();
        (uint256 expectedOut,, uint256 expectedReward,) =
            yieldContraction.previewKeeperBuyback(yieldAmount);
        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received, uint256 reward) =
            yieldContraction.contractViaAmm(yieldAmount);
        uint256 netRetained = received - reward;
        uint256 expectedExposureAfter =
            netRetained < exposureBefore ? exposureBefore - netRetained : 0;

        assertEq(spent, yieldAmount);
        assertEq(received, expectedOut);
        assertEq(reward, expectedReward);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore - yieldAmount);
        assertEq(pegKeeper.deployed_crvusd(), expectedExposureAfter);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_failedYieldContractionRollsBackAccountingBalancesAndAllowances() public {
        _enableYieldContraction();
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 yieldBalanceBefore = yieldToken.balanceOf(address(pegKeeper));
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        daiUsds.setOutputPpm(999_999);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        yieldContraction.contractViaAmm(1_000e18);

        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), yieldBalanceBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
        assertEq(yieldToken.allowance(address(pegKeeper), address(yieldToken)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(daiUsds)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiToCrvUsdPool)), 0);
    }

    function test_executesExactlySixteenContractionSteps() public {
        _enableYieldContraction();
        IPegKeeperV3.RouteStep[] memory path = new IPegKeeperV3.RouteStep[](16);
        for (uint256 i; i < 13; ++i) {
            if (i % 2 == 0) {
                path[i] = _vaultStep(ERC4626_REDEEM, address(yieldToken), address(backingAsset));
            } else {
                path[i] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
            }
        }
        path[13] = _converterStep(address(backingAsset), address(dai));
        path[14] = _converterStep(address(dai), address(backingAsset));
        path[15] = _curveStep(
            address(backingToCrvUsdPool), address(backingAsset), address(crvUsd), 0, 1, 5
        );
        _installPaths(path);

        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received,) = yieldContraction.contractViaAmm(1_000e18);

        assertEq(spent, 1_000e18);
        assertEq(received, 1_010e18);
        assertEq(pegKeeper.accounted_yield_token_units(), EXPANSION_AMOUNT - 1_000e18);
    }

    function _createYieldBacking() internal {
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(1, false);
        vm.stopPrank();
        daiUsds.setOutputPpm(999_999);
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        daiUsds.setOutputPpm(1_000_000);
        vm.prank(expansionKeeper);
        pegKeeper.deployUndeployedBacking(TARGET_TO_DEPLOY);
    }

    function _enableYieldContraction() internal {
        vm.prank(governance);
        pegKeeper.set_direction_paused(4, false);
    }

    function _expected(uint256 yieldAmount)
        internal
        view
        returns (uint256 expectedOut, uint256 grossProfit, uint256 reward)
    {
        uint256 backingOut = yieldToken.previewRedeem(yieldAmount);
        expectedOut = daiToCrvUsdPool.get_dy(0, 1, backingOut);
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        uint256 trustedBefore = yieldToken.convertToAssets(accounted);
        uint256 trustedAfter = yieldToken.convertToAssets(accounted - yieldAmount);
        uint256 trustedRemoved = trustedBefore - trustedAfter;
        if (expectedOut > trustedRemoved) grossProfit = expectedOut - trustedRemoved;
        reward = grossProfit * 3_000 / 10_000;
        if (reward > 20e18) reward = 20e18;
    }

    function _installPaths(IPegKeeperV3.RouteStep[] memory contractionPath) internal {
        vm.prank(governance);
        pegKeeper.setPaths(_expansionPath(), 100, contractionPath);
    }

    function _expansionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5);
        path[1] = _converterStep(address(dai), address(backingAsset));
        path[2] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _vaultStep(ERC4626_REDEEM, address(yieldToken), address(backingAsset));
        path[1] = _converterStep(address(backingAsset), address(dai));
        path[2] = _curveStep(address(daiToCrvUsdPool), address(dai), address(crvUsd), 0, 1, 5);
    }

    function _converterStep(address tokenIn, address tokenOut)
        internal
        view
        returns (IPegKeeperV3.RouteStep memory step)
    {
        step = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
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

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory),
            address(targetPool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            feeReceiver,
            governance,
            emergencyAdmin,
            MAX_DEPLOYED
        );
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        address deployed;

        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        deployedPegKeeper = IPegKeeperV3(deployed);
    }
}
