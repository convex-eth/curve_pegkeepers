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
import {
    ExecutionDaiUsds,
    ExecutionRoutePool,
    ExecutionYieldToken
} from "./PegKeeperV3BackingDeployment.t.sol";

interface IExpansionPathAttempt {
    function executeExpansionPath(uint256 targetAmount, uint256 crvUsdSold, address keeper)
        external
        returns (
            uint256 backingAssetReceived,
            uint256 yieldTokenReceived,
            uint256 grossProfit,
            uint256 keeperReward
        );
}

contract YieldDonatingDaiUsds {
    ExpansionToken public immutable daiToken;
    ExpansionToken public immutable backingToken;
    ExecutionYieldToken public immutable yieldToken;
    uint256 public immutable donation;

    constructor(
        ExpansionToken dai_,
        ExpansionToken backingToken_,
        ExecutionYieldToken yieldToken_,
        uint256 donation_
    ) {
        daiToken = dai_;
        backingToken = backingToken_;
        yieldToken = yieldToken_;
        donation = donation_;
    }

    function dai() external view returns (address) {
        return address(daiToken);
    }

    function usds() external view returns (address) {
        return address(backingToken);
    }

    function daiToUsds(address receiver, uint256 amount) external {
        require(daiToken.transferFrom(msg.sender, address(this), amount), "transfer");
        backingToken.mint(receiver, amount);
        yieldToken.mint(receiver, donation);
    }

    function usdsToDai(address receiver, uint256 amount) external {
        require(backingToken.transferFrom(msg.sender, address(this), amount), "transfer");
        daiToken.mint(receiver, amount);
        yieldToken.mint(receiver, donation);
    }
}

contract GasBurningRoutePool {
    address public immutable coin0;
    address public immutable coin1;

    constructor(address coin0_, address coin1_) {
        coin0 = coin0_;
        coin1 = coin1_;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return coin0;
        require(index == 1, "coin index");
        return coin1;
    }

    function get_dy(int128, int128, uint256 amount) external pure returns (uint256) {
        return amount * 1e12;
    }

    function exchange(int128, int128, uint256, uint256) external pure {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }
}

