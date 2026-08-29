// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract ExpansionToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract ExpansionYieldToken is ExpansionToken {
    address public immutable asset;

    constructor(address asset_) ExpansionToken(18) {
        asset = asset_;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }
}

contract ExpansionFactory {
    address public immutable stablecoin;
    mapping(address => uint256) public debt_ceiling;

    constructor(address stablecoin_) {
        stablecoin = stablecoin_;
    }

    function setDebtCeiling(address account, uint256 amount) external {
        debt_ceiling[account] = amount;
    }
}

contract ExpansionPool {
    uint256 internal constant PPM = 1_000_000;

    ExpansionToken public immutable crvUsd;
    ExpansionToken public immutable targetAsset;
    uint256 public quotePricePpm = 1_000_100;
    uint256 public executionPricePpm = 1_000_100;
    uint256 public reverseQuotePricePpm = 1_010_000;
    uint256 public reverseExecutionPricePpm = 1_010_000;

    constructor(ExpansionToken crvUsd_, ExpansionToken targetAsset_) {
        crvUsd = crvUsd_;
        targetAsset = targetAsset_;
    }

    function coins(uint256 index) external view returns (address) {
        if (index == 0) return address(targetAsset);
        require(index == 1, "coin index");
        return address(crvUsd);
    }

    function setPrices(uint256 quotePricePpm_, uint256 executionPricePpm_) external {
        quotePricePpm = quotePricePpm_;
        executionPricePpm = executionPricePpm_;
    }

    function setReversePrices(uint256 quotePricePpm_, uint256 executionPricePpm_) external {
        reverseQuotePricePpm = quotePricePpm_;
        reverseExecutionPricePpm = executionPricePpm_;
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        if (i == 1 && j == 0) return dx * quotePricePpm / (PPM * 1e12);
        require(i == 0 && j == 1, "indices");
        return dx * reverseQuotePricePpm * 1e12 / PPM;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut)
    {
        if (i == 1 && j == 0) {
            amountOut = dx * executionPricePpm / (PPM * 1e12);
            require(amountOut >= minDy, "slippage");
            require(crvUsd.transferFrom(msg.sender, address(this), dx), "transfer");
            targetAsset.mint(msg.sender, amountOut);
        } else {
            require(i == 0 && j == 1, "indices");
            amountOut = dx * reverseExecutionPricePpm * 1e12 / PPM;
            require(amountOut >= minDy, "slippage");
            require(targetAsset.transferFrom(msg.sender, address(this), dx), "transfer");
            crvUsd.mint(msg.sender, amountOut);
        }
    }
}

