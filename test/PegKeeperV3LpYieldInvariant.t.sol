// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {LpYieldToken, LpYieldFactory, LpYieldAmm, LpYieldOracle} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3LpYieldHandler is Test {
    IPegKeeperV3 public immutable keeper;
    LpYieldToken public immutable crvUsd;
    LpYieldToken public immutable yieldToken;
    LpYieldAmm public immutable yieldAmm;
    uint256 public successfulExpansions;
    uint256 public successfulDonationSweeps;
    uint256 public successfulContractions;
    uint256 public successfulProfitWithdrawals;

    constructor(
        IPegKeeperV3 keeper_,
        LpYieldToken crvUsd_,
        LpYieldToken yieldToken_,
        LpYieldAmm yieldAmm_
    ) {
        keeper = keeper_;
        crvUsd = crvUsd_;
        yieldToken = yieldToken_;
        yieldAmm = yieldAmm_;
    }

    function expandSupply(uint256 seed) external {
        yieldAmm.setBalances(0, bound(seed, 1, 100_000_000e18));
        vm.warp(block.timestamp + keeper.expansion_refill_period());
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.expand_supply, ()));
        if (success) successfulExpansions++;
    }

    function donateYield(uint256 seed) external {
        yieldToken.mint(address(keeper), bound(seed, 1, 20_000e18));
    }

    function sweep_donated_paired_token(uint256 seed) external {
        uint256 held = yieldToken.balanceOf(address(keeper));
        if (held == 0) return;
        yieldAmm.setBalances(0, 100_000_000e18);
        vm.warp(block.timestamp + keeper.expansion_refill_period());
        uint256 amount = bound(seed, 1, held);
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.sweep_donated_paired_token, (amount)));
        if (success) successfulDonationSweeps++;
    }

    function donateLp(uint256 seed) external {
        yieldAmm.mint(address(keeper), bound(seed, 1, 2_000e18));
    }

    function contractLp(uint256 seed) external {
        uint256 held = keeper.accounted_lp_tokens();
        if (held == 0) return;
        yieldAmm.setBalances(bound(seed, 1, 100_000_000e18), 0);
        vm.warp(block.timestamp + keeper.min_intervention_delay());
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.contract_supply, ()));
        if (success) successfulContractions++;
    }

    function increaseVirtualPrice(uint256 seed) external {
        uint256 current = yieldAmm.virtualPrice();
        uint256 increase = bound(seed, 0, 1e15);
        if (current <= 2e18 - increase) yieldAmm.setVirtualPrice(current + increase);
    }

    function withdrawProfit(uint256 seed) external {
        uint256 idle = crvUsd.balanceOf(address(keeper));
        if (idle == 0) return;
        vm.warp(block.timestamp + keeper.expansion_refill_period());
        uint256 amount = bound(seed, 1, idle);
        (bool success,) = address(keeper)
            .call(abi.encodeWithSelector(bytes4(keccak256("withdraw_profit(uint256)")), amount));
        if (success) successfulProfitWithdrawals++;
    }
}

contract PegKeeperV3LpYieldInvariantTest is StdInvariant, Test {
    IPegKeeperV3 internal keeper;
    LpYieldToken internal crvUsd;
    LpYieldToken internal yieldToken;
    LpYieldFactory internal factory;
    LpYieldAmm internal yieldAmm;
    PegKeeperV3LpYieldHandler internal handler;

    address internal constant GOVERNANCE = address(0xA11CE);
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        yieldToken = new LpYieldToken(18);
        LpYieldOracle oracle = new LpYieldOracle();
        factory = new LpYieldFactory(
            address(crvUsd), GOVERNANCE, address(0xBEEF), address(0xFEE), address(oracle)
        );
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        yieldAmm.setLpMintBps(10_001);
        keeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(yieldToken),
            address(yieldToken),
            address(yieldAmm),
            MAX_DEPLOYED,
            1,
            address(oracle)
        );
        factory.setDebtCeiling(address(keeper), MAX_DEPLOYED);

        vm.startPrank(GOVERNANCE);
        keeper.set_amm_execution_buffer(0);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(1, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        crvUsd.mint(address(keeper), 20_000_000e18);
        handler = new PegKeeperV3LpYieldHandler(keeper, crvUsd, yieldToken, yieldAmm);
        handler.expandSupply(10_000e18);
        handler.donateYield(10_000e18);
        handler.sweep_donated_paired_token(10_000e18);
        handler.contractLp(100e18);
        handler.withdrawProfit(1e18);
        targetContract(address(handler));
    }

    function invariant_lpBackingAlwaysCoversRecordedExposure() public view {
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function invariant_exposureNeverExceedsLocalOrFactoryCapacity() public view {
        assertLe(keeper.deployed_crvusd(), keeper.max_deployed_crvusd());
        assertLe(keeper.deployed_crvusd(), factory.debt_ceiling(address(keeper)));
    }

    function invariant_ammAllowancesAreAlwaysZero() public view {
        assertEq(crvUsd.allowance(address(keeper), address(yieldAmm)), 0);
        assertEq(yieldToken.allowance(address(keeper), address(yieldAmm)), 0);
    }

    function invariant_handlerReachesEveryEconomicAction() public view {
        assertGt(handler.successfulExpansions(), 0);
        assertGt(handler.successfulDonationSweeps(), 0);
        assertGt(handler.successfulContractions(), 0);
        assertGt(handler.successfulProfitWithdrawals(), 0);
    }
}
