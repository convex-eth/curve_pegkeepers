// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    LpYieldToken,
    LpYieldFactory,
    LpYieldTargetAmm,
    LpYieldRoutePool,
    LpYieldAmm,
    LpYieldOracle
} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3LpYieldHandler is Test {
    IPegKeeperV3 public immutable keeper;
    LpYieldToken public immutable crvUsd;
    LpYieldToken public immutable targetAsset;
    LpYieldToken public immutable yieldToken;
    LpYieldAmm public immutable yieldAmm;
    uint256 public successfulExpansions;
    uint256 public successfulDonationSweeps;
    uint256 public successfulContractions;
    uint256 public successfulSurplusClaims;

    constructor(
        IPegKeeperV3 keeper_,
        LpYieldToken crvUsd_,
        LpYieldToken targetAsset_,
        LpYieldToken yieldToken_,
        LpYieldAmm yieldAmm_
    ) {
        keeper = keeper_;
        crvUsd = crvUsd_;
        targetAsset = targetAsset_;
        yieldToken = yieldToken_;
        yieldAmm = yieldAmm_;
    }

    function expand(uint256 seed) external {
        vm.warp(block.timestamp + 300);
        uint256 amount = bound(seed, 10_000e18, 100_000e18);
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.expand, (amount)));
        if (success) successfulExpansions++;
    }

    function donateYield(uint256 seed) external {
        yieldToken.mint(address(keeper), bound(seed, 1, 20_000e18));
    }

    function sweepDonatedYield(uint256 seed) external {
        uint256 held = yieldToken.balanceOf(address(keeper));
        uint256 minimum = keeper.min_expansion_amount();
        if (held < minimum) return;
        vm.warp(block.timestamp + 300);
        uint256 amount = bound(seed, minimum, held);
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.sweepDonatedYield, (amount)));
        if (success) successfulDonationSweeps++;
    }

    function donateLp(uint256 seed) external {
        yieldAmm.mint(address(keeper), bound(seed, 1, 2_000e18));
    }

    function contractLp(uint256 seed) external {
        uint256 held = keeper.accounted_lp_tokens();
        if (held == 0) return;
        uint256 amount = bound(seed, 1, held / 4 + 1);
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.contractViaAmm, (amount)));
        if (success) successfulContractions++;
    }

    function increaseVirtualPrice(uint256 seed) external {
        uint256 current = yieldAmm.virtualPrice();
        uint256 increase = bound(seed, 0, 1e15);
        if (current <= 2e18 - increase) yieldAmm.setVirtualPrice(current + increase);
    }

    function claimSurplus(uint256 seed) external {
        uint256 idle = crvUsd.balanceOf(address(keeper));
        if (idle == 0) return;
        vm.warp(block.timestamp + 300);
        uint256 amount = bound(seed, 1, idle);
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.claimSurplus, (amount)));
        if (success) successfulSurplusClaims++;
    }
}

contract PegKeeperV3LpYieldInvariantTest is StdInvariant, Test {
    IPegKeeperV3 internal keeper;
    LpYieldToken internal crvUsd;
    LpYieldToken internal targetAsset;
    LpYieldToken internal yieldToken;
    LpYieldFactory internal factory;
    LpYieldTargetAmm internal targetAmm;
    LpYieldRoutePool internal routePool;
    LpYieldAmm internal yieldAmm;
    PegKeeperV3LpYieldHandler internal handler;

    address internal constant GOVERNANCE = address(0xA11CE);
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        targetAsset = new LpYieldToken(6);
        yieldToken = new LpYieldToken(18);
        factory = new LpYieldFactory(address(crvUsd), GOVERNANCE, address(0xBEEF), address(0xFEE));
        targetAmm = new LpYieldTargetAmm(crvUsd, targetAsset);
        routePool = new LpYieldRoutePool(targetAsset, yieldToken);
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        yieldAmm.setLpMintBps(10_001);
        LpYieldOracle oracle = new LpYieldOracle();

        keeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetAmm),
            address(targetAsset),
            address(yieldToken),
            address(yieldToken),
            address(yieldAmm),
            MAX_DEPLOYED,
            1,
            address(oracle),
            address(oracle)
        );
        factory.setDebtCeiling(address(keeper), MAX_DEPLOYED);

        IPegKeeperV3.RouteStep[] memory path = new IPegKeeperV3.RouteStep[](1);
        path[0] = IPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(routePool),
            tokenIn: address(targetAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 0
        });
        vm.startPrank(GOVERNANCE);
        keeper.setPaths(path, 100);
        keeper.set_expansion_config(0, 0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(1, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        crvUsd.mint(address(keeper), 20_000_000e18);
        handler = new PegKeeperV3LpYieldHandler(keeper, crvUsd, targetAsset, yieldToken, yieldAmm);
        handler.expand(10_000e18);
        handler.donateYield(10_000e18);
        handler.sweepDonatedYield(10_000e18);
        handler.contractLp(100e18);
        handler.claimSurplus(1e18);
        targetContract(address(handler));
    }

    function invariant_lpBackingAlwaysCoversRecordedExposure() public view {
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function invariant_exposureNeverExceedsLocalOrFactoryCapacity() public view {
        assertLe(keeper.deployed_crvusd(), keeper.max_deployed_crvusd());
        assertLe(keeper.deployed_crvusd(), factory.debt_ceiling(address(keeper)));
    }

    function invariant_routeAndYieldAmmAllowancesAreAlwaysZero() public view {
        assertEq(crvUsd.allowance(address(keeper), address(targetAmm)), 0);
        assertEq(targetAsset.allowance(address(keeper), address(routePool)), 0);
        assertEq(crvUsd.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(yieldToken.allowance(address(keeper), address(yieldAmm)), 0);
    }

    function invariant_noRoutedTargetResidue() public view {
        assertEq(targetAsset.balanceOf(address(keeper)), 0);
    }

    function invariant_handlerReachesEveryEconomicAction() public view {
        assertGt(handler.successfulExpansions(), 0);
        assertGt(handler.successfulDonationSweeps(), 0);
        assertGt(handler.successfulContractions(), 0);
        assertGt(handler.successfulSurplusClaims(), 0);
    }
}
