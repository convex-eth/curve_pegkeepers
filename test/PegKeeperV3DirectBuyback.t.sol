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

contract PegKeeperV3DirectBuybackTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;
    uint256 internal constant TARGET_TO_DEPLOY = 10_000e6;
    uint256 internal constant PPM = 1_000_000;
    uint256 internal constant EARLY_EXIT_PPM = 5_000;
    uint256 internal constant NORMAL_EXIT_PPM = 1_000;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal expansionKeeper = makeAddr("expansionKeeper");
    address internal buyer = makeAddr("buyer");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExecutionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExecutionRoutePool internal targetToDaiPool;
    ExecutionRoutePool internal daiToCrvUsdPool;
    ExecutionDaiUsds internal daiUsds;
    IPegKeeperV3 internal pegKeeper;

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
        daiUsds = new ExecutionDaiUsds(dai, backingAsset);
        pegKeeper = _deploy();
        _installExpansionPath();
        _createYieldBacking();
    }

    function test_previewBuybackSelectsEarlyAndNormalMargin() public {
        uint256 crvUsdAmount = 1_000e18;
        (uint256 expectedOut, uint256 expectedProfit) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);

        (uint256 quotedOut, uint256 requiredProfit, bool earlyExit) =
            pegKeeper.previewBuyback(crvUsdAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(requiredProfit, expectedProfit);
        assertTrue(earlyExit);

        vm.warp(pegKeeper.last_expansion_at() + 2 days);
        (expectedOut, expectedProfit) = _expectedQuote(crvUsdAmount, NORMAL_EXIT_PPM);
        (quotedOut, requiredProfit, earlyExit) = pegKeeper.previewBuyback(crvUsdAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(requiredProfit, expectedProfit);
        assertFalse(earlyExit);
    }

    function test_directBuybackTransfersOnlyFixedYieldTokenAndReducesExposure() public {
        _enableDirectBuyback();
        uint256 crvUsdAmount = 1_000e18;
        _fundBuyer(crvUsdAmount);
        (uint256 expectedOut,) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 targetBefore = pegKeeper.undeployed_backing();
        uint256 expansionTime = pegKeeper.last_expansion_at();

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.DirectBuyback(buyer, crvUsdAmount, expectedOut, true);
        vm.prank(buyer);
        uint256 yieldTokenOut = pegKeeper.buyback(crvUsdAmount, expectedOut);

        assertEq(yieldTokenOut, expectedOut);
        assertEq(crvUsd.balanceOf(buyer), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), crvUsdAmount);
        assertEq(yieldToken.balanceOf(buyer), expectedOut);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore - expectedOut);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore - crvUsdAmount);
        assertEq(pegKeeper.undeployed_backing(), targetBefore);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_sameBlockExpansionThenDirectBuybackUsesEarlyExitAndNoStaleAccounting() public {
        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        uint256 resetAt = pegKeeper.last_expansion_at();
        uint256 exposureAfterExpansion = pegKeeper.deployed_crvusd();
        uint256 crvUsdAmount = 1_000e18;
        _fundBuyer(crvUsdAmount);
        _enableDirectBuyback();

        (uint256 expectedOut,, bool earlyExit) = pegKeeper.previewBuyback(crvUsdAmount);
        assertTrue(earlyExit);
        vm.prank(buyer);
        pegKeeper.buyback(crvUsdAmount, expectedOut);

        assertEq(pegKeeper.last_expansion_at(), resetAt);
        assertEq(pegKeeper.deployed_crvusd(), exposureAfterExpansion - crvUsdAmount);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_sameBlockDirectBuybackThenExpansionCannotCreateBacking() public {
        _enableDirectBuyback();
        _fundBuyer(EXPANSION_AMOUNT);
        (uint256 expectedOut,,) = pegKeeper.previewBuyback(EXPANSION_AMOUNT);
        vm.prank(buyer);
        pegKeeper.buyback(EXPANSION_AMOUNT, expectedOut);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), EXPANSION_AMOUNT);

        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(pegKeeper.deployed_crvusd(), EXPANSION_AMOUNT);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
        assertEq(crvUsd.allowance(address(pegKeeper), address(targetPool)), 0);
    }

    function test_directBuybackRequiresDirectionAndGlobalExecution() public {
        uint256 crvUsdAmount = 1_000e18;
        _fundBuyer(crvUsdAmount);

        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(crvUsdAmount, 0);

        _enableDirectBuyback();
        vm.prank(governance);
        pegKeeper.set_direction_paused(5, true);
        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(crvUsdAmount, 0);
    }

    function test_directBuybackRemainsOpenAfterFactoryCeilingFallsBelowExposure() public {
        uint256 exposure = pegKeeper.deployed_crvusd();
        factory.setDebtCeiling(address(pegKeeper), exposure - 1);
        _enableDirectBuyback();
        _fundBuyer(1_000e18);
        (uint256 expectedOut,,) = pegKeeper.previewBuyback(1_000e18);

        vm.prank(buyer);
        pegKeeper.buyback(1_000e18, expectedOut);

        assertEq(pegKeeper.deployed_crvusd(), exposure - 1_000e18);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_previewRejectsZeroOverExposureAndInsufficientYield() public {
        vm.expectRevert();
        pegKeeper.previewBuyback(0);

        uint256 deployed = pegKeeper.deployed_crvusd();
        vm.expectRevert();
        pegKeeper.previewBuyback(deployed + 1);

        yieldToken.setRates(1_000_000, 1_000_000, 100_000);
        vm.expectRevert();
        pegKeeper.previewBuyback(deployed);
    }

    function test_previewRejectsNativeUnitDustPayout() public {
        vm.expectRevert();
        pegKeeper.previewBuyback(1);
    }

    function test_minYieldTokenOutCanOnlyTightenExecutionAndRollback() public {
        _enableDirectBuyback();
        uint256 crvUsdAmount = 1_000e18;
        _fundBuyer(crvUsdAmount);
        (uint256 expectedOut,) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();

        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(crvUsdAmount, expectedOut + 1);

        assertEq(crvUsd.balanceOf(buyer), crvUsdAmount);
        assertEq(yieldToken.balanceOf(buyer), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
    }

    function test_donationsDoNotChangeQuoteOrAccounting() public {
        _enableDirectBuyback();
        uint256 crvUsdAmount = 1_000e18;
        (uint256 expectedOut,,) = pegKeeper.previewBuyback(crvUsdAmount);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 rawGapBefore = yieldToken.balanceOf(address(pegKeeper)) - accountedBefore;

        yieldToken.mint(address(pegKeeper), 777e18);
        crvUsd.mint(address(pegKeeper), 333e18);
        (uint256 quotedAfterDonation,,) = pegKeeper.previewBuyback(crvUsdAmount);
        assertEq(quotedAfterDonation, expectedOut);
        _fundBuyer(crvUsdAmount);

        vm.prank(buyer);
        pegKeeper.buyback(crvUsdAmount, expectedOut);

        uint256 rawGapAfter =
            yieldToken.balanceOf(address(pegKeeper)) - pegKeeper.accounted_yield_token_units();
        assertEq(rawGapAfter, rawGapBefore + 777e18);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 333e18 + crvUsdAmount);
    }

    function test_fullExposureBuybackCapsDeploymentAtZero() public {
        _enableDirectBuyback();
        uint256 crvUsdAmount = pegKeeper.deployed_crvusd();
        _fundBuyer(crvUsdAmount);
        (uint256 expectedOut,) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);

        vm.prank(buyer);
        uint256 actualOut = pegKeeper.buyback(crvUsdAmount, expectedOut);

        assertEq(actualOut, expectedOut);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertGt(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), crvUsdAmount);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_postExposureImpairmentBlocksPartialAndFullDirectBuyback() public {
        _enableDirectBuyback();
        uint256 exposure = pegKeeper.deployed_crvusd();
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);
        assertLt(pegKeeper.trusted_backing_value(), exposure);

        uint256 partialAmount = 1_000e18;
        _fundBuyer(partialAmount);
        vm.expectRevert();
        pegKeeper.previewBuyback(partialAmount);
        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(partialAmount, 0);

        vm.expectRevert();
        pegKeeper.previewBuyback(exposure);
        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(exposure, 0);

        assertEq(pegKeeper.deployed_crvusd(), exposure);
        assertEq(pegKeeper.accounted_yield_token_units(), accounted);
        assertEq(crvUsd.balanceOf(buyer), partialAmount);
        assertEq(yieldToken.balanceOf(buyer), 0);
        assertLt(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_postTransferRateChangeUsesRealizedWholePositionValueAndRollsBack() public {
        _enableDirectBuyback();
        uint256 crvUsdAmount = 1_000e18;
        _fundBuyer(crvUsdAmount);
        (uint256 expectedOut,) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        yieldToken.setPostTransferAssetValue(1_400_000);

        vm.prank(buyer);
        vm.expectRevert();
        pegKeeper.buyback(crvUsdAmount, expectedOut);

        assertEq(crvUsd.balanceOf(buyer), crvUsdAmount);
        assertEq(yieldToken.balanceOf(buyer), 0);
        assertEq(yieldToken.assetValuePpm(), 1_000_000);
        assertEq(pegKeeper.accounted_yield_token_units(), accountedBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
    }

    function test_wholePositionValueRemovedIsAuthoritativeUnderFloorRounding() public {
        _enableDirectBuyback();
        yieldToken.setRates(1_000_000, 1_000_000, 1_500_001);
        uint256 crvUsdAmount = 1_000e18 + 123;
        _fundBuyer(crvUsdAmount);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 surplusBefore = trustedBefore - deployedBefore;
        (uint256 expectedOut, uint256 requiredProfit) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);
        uint256 preYieldValue = yieldToken.convertToAssets(accountedBefore);
        uint256 postYieldValue = yieldToken.convertToAssets(accountedBefore - expectedOut);
        uint256 trustedRemoved = preYieldValue - postYieldValue;
        uint256 payoutBudget = crvUsdAmount * PPM / (PPM + EARLY_EXIT_PPM);

        vm.prank(buyer);
        pegKeeper.buyback(crvUsdAmount, expectedOut);

        uint256 surplusAfter = pegKeeper.trusted_backing_value() - pegKeeper.deployed_crvusd();
        assertLe(trustedRemoved, payoutBudget);
        assertEq(requiredProfit, trustedRemoved * EARLY_EXIT_PPM / PPM);
        assertEq(surplusAfter - surplusBefore, crvUsdAmount - trustedRemoved);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function testFuzz_directBuybackPreservesPrincipalAcrossAmountsAndConversionRates(
        uint256 crvUsdAmount,
        uint256 assetValuePpm
    ) public {
        _enableDirectBuyback();
        crvUsdAmount = bound(crvUsdAmount, 1e12, EXPANSION_AMOUNT);
        assetValuePpm = bound(assetValuePpm, 1_000_000, 2_000_000);
        yieldToken.setRates(1_000_000, 1_000_000, assetValuePpm);
        _fundBuyer(crvUsdAmount);
        uint256 accountedBefore = pegKeeper.accounted_yield_token_units();
        uint256 preYieldValue = yieldToken.convertToAssets(accountedBefore);
        uint256 surplusBefore = pegKeeper.trusted_backing_value() - pegKeeper.deployed_crvusd();
        (uint256 expectedOut, uint256 requiredProfit) = _expectedQuote(crvUsdAmount, EARLY_EXIT_PPM);
        uint256 postYieldValue = yieldToken.convertToAssets(accountedBefore - expectedOut);
        uint256 trustedRemoved = preYieldValue - postYieldValue;

        vm.prank(buyer);
        uint256 actualOut = pegKeeper.buyback(crvUsdAmount, expectedOut);

        assertEq(actualOut, expectedOut);
        assertGe(crvUsdAmount, trustedRemoved + requiredProfit);
        assertEq(pegKeeper.protocol_surplus() - surplusBefore, crvUsdAmount - trustedRemoved);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _expectedQuote(uint256 crvUsdAmount, uint256 exitMarginPpm)
        internal
        view
        returns (uint256 expectedOut, uint256 requiredProfit)
    {
        uint256 payoutBudget = crvUsdAmount * PPM / (PPM + exitMarginPpm);
        expectedOut = yieldToken.convertToShares(payoutBudget - 1);
        uint256 accounted = pegKeeper.accounted_yield_token_units();
        uint256 trustedRemoved = yieldToken.convertToAssets(accounted)
            - yieldToken.convertToAssets(accounted - expectedOut);
        requiredProfit = trustedRemoved * exitMarginPpm / PPM;
    }

    function _fundBuyer(uint256 amount) internal {
        crvUsd.mint(buyer, amount);
        vm.prank(buyer);
        crvUsd.approve(address(pegKeeper), amount);
    }

    function _enableDirectBuyback() internal {
        vm.prank(governance);
        pegKeeper.set_direction_paused(2, false);
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

    function _installExpansionPath() internal {
        IPegKeeperV3.RouteStep[] memory expansionPath = new IPegKeeperV3.RouteStep[](3);
        expansionPath[0] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(targetToDaiPool),
            tokenIn: address(targetAsset),
            tokenOut: address(dai),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
        expansionPath[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(dai),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        expansionPath[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        IPegKeeperV3.RouteStep[] memory contractionPath = new IPegKeeperV3.RouteStep[](3);
        contractionPath[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: address(yieldToken),
            tokenIn: address(yieldToken),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        contractionPath[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(backingAsset),
            tokenOut: address(dai),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        contractionPath[2] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(daiToCrvUsdPool),
            tokenIn: address(dai),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
        vm.prank(governance);
        pegKeeper.setPaths(expansionPath, 100, contractionPath);
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
            MAX_DEPLOYED,
            1
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
