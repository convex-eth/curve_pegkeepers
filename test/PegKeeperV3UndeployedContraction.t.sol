// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    ExpansionFactory,
    ExpansionPool,
    ExpansionToken,
    ExpansionYieldToken
} from "./PegKeeperV3Expansion.t.sol";

contract PegKeeperV3UndeployedContractionTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;
    uint256 internal constant TARGET_MULTIPLIER = 1e12;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal expansionKeeper = makeAddr("expansionKeeper");
    address internal contractionKeeper = makeAddr("contractionKeeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal pool;
    IPegKeeperV3 internal pegKeeper;
    IPegKeeperV3 internal contraction;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        yieldToken = new ExpansionYieldToken(address(backingAsset));
        factory = new ExpansionFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        pool = new ExpansionPool(crvUsd, targetAsset);
        pegKeeper = _deploy();
        contraction = IPegKeeperV3(address(pegKeeper));
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
    }

    function test_previewUndeployedContractionSelectsEarlyAndNormalState() public {
        _createUndeployedBacking();
        uint256 targetAmount = 1_000e6;
        (uint256 expectedOut, uint256 grossProfit, uint256 reward) = _expected(targetAmount);

        (uint256 quotedOut, uint256 quotedGross, uint256 quotedReward, bool earlyExit) =
            contraction.previewUndeployedContraction(targetAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(quotedGross, grossProfit);
        assertEq(quotedReward, reward);
        assertTrue(earlyExit);

        vm.warp(pegKeeper.last_expansion_at() + 2 days);
        (quotedOut, quotedGross, quotedReward, earlyExit) =
            contraction.previewUndeployedContraction(targetAmount);
        assertEq(quotedOut, expectedOut);
        assertEq(quotedGross, grossProfit);
        assertEq(quotedReward, reward);
        assertFalse(earlyExit);
    }

    function test_previewRejectsZeroTargetAmount() public {
        _createUndeployedBacking();

        vm.expectRevert();
        contraction.previewUndeployedContraction(0);
    }

    function test_earlyContractionPaysProfitShareAndReducesExposureByNetCrvUsd() public {
        _createUndeployedBacking();
        _enableContraction();
        uint256 targetAmount = 1_000e6;
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 backingBefore = pegKeeper.undeployed_backing();
        uint256 expansionTime = pegKeeper.last_expansion_at();
        (uint256 expectedOut, uint256 grossProfit, uint256 expectedReward) = _expected(targetAmount);
        uint256 expectedNet = expectedOut - expectedReward;

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.KeeperBuyback(
            contractionKeeper,
            address(targetAsset),
            targetAmount,
            0,
            expectedOut,
            grossProfit,
            expectedReward,
            true
        );
        vm.prank(contractionKeeper);
        (uint256 spent, uint256 received, uint256 reward) =
            contraction.contractUndeployedBacking(targetAmount);

        assertEq(spent, targetAmount);
        assertEq(received, expectedOut);
        assertEq(reward, expectedReward);
        assertEq(crvUsd.balanceOf(contractionKeeper), expectedReward);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), expectedNet);
        assertEq(pegKeeper.undeployed_backing(), backingBefore - targetAmount);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore - expectedNet);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertEq(targetAsset.allowance(address(pegKeeper), address(pool)), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_normalMarginContractionRequiresMaturity() public {
        _createUndeployedBacking();
        _enableContraction();
        pool.setReversePrices(1_002_000, 1_002_000);
        uint256 targetAmount = 1_000e6;

        vm.prank(contractionKeeper);
        vm.expectRevert();
        contraction.contractUndeployedBacking(targetAmount);

        vm.warp(pegKeeper.last_expansion_at() + 2 days);
        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(targetAmount);
    }

    function test_sameBlockExpansionThenUndeployedContractionUsesEarlyExitEconomics() public {
        _createUndeployedBacking();
        _enableContraction();
        uint256 expansionTime = pegKeeper.last_expansion_at();
        uint256 exposureBefore = pegKeeper.deployed_crvusd();

        (,,, bool earlyExit) = contraction.previewUndeployedContraction(1_000e6);
        assertTrue(earlyExit);
        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(1_000e6);

        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertLt(pegKeeper.deployed_crvusd(), exposureBefore);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_sameBlockUndeployedContractionThenExpansionCannotCreateBacking() public {
        _createUndeployedBacking();
        _enableContraction();
        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(10_000e6);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertGt(crvUsd.balanceOf(address(pegKeeper)), EXPANSION_AMOUNT);

        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(pegKeeper.deployed_crvusd(), EXPANSION_AMOUNT);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
        assertEq(crvUsd.allowance(address(pegKeeper), address(pool)), 0);
    }

    function test_minimumExpansionResetsMaturePositionToEarlyExitEconomics() public {
        _createUndeployedBacking();
        _enableContraction();
        pool.setReversePrices(1_002_000, 1_002_000);
        uint256 targetAmount = 1_000e6;
        uint256 matureAt = pegKeeper.last_expansion_at() + 2 days;

        vm.warp(matureAt);
        (,,, bool earlyBeforeReset) = contraction.previewUndeployedContraction(targetAmount);
        assertFalse(earlyBeforeReset);

        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        uint256 resetAt = pegKeeper.last_expansion_at();
        assertEq(resetAt, matureAt);

        (,,, bool earlyAfterReset) = contraction.previewUndeployedContraction(targetAmount);
        assertTrue(earlyAfterReset);
        vm.prank(contractionKeeper);
        vm.expectRevert();
        contraction.contractUndeployedBacking(targetAmount);

        vm.warp(resetAt + 2 days);
        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(targetAmount);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_contractionEnforcesReverseTargetAmmQuoteFloor() public {
        _createUndeployedBacking();
        _enableContraction();
        pool.setReversePrices(1_010_000, 1_009_000);

        vm.prank(contractionKeeper);
        vm.expectRevert("slippage");
        contraction.contractUndeployedBacking(1_000e6);
    }

    function test_contractionCannotSpendUnaccountedTargetDonation() public {
        _createUndeployedBacking();
        _enableContraction();
        uint256 accounted = pegKeeper.undeployed_backing();
        targetAsset.mint(address(pegKeeper), 1_000e6);

        vm.prank(contractionKeeper);
        vm.expectRevert();
        contraction.contractUndeployedBacking(accounted + 1);
    }

    function test_fullContractionCapsExposureReductionAtCurrentDeployedAmount() public {
        _createUndeployedBacking();
        _enableContraction();
        uint256 targetAmount = pegKeeper.undeployed_backing();
        (uint256 expectedOut,, uint256 expectedReward) = _expected(targetAmount);

        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(targetAmount);

        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), expectedOut - expectedReward);
    }

    function testFuzz_contractionPreservesPrincipalAcrossAmountsAndProfitableSpreads(
        uint256 targetAmount,
        uint256 spreadPpm
    ) public {
        _createUndeployedBacking();
        _enableContraction();
        targetAmount = bound(targetAmount, 100e6, pegKeeper.undeployed_backing());
        spreadPpm = bound(spreadPpm, 8_000, 50_000);
        pool.setReversePrices(1_000_000 + spreadPpm, 1_000_000 + spreadPpm);
        uint256 backingBefore = pegKeeper.undeployed_backing();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        (uint256 expectedOut,, uint256 expectedReward) = _expected(targetAmount);
        uint256 expectedNet = expectedOut - expectedReward;

        vm.prank(contractionKeeper);
        contraction.contractUndeployedBacking(targetAmount);

        assertEq(pegKeeper.undeployed_backing(), backingBefore - targetAmount);
        assertEq(
            pegKeeper.deployed_crvusd(),
            expectedNet < deployedBefore ? deployedBefore - expectedNet : 0
        );
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_contractionRequiresEnabledDirection() public {
        _createUndeployedBacking();

        vm.prank(contractionKeeper);
        vm.expectRevert();
        contraction.contractUndeployedBacking(1_000e6);
    }

    function _createUndeployedBacking() internal {
        vm.warp(1_800_000_000);
        crvUsd.mint(address(pegKeeper), EXPANSION_AMOUNT);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
        vm.prank(expansionKeeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _enableContraction() internal {
        vm.prank(governance);
        pegKeeper.set_direction_paused(3, false);
    }

    function _expected(uint256 targetAmount)
        internal
        view
        returns (uint256 expectedOut, uint256 grossProfit, uint256 reward)
    {
        expectedOut = pool.get_dy(0, 1, targetAmount);
        grossProfit = expectedOut - targetAmount * TARGET_MULTIPLIER;
        reward = grossProfit * 3_000 / 10_000;
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        deployedPegKeeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(pool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            MAX_DEPLOYED,
            1
        );
    }
}