contract PegKeeperV3ExpansionTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant MIN_EXPANSION = 10_000e18;
    uint256 internal constant TARGET_MULTIPLIER = 1e12;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal pool;
    IPegKeeperV3 internal pegKeeper;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        yieldToken = new ExpansionYieldToken(address(backingAsset));
        factory = new ExpansionFactory(address(crvUsd));
        pool = new ExpansionPool(crvUsd, targetAsset);
        pegKeeper = _deploy();
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
    }

    function test_adminConfiguresExpansionSafety() public {
        vm.expectEmit(false, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.ExpansionConfigUpdated(2, 500_000, 100_000);
        vm.prank(governance);
        pegKeeper.set_expansion_config(2, 500_000, 100_000);

        assertEq(pegKeeper.target_amm_execution_buffer_bps(), 2);
        assertEq(pegKeeper.min_downstream_attempt_gas(), 500_000);
        assertEq(pegKeeper.fallback_settlement_gas_reserve(), 100_000);
    }

    function test_previewExpansionPredictsFallbackWithoutChangingState() public {
        IPegKeeperV3 previewer = IPegKeeperV3(address(pegKeeper));
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        uint256 expectedTarget = pool.get_dy(1, 0, MIN_EXPANSION);
        uint256 expectedGrossProfit = expectedTarget * 1e12 - MIN_EXPANSION;
        uint256 expectedReward = (expectedGrossProfit * 3_000 / 10_000) / 1e12;
        (
            uint256 targetOut,
            uint256 backingOut,
            uint256 grossProfit,
            uint256 keeperReward,
            uint256 yieldOut,
            bool expectedToDeploy
        ) = previewer.previewExpansion(MIN_EXPANSION);

        assertEq(targetOut, expectedTarget);
        assertEq(backingOut, 0);
        assertEq(grossProfit, expectedGrossProfit);
        assertEq(keeperReward, expectedReward);
        assertEq(yieldOut, 0);
        assertFalse(expectedToDeploy);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.last_expansion_at(), 0);

        _enableExpansion(0);
        vm.prank(keeper);
        (, uint256 retained,, uint256 realizedReward, bool deployed) =
            pegKeeper.expand(MIN_EXPANSION);
        assertEq(retained + realizedReward, targetOut);
        assertEq(realizedReward, keeperReward);
        assertFalse(deployed);
    }

    function test_previewExpansionRejectsTheStateChangingAmountBounds() public {
        IPegKeeperV3 previewer = IPegKeeperV3(address(pegKeeper));

        vm.expectRevert();
        previewer.previewExpansion(MIN_EXPANSION - 1);

        vm.expectRevert();
        previewer.previewExpansion(MIN_EXPANSION);

        crvUsd.mint(address(pegKeeper), MAX_DEPLOYED + 1);
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED + 1);
        vm.expectRevert();
        previewer.previewExpansion(MAX_DEPLOYED + 1);

        factory.setDebtCeiling(address(pegKeeper), MIN_EXPANSION - 1);
        vm.expectRevert();
        previewer.previewExpansion(MIN_EXPANSION);
    }

    function test_rotatedTargetAmmExecutesBothDirectionsWithDiscoveredIndices() public {
        ExpansionPool replacement = new ExpansionPool(crvUsd, targetAsset);
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(governance);
        pegKeeper.set_target_amm(address(replacement), 0);
        _enableExpansion(0);

        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);

        assertEq(crvUsd.balanceOf(address(replacement)), MIN_EXPANSION);
        assertEq(crvUsd.balanceOf(address(pool)), 0);

        vm.prank(governance);
        pegKeeper.set_direction_paused(3, false);
        vm.prank(keeper);
        pegKeeper.contractUndeployedBacking(1_000e6);

        assertEq(targetAsset.balanceOf(address(replacement)), 1_000e6);
        assertEq(targetAsset.balanceOf(address(pool)), 0);
        assertLt(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
    }

    function test_targetAmmRotationAfterExposurePreservesBackingAndUsesOnlyReplacement() public {
        ExpansionPool replacement = new ExpansionPool(crvUsd, targetAsset);
        crvUsd.mint(address(pegKeeper), 2 * MIN_EXPANSION);
        _enableExpansion(0);

        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        uint256 oldPoolCrvUsd = crvUsd.balanceOf(address(pool));
        uint256 backingBeforeRotation = pegKeeper.undeployed_backing();
        uint256 deployedBeforeRotation = pegKeeper.deployed_crvusd();

        vm.prank(governance);
        pegKeeper.set_target_amm(address(replacement), 0);
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);

        assertEq(crvUsd.balanceOf(address(pool)), oldPoolCrvUsd);
        assertEq(crvUsd.balanceOf(address(replacement)), MIN_EXPANSION);
        assertEq(pegKeeper.deployed_crvusd(), deployedBeforeRotation + MIN_EXPANSION);
        assertGt(pegKeeper.undeployed_backing(), backingBeforeRotation);

        vm.prank(governance);
        pegKeeper.set_direction_paused(3, false);
        vm.prank(keeper);
        pegKeeper.contractUndeployedBacking(1_000e6);

        assertEq(targetAsset.balanceOf(address(pool)), 0);
        assertEq(targetAsset.balanceOf(address(replacement)), 1_000e6);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_repeatedSameBlockExpansionsExhaustIdleInventoryWithPerCallRewards() public {
        crvUsd.mint(address(pegKeeper), 10 * MIN_EXPANSION);
        pool.setPrices(1_010_000, 1_010_000);
        _enableExpansion(0);

        _runSplitExpansions(10);

        assertEq(pegKeeper.available_expansion(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 0);
    }

    function test_repeatedSameBlockExpansionsExhaustFactoryAllocation() public {
        crvUsd.mint(address(pegKeeper), 20 * MIN_EXPANSION);
        factory.setDebtCeiling(address(pegKeeper), 10 * MIN_EXPANSION);
        pool.setPrices(1_010_000, 1_010_000);
        _enableExpansion(0);

        _runSplitExpansions(10);

        assertEq(pegKeeper.available_expansion(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 10 * MIN_EXPANSION);
    }

    function test_repeatedSameBlockExpansionsExhaustLocalCapacity() public {
        crvUsd.mint(address(pegKeeper), 20 * MIN_EXPANSION);
        pool.setPrices(1_010_000, 1_010_000);
        vm.prank(governance);
        pegKeeper.set_policy(
            50, 1_000, 5_000, 3_000, 20e18, 2 days, MIN_EXPANSION, 10 * MIN_EXPANSION
        );
        _enableExpansion(0);

        _runSplitExpansions(10);

        assertEq(pegKeeper.available_expansion(), 0);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 10 * MIN_EXPANSION);
    }

    function test_splitMinimumCallsCollectMoreCapsButLeaveLessSurplusThanOneLargeCall() public {
        uint256 totalAmount = 10 * MIN_EXPANSION;
        crvUsd.mint(address(pegKeeper), totalAmount);
        pool.setPrices(1_010_000, 1_010_000);
        _enableExpansion(0);
        vm.warp(1_800_000_000);
        uint256 snapshot = vm.snapshotState();

        vm.prank(keeper);
        (,,, uint256 largeReward,) = pegKeeper.expand(totalAmount);
        uint256 largeSurplus = pegKeeper.protocol_surplus();
        assertEq(largeReward, 20e6);
        assertEq(largeSurplus, 980e18);

        assertTrue(vm.revertToState(snapshot));
        _runSplitExpansions(10);
        uint256 splitReward = targetAsset.balanceOf(keeper);
        uint256 splitSurplus = pegKeeper.protocol_surplus();

        assertEq(splitReward, 200e6);
        assertEq(splitSurplus, 800e18);
        assertGt(splitReward, largeReward);
        assertLt(splitSurplus, largeSurplus);
    }

    function test_availableExpansionUsesIdleFactoryAndConfiguredBounds() public {
        crvUsd.mint(address(pegKeeper), 20_000_000e18);
        factory.setDebtCeiling(address(pegKeeper), 18_000_000e18);

        assertEq(pegKeeper.available_expansion(), 18_000_000e18);
    }

    function test_fallbackExpansionPaysKeeperAndAccountsMeasuredBacking() public {
        uint256 amount = MIN_EXPANSION;
        crvUsd.mint(address(pegKeeper), amount);
        _enableExpansion(0);
        vm.warp(1_800_000_000);

        uint256 expectedTarget = pool.get_dy(1, 0, amount);
        uint256 grossProfit = expectedTarget * TARGET_MULTIPLIER - amount;
        uint256 rewardValue = grossProfit * 3_000 / 10_000;
        uint256 expectedReward = rewardValue / TARGET_MULTIPLIER;
        uint256 expectedRetained = expectedTarget - expectedReward;

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.Expanded(
            keeper,
            amount,
            expectedTarget,
            0,
            0,
            grossProfit,
            expectedReward,
            expectedRetained,
            false,
            block.timestamp + 2 days
        );
        vm.prank(keeper);
        (
            uint256 sold,
            uint256 retained,
            uint256 yieldReceived,
            uint256 reward,
            bool deployedToYield
        ) = pegKeeper.expand(amount);

        assertEq(sold, amount);
        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployedToYield);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), expectedRetained);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.deployed_crvusd(), amount);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(pegKeeper.last_expansion_at(), block.timestamp);
        assertEq(pegKeeper.trusted_backing_value(), expectedRetained * TARGET_MULTIPLIER);
        assertEq(pegKeeper.protocol_surplus(), expectedRetained * TARGET_MULTIPLIER - amount);
        assertEq(crvUsd.allowance(address(pegKeeper), address(pool)), 0);
    }

    function test_expansionExcludesPreExistingTargetDonationFromAccounting() public {
        uint256 amount = MIN_EXPANSION;
        uint256 donation = 1_234e6;
        targetAsset.mint(address(pegKeeper), donation);
        crvUsd.mint(address(pegKeeper), amount);
        _enableExpansion(0);

        uint256 expectedTarget = pool.get_dy(1, 0, amount);
        uint256 grossProfit = expectedTarget * TARGET_MULTIPLIER - amount;
        uint256 expectedReward = grossProfit * 3_000 / 10_000 / TARGET_MULTIPLIER;
        uint256 expectedRetained = expectedTarget - expectedReward;

        vm.prank(keeper);
        pegKeeper.expand(amount);

        assertEq(targetAsset.balanceOf(address(pegKeeper)), donation + expectedRetained);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
        assertEq(pegKeeper.trusted_backing_value(), expectedRetained * TARGET_MULTIPLIER);
    }

    function test_expansionCapsTargetDenominatedReward() public {
        uint256 amount = MIN_EXPANSION;
        crvUsd.mint(address(pegKeeper), amount);
        pool.setPrices(1_010_000, 1_010_000);
        _enableExpansion(0);

        uint256 expectedTarget = pool.get_dy(1, 0, amount);
        uint256 expectedReward = 20e6;

        vm.prank(keeper);
        (,,, uint256 reward,) = pegKeeper.expand(amount);

        assertEq(reward, expectedReward);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(pegKeeper.undeployed_backing(), expectedTarget - expectedReward);
    }

    function test_expansionRoundsTargetRewardDownToNativeUnits() public {
        uint256 amount = MIN_EXPANSION + 1;
        crvUsd.mint(address(pegKeeper), amount);
        _enableExpansion(0);

        uint256 expectedTarget = pool.get_dy(1, 0, amount);
        uint256 grossProfit = expectedTarget * TARGET_MULTIPLIER - amount;
        uint256 expectedRewardValue = grossProfit * 3_000 / 10_000;
        uint256 expectedReward = expectedRewardValue / TARGET_MULTIPLIER;
        assertGt(expectedRewardValue % TARGET_MULTIPLIER, 0);

        vm.prank(keeper);
        (,,, uint256 reward,) = pegKeeper.expand(amount);

        assertEq(reward, expectedReward);
        assertEq(targetAsset.balanceOf(keeper), expectedReward);
        assertEq(pegKeeper.undeployed_backing(), expectedTarget - expectedReward);
    }

    function test_expansionRevertsAndRollsBackWithoutRetainedMargin() public {
        uint256 amount = MIN_EXPANSION;
        crvUsd.mint(address(pegKeeper), amount);
        pool.setPrices(1_000_000, 1_000_000);
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(amount);

        assertEq(crvUsd.balanceOf(address(pegKeeper)), amount);
        assertEq(crvUsd.balanceOf(address(pool)), 0);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(targetAsset.balanceOf(keeper), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.last_expansion_at(), 0);
    }

    function test_expansionEnforcesTargetAmmQuoteFloor() public {
        uint256 amount = MIN_EXPANSION;
        crvUsd.mint(address(pegKeeper), amount);
        pool.setPrices(1_001_000, 1_000_900);
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert("slippage");
        pegKeeper.expand(amount);
    }

    function test_expansionRejectsAmountBelowMinimum() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION - 1);
    }

    function test_expansionRejectsAmountAboveIdleInventory() public {
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
    }

    function test_expansionRejectsAmountAboveFactoryAllocation() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);
        factory.setDebtCeiling(address(pegKeeper), MIN_EXPANSION - 1);
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
    }

    function test_expansionRejectsAmountAboveConfiguredCapacity() public {
        uint256 amount = MAX_DEPLOYED + 1;
        crvUsd.mint(address(pegKeeper), amount);
        factory.setDebtCeiling(address(pegKeeper), amount);
        _enableExpansion(0);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(amount);
    }

    function test_loweringCapacityBelowExposureStopsGrowthWithoutBlockingWindDown() public {
        crvUsd.mint(address(pegKeeper), 2 * MIN_EXPANSION);
        _enableExpansion(0);

        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);

        vm.prank(governance);
        pegKeeper.set_policy(
            50, 1_000, 5_000, 3_000, 20e18, 2 days, MIN_EXPANSION, MIN_EXPANSION - 1
        );
        assertEq(pegKeeper.available_expansion(), 0);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);

        vm.prank(governance);
        pegKeeper.set_direction_paused(3, false);
        vm.prank(keeper);
        pegKeeper.contractUndeployedBacking(1_000e6);

        assertLt(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
    }

    function test_loweringFactoryCeilingBelowExposureBlocksGrowthAndKeepsWindDownOpen() public {
        crvUsd.mint(address(pegKeeper), 2 * MIN_EXPANSION);
        _enableExpansion(0);
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);

        uint256 exposure = pegKeeper.deployed_crvusd();
        factory.setDebtCeiling(address(pegKeeper), exposure - 1);
        crvUsd.mint(address(pegKeeper), 100e18);

        assertEq(pegKeeper.available_expansion(), 0);
        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.claimSurplus(1e18);

        vm.prank(governance);
        pegKeeper.set_direction_paused(3, false);
        vm.prank(keeper);
        pegKeeper.contractUndeployedBacking(1_000e6);

        assertLt(pegKeeper.deployed_crvusd(), exposure);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_expansionRequiresDirectionAndGlobalExecution() public {
        crvUsd.mint(address(pegKeeper), MIN_EXPANSION);

        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
        _assertExpansionDidNotStart();

        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
        _assertExpansionDidNotStart();

        vm.startPrank(governance);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(5, true);
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.expand(MIN_EXPANSION);
        _assertExpansionDidNotStart();

        vm.prank(governance);
        pegKeeper.set_direction_paused(5, false);
        vm.prank(keeper);
        pegKeeper.expand(MIN_EXPANSION);
        assertEq(pegKeeper.deployed_crvusd(), MIN_EXPANSION);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function test_onlyAdminCanConfigureExpansion() public {
        vm.prank(keeper);
        vm.expectRevert();
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
    }

    function test_expansionConfigRejectsInvalidBounds() public {
        vm.startPrank(governance);
        vm.expectRevert();
        pegKeeper.set_expansion_config(10_001, 500_000, 100_000);
        vm.expectRevert();
        pegKeeper.set_expansion_config(0, 100_000, 100_000);
        vm.expectRevert();
        pegKeeper.set_expansion_config(0, 500_000, 0);
        vm.stopPrank();
    }

    function _assertExpansionDidNotStart() internal view {
        assertEq(crvUsd.balanceOf(address(pegKeeper)), MIN_EXPANSION);
        assertEq(crvUsd.balanceOf(address(pool)), 0);
        assertEq(targetAsset.balanceOf(address(pegKeeper)), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.last_expansion_at(), 0);
    }

    function _enableExpansion(uint256 bufferBps) internal {
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(bufferBps, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function _runSplitExpansions(uint256 calls) internal {
        uint256 timestamp = 1_800_000_000;
        vm.warp(timestamp);
        for (uint256 i; i < calls; ++i) {
            vm.prank(keeper);
            (,,, uint256 reward,) = pegKeeper.expand(MIN_EXPANSION);
            assertEq(reward, 20e6);
        }
        assertEq(pegKeeper.deployed_crvusd(), calls * MIN_EXPANSION);
        assertEq(targetAsset.balanceOf(keeper), calls * 20e6);
        assertEq(pegKeeper.last_expansion_at(), timestamp);
        assertEq(pegKeeper.protocol_surplus(), calls * 80e18);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory),
            address(pool),
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