contract PegKeeperV3DownstreamExpansionTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant MIN_EXPANSION = 10_000e18;
    uint256 internal constant TARGET_MULTIPLIER = 1e12;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant MIN_ORACLE_PRICE = 999_700_000_000_000_000;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExecutionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExecutionRoutePool internal targetToDaiPool;
    ExecutionRoutePool internal backingToCrvUsdPool;
    ExecutionDaiUsds internal daiUsds;
    ExpansionOracle internal targetOracle;
    ExpansionOracle internal yieldOracle;
    IPegKeeperV3 internal pegKeeper;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        dai = new ExpansionToken(18);
        yieldToken = new ExecutionYieldToken(backingAsset);
        factory = new ExpansionFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        targetPool = new ExpansionPool(crvUsd, targetAsset);
        targetToDaiPool = new ExecutionRoutePool(targetAsset, dai);
        backingToCrvUsdPool = new ExecutionRoutePool(backingAsset, crvUsd);
        daiUsds = new ExecutionDaiUsds(dai, backingAsset);
        targetOracle = new ExpansionOracle();
        yieldOracle = new ExpansionOracle();
        pegKeeper = _deploy();

        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
        vm.startPrank(governance);
        pegKeeper.setPaths(_expansionPath(), 100, _contractionPath());
        pegKeeper.set_expansion_config(0, 1_000_000, 250_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function test_targetOracleHaircutPreservesPreviewExecutionBranchParity() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        targetOracle.setPrice(MIN_ORACLE_PRICE);
        targetPool.setPrices(1_020_000, 1_020_000);
        targetToDaiPool.setPrices(989_900, 989_900);

        (,,,,, bool expectedToDeploy) = pegKeeper.previewExpansion(MIN_EXPANSION);
        assertTrue(expectedToDeploy);

        vm.prank(keeper);
        (, uint256 retained, uint256 yieldReceived,, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);
        assertTrue(deployed);
        assertEq(retained, 0);
        assertGt(yieldReceived, 0);
    }

    function test_yieldOracleDepegFallsBackToHealthyTarget() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        yieldOracle.setPrice(MIN_ORACLE_PRICE - 1);

        (uint256 targetOut, uint256 backingOut,,,, bool expectedToDeploy) =
            pegKeeper.previewExpansion(MIN_EXPANSION);
        assertGt(targetOut, 0);
        assertEq(backingOut, 0);
        assertFalse(expectedToDeploy);

        vm.prank(keeper);
        (, uint256 retained, uint256 yieldReceived,, bool deployedToYield) =
            pegKeeper.expand(MIN_EXPANSION);
        assertGt(retained, 0);
        assertEq(yieldReceived, 0);
        assertFalse(deployedToYield);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
    }

    function test_yieldOracleFailureFallsBackToHealthyTarget() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        yieldOracle.setShouldRevert(true);

        (,,,,, bool expectedToDeploy) = pegKeeper.previewExpansion(MIN_EXPANSION);
        assertFalse(expectedToDeploy);

        vm.prank(keeper);
        (,, uint256 yieldReceived,, bool deployedToYield) = pegKeeper.expand(MIN_EXPANSION);
        assertEq(yieldReceived, 0);
        assertFalse(deployedToYield);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
    }

    function test_previewExpansionPredictsConfiguredDownstreamRoute() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        IPegKeeperV3 previewer = IPegKeeperV3(address(pegKeeper));

        uint256 targetReceived = targetPool.get_dy(1, 0, MIN_EXPANSION);
        uint256 backingReceived = targetReceived * TARGET_MULTIPLIER;
        uint256 grossProfit = backingReceived - MIN_EXPANSION;
        uint256 expectedReward = grossProfit * 3_000 / 10_000;
        uint256 expectedYield = backingReceived - expectedReward;

        (
            uint256 targetOut,
            uint256 backingOut,
            uint256 previewGrossProfit,
            uint256 keeperReward,
            uint256 yieldOut,
            bool expectedToDeploy
        ) = previewer.previewExpansion(MIN_EXPANSION);

        assertEq(targetOut, targetReceived);
        assertEq(backingOut, backingReceived);
        assertEq(previewGrossProfit, grossProfit);
        assertEq(keeperReward, expectedReward);
        assertEq(yieldOut, expectedYield);
        assertTrue(expectedToDeploy);
    }

    function test_previewExpansionRejectsGloballyInsolventPostActionBacking() public {
        crvUsd.mint(address(pegKeeper), 2 * MIN_EXPANSION);

        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);

        vm.expectRevert();
        pegKeeper.previewExpansion(MIN_EXPANSION);

        vm.expectRevert();
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
    }

    function test_previewExpansionIsAdvisoryWhenRouteQuoteChanges() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        IPegKeeperV3 previewer = IPegKeeperV3(address(pegKeeper));

        (,,,,, bool expectedToDeploy) = previewer.previewExpansion(MIN_EXPANSION);
        assertTrue(expectedToDeploy);

        targetToDaiPool.setPrices(900_000, 900_000);
        vm.prank(keeper);
        (,, uint256 yieldReceived,, bool deployed) = pegKeeper.expand(MIN_EXPANSION);

        assertEq(yieldReceived, 0);
        assertFalse(deployed);
        assertGt(pegKeeper.undeployed_backing(), 0);
    }

    function test_previewExpansionSelectsFallbackWhenQuotedRouteLossIsTooHigh() public {
        targetPool.setPrices(1_100_000, 1_100_000);
        targetToDaiPool.setPrices(950_000, 950_000);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        uint256 expectedTarget = targetPool.get_dy(1, 0, MIN_EXPANSION);
        uint256 expectedGrossProfit = expectedTarget * TARGET_MULTIPLIER - MIN_EXPANSION;
        uint256 expectedReward = expectedGrossProfit * 3_000 / 10_000 / TARGET_MULTIPLIER;
        (
            uint256 targetOut,
            uint256 backingOut,
            uint256 grossProfit,
            uint256 keeperReward,
            uint256 yieldOut,
            bool expectedToDeploy
        ) = pegKeeper.previewExpansion(MIN_EXPANSION);

        assertEq(targetOut, expectedTarget);
        assertEq(backingOut, 0);
        assertEq(grossProfit, expectedGrossProfit);
        assertEq(keeperReward, expectedReward);
        assertEq(yieldOut, 0);
        assertFalse(expectedToDeploy);

        vm.prank(keeper);
        (, uint256 retained,, uint256 realizedReward, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);
        assertEq(retained + realizedReward, targetOut);
        assertEq(realizedReward, keeperReward);
        assertFalse(deployed);
    }

    function test_expansionRoutesNewTargetToYieldAndPaysOneBackingReward() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        vm.warp(1_800_000_000);

        uint256 targetReceived = targetPool.get_dy(1, 0, MIN_EXPANSION);
        uint256 backingReceived = targetReceived * TARGET_MULTIPLIER;
        uint256 grossProfit = backingReceived - MIN_EXPANSION;
        uint256 expectedReward = grossProfit * 3_000 / 10_000;
        uint256 expectedYield = backingReceived - expectedReward;

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.Expanded(
            keeper,
            MIN_EXPANSION,
            targetReceived,
            backingReceived,
            expectedYield,
            grossProfit,
            expectedReward,
            0,
            true,
            block.timestamp + 2 days
        );
        vm.prank(keeper);
        (
            uint256 sold,
            uint256 backingRetained,
            uint256 yieldReceived,
            uint256 reward,
            bool deployedToYield
        ) = pegKeeper.expand(MIN_EXPANSION);

        assertEq(sold, MIN_EXPANSION);
        assertEq(backingRetained, 0);
        assertEq(yieldReceived, expectedYield);
        assertEq(reward, expectedReward);
        assertTrue(deployedToYield);
        assertEq(backingAsset.balanceOf(keeper), expectedReward);
        assertEq(pegKeeper.accounted_yield_token_units(), expectedYield);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
        assertEq(pegKeeper.last_expansion_at(), block.timestamp);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(dai.balanceOf(address(pegKeeper)), 0);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), expectedYield);
        assertEq(targetAsset.allowance(address(pegKeeper), address(targetToDaiPool)), 0);
        assertEq(dai.allowance(address(pegKeeper), address(daiUsds)), 0);
        assertEq(backingAsset.allowance(address(pegKeeper), address(yieldToken)), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_failedIntermediateRouteRollsBackAttemptAndSettlesFallback() public {
        daiUsds.setOutputPpm(999_999);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        (uint256 expectedTarget, uint256 expectedReward, uint256 expectedRetained) =
            _fallbackAmounts(MIN_EXPANSION);
        vm.prank(keeper);
        (uint256 sold, uint256 retained, uint256 yieldReceived, uint256 reward, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);

        assertEq(sold, MIN_EXPANSION);
        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployed);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), expectedRetained);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(dai.balanceOf(address(pegKeeper)), 0);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(expectedTarget, expectedRetained + expectedReward);
    }

    function test_failedFinalYieldFloorRollsBackAttemptAndSettlesFallback() public {
        yieldToken.setRates(1_000_000, 1_000_000, 900_000);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        (, uint256 expectedReward, uint256 expectedRetained) = _fallbackAmounts(MIN_EXPANSION);
        vm.prank(keeper);
        (, uint256 retained, uint256 yieldReceived, uint256 reward, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);

        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployed);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(backingAsset.balanceOf(keeper), 0);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), 0);
    }

    function test_routeLossAboveConfiguredMaximumSelectsFallbackEvenWhenPrincipalPasses() public {
        targetPool.setPrices(1_100_000, 1_100_000);
        targetToDaiPool.setPrices(950_000, 950_000);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        (, uint256 expectedReward, uint256 expectedRetained) = _fallbackAmounts(MIN_EXPANSION);
        vm.prank(keeper);
        (, uint256 retained, uint256 yieldReceived, uint256 reward, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);

        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployed);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(backingAsset.balanceOf(keeper), 0);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
    }

    function test_successfulAttemptExcludesAllPreExistingTokenDonations() public {
        uint256 targetDonation = 123e6;
        uint256 daiDonation = 456e18;
        uint256 backingDonation = 789e18;
        uint256 yieldDonation = 321e18;
        targetAsset.mint(address(pegKeeper), targetDonation);
        dai.mint(address(pegKeeper), daiDonation);
        backingAsset.mint(address(pegKeeper), backingDonation);
        yieldToken.mint(address(pegKeeper), yieldDonation);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        uint256 targetReceived = targetPool.get_dy(1, 0, MIN_EXPANSION);
        uint256 backingReceived = targetReceived * TARGET_MULTIPLIER;
        uint256 reward = (backingReceived - MIN_EXPANSION) * 3_000 / 10_000;
        uint256 expectedYield = backingReceived - reward;

        vm.prank(keeper);
        (,, uint256 yieldReceived,, bool deployed) = pegKeeper.expand(MIN_EXPANSION);

        assertTrue(deployed);
        assertEq(yieldReceived, expectedYield);
        assertEq(pegKeeper.accounted_yield_token_units(), expectedYield);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), targetDonation);
        assertEq(dai.balanceOf(address(pegKeeper)), daiDonation);
        assertEq(backingAsset.balanceOf(address(pegKeeper)), backingDonation);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), yieldDonation + expectedYield);
        assertEq(pegKeeper.trusted_backing_value(), expectedYield);
    }

    function test_newExpansionDoesNotCombineExistingUndeployedBacking() public {
        daiUsds.setOutputPpm(999_999);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        uint256 undeployedBefore = pegKeeper.undeployed_backing();

        daiUsds.setOutputPpm(1_000_000);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        vm.prank(keeper);
        (,, uint256 yieldReceived,, bool deployed) = pegKeeper.expand(MIN_EXPANSION);

        assertTrue(deployed);
        assertGt(yieldReceived, 0);
        assertEq(pegKeeper.undeployed_backing(), undeployedBefore);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), undeployedBefore);
    }

    function test_insufficientGasForAttemptRevertsEntireExpansionInsteadOfSelectingFallback()
        public
    {
        vm.prank(governance);
        pegKeeper.set_expansion_config(0, type(uint256).max, 250_000);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);

        assertEq(crvUsd.balanceOf(address(pegKeeper)), MIN_EXPANSION);
        assertEq(crvUsd.balanceOf(address(targetPool)), 0);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.undeployed_backing(), 0);
    }

    function test_forwardedGasExhaustionStillLeavesEnoughGasForFallbackSettlement() public {
        GasBurningRoutePool burner = new GasBurningRoutePool(address(targetAsset), address(dai));
        IPegKeeperV3.RouteStep[] memory path = _expansionPath();
        path[0].venue = address(burner);
        vm.startPrank(governance);
        pegKeeper.setPaths(path, 100, _contractionPath());
        pegKeeper.set_expansion_config(0, 1_000_000, 500_000);
        vm.stopPrank();
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(keeper);
        (bool success, bytes memory result) = address(pegKeeper).call{gas: 2_000_000}(
            abi.encodeCall(IPegKeeperV3.expand, (MIN_EXPANSION))
        );

        assertTrue(success);
        (uint256 sold, uint256 retained, uint256 yieldReceived, uint256 reward, bool deployed) =
            abi.decode(result, (uint256, uint256, uint256, uint256, bool));
        (, uint256 expectedReward, uint256 expectedRetained) = _fallbackAmounts(MIN_EXPANSION);
        assertEq(sold, MIN_EXPANSION);
        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployed);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
    }

    function test_successfulSubcallWithInconsistentOuterYieldDeltaRevertsEntireExpansion() public {
        uint256 donation = 7e18;
        YieldDonatingDaiUsds donatingConverter =
            new YieldDonatingDaiUsds(dai, backingAsset, yieldToken, donation);
        IPegKeeperV3.RouteStep[] memory path = _expansionPath();
        path[1].venue = address(donatingConverter);
        vm.prank(governance);
        pegKeeper.setPaths(path, 100, _contractionPath());
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);

        assertEq(crvUsd.balanceOf(address(pegKeeper)), MIN_EXPANSION);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(yieldToken.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
    }

    function test_externalCallerCannotInvokeExpansionPathAttempt() public {
        vm.prank(keeper);
        vm.expectRevert();
        IExpansionPathAttempt(address(pegKeeper)).executeExpansionPath(1, 1, keeper);
    }

    function _fallbackAmounts(uint256 amount)
        internal
        view
        returns (uint256 targetReceived, uint256 reward, uint256 retained)
    {
        targetReceived = targetPool.get_dy(1, 0, amount);
        uint256 grossProfit = targetReceived * TARGET_MULTIPLIER - amount;
        reward = grossProfit * 3_000 / 10_000 / TARGET_MULTIPLIER;
        retained = targetReceived - reward;
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
        path[2] = _vaultStep(ERC4626_DEPOSIT, address(backingAsset), address(yieldToken));
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = _vaultStep(ERC4626_REDEEM, address(yieldToken), address(backingAsset));
        path[1] = _curveStep(
            address(backingToCrvUsdPool), address(backingAsset), address(crvUsd), 0, 1, 5
        );
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 indexIn,
        int128 indexOut,
        uint256 bufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: indexIn,
            poolIndexOut: indexOut,
            executionBufferBps: bufferBps
        });
    }

    function _vaultStep(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: kind == ERC4626_DEPOSIT ? tokenOut : tokenIn,
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
            1,
            address(targetOracle),
            address(yieldOracle)
        );
    }
}
