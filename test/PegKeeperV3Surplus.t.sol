// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {
    ExpansionFactory,
    ExpansionPool,
    ExpansionToken,
    ExpansionYieldToken
} from "./PegKeeperV3Expansion.t.sol";

contract PegKeeperV3SurplusTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");
    address internal caller = makeAddr("surplusCaller");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal pool;
    IPegKeeperV3 internal pegKeeper;
    IPegKeeperV3 internal surplusModule;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        yieldToken = new ExpansionYieldToken(address(backingAsset));
        factory = new ExpansionFactory(address(crvUsd));
        pool = new ExpansionPool(crvUsd, targetAsset);
        pegKeeper = _deploy(MAX_DEPLOYED);
        surplusModule = IPegKeeperV3(address(pegKeeper));
        factory.setDebtCeiling(address(pegKeeper), MAX_DEPLOYED);
    }

    function test_claimSurplusTransfersIdleCrvUsdAndIncreasesExposure() public {
        _createSurplus(pegKeeper);
        uint256 surplusBefore = pegKeeper.protocol_surplus();
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 expansionTime = pegKeeper.last_expansion_at();
        crvUsd.mint(address(pegKeeper), 100e18);

        vm.expectEmit(true, true, false, true, address(pegKeeper));
        emit IPegKeeperV3.SurplusClaimed(
            caller, feeReceiver, surplusBefore, deployedBefore + surplusBefore
        );
        vm.prank(caller);
        uint256 transferred = surplusModule.claimSurplus(type(uint256).max);

        assertEq(transferred, surplusBefore);
        assertEq(crvUsd.balanceOf(feeReceiver), surplusBefore);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 100e18 - surplusBefore);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore + surplusBefore);
        assertEq(pegKeeper.trusted_backing_value(), trustedBefore);
        assertEq(pegKeeper.protocol_surplus(), 0);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
    }

    function test_claimSurplusRespectsCallerMaximum() public {
        _createSurplus(pegKeeper);
        crvUsd.mint(address(pegKeeper), 100e18);
        uint256 callerMaximum = 0.25e18;

        vm.prank(caller);
        uint256 transferred = surplusModule.claimSurplus(callerMaximum);

        assertEq(transferred, callerMaximum);
        assertEq(crvUsd.balanceOf(feeReceiver), callerMaximum);
    }

    function test_claimSurplusUsesCurrentFeeReceiver() public {
        _createSurplus(pegKeeper);
        crvUsd.mint(address(pegKeeper), 100e18);
        address newFeeReceiver = makeAddr("newFeeReceiver");
        vm.prank(governance);
        IPegKeeperV3(address(pegKeeper)).set_fee_receiver(newFeeReceiver);

        vm.prank(caller);
        uint256 transferred = surplusModule.claimSurplus(0.25e18);

        assertEq(transferred, 0.25e18);
        assertEq(crvUsd.balanceOf(feeReceiver), 0);
        assertEq(crvUsd.balanceOf(newFeeReceiver), transferred);
    }

    function test_governanceUpdatesFeeReceiver() public {
        address newFeeReceiver = makeAddr("newFeeReceiver");
        vm.expectEmit(true, true, false, false, address(pegKeeper));
        emit IPegKeeperV3.FeeReceiverUpdated(feeReceiver, newFeeReceiver);

        vm.prank(governance);
        IPegKeeperV3(address(pegKeeper)).set_fee_receiver(newFeeReceiver);

        assertEq(pegKeeper.fee_receiver(), newFeeReceiver);
    }

    function test_nonAdminCannotUpdateFeeReceiver() public {
        vm.prank(caller);
        vm.expectRevert();
        IPegKeeperV3(address(pegKeeper)).set_fee_receiver(makeAddr("newFeeReceiver"));
    }

    function test_feeReceiverCannotBeZero() public {
        vm.prank(governance);
        vm.expectRevert();
        IPegKeeperV3(address(pegKeeper)).set_fee_receiver(address(0));
    }

    function test_claimSurplusRespectsActualIdleInventory() public {
        _createSurplus(pegKeeper);
        uint256 idleInventory = 0.1e18;
        crvUsd.mint(address(pegKeeper), idleInventory);

        vm.prank(caller);
        uint256 transferred = surplusModule.claimSurplus(type(uint256).max);

        assertEq(transferred, idleInventory);
        assertEq(crvUsd.balanceOf(address(pegKeeper)), 0);
    }

    function test_claimSurplusRespectsFactoryAllocationRemainder() public {
        _createSurplus(pegKeeper);
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 allocationRemainder = 0.2e18;
        factory.setDebtCeiling(address(pegKeeper), deployedBefore + allocationRemainder);
        crvUsd.mint(address(pegKeeper), 100e18);

        vm.prank(caller);
        uint256 transferred = surplusModule.claimSurplus(type(uint256).max);

        assertEq(transferred, allocationRemainder);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore + allocationRemainder);
    }

    function test_claimSurplusRespectsLocalExposureRemainder() public {
        uint256 localRemainder = 0.15e18;
        IPegKeeperV3 limitedPegKeeper = _deploy(EXPANSION_AMOUNT + localRemainder);
        factory.setDebtCeiling(address(limitedPegKeeper), MAX_DEPLOYED);
        _createSurplus(limitedPegKeeper);
        crvUsd.mint(address(limitedPegKeeper), 100e18);

        vm.prank(caller);
        uint256 transferred =
            IPegKeeperV3(address(limitedPegKeeper)).claimSurplus(type(uint256).max);

        assertEq(transferred, localRemainder);
        assertEq(limitedPegKeeper.deployed_crvusd(), EXPANSION_AMOUNT + localRemainder);
    }

    function test_crvUsdDonationCannotBypassFactoryAllocation() public {
        _createSurplus(pegKeeper);
        factory.setDebtCeiling(address(pegKeeper), pegKeeper.deployed_crvusd());
        crvUsd.mint(address(pegKeeper), 100e18);

        vm.prank(caller);
        vm.expectRevert();
        surplusModule.claimSurplus(type(uint256).max);
    }

    function test_claimSurplusRejectsZeroTransfer() public {
        _enableExpansion(pegKeeper);
        crvUsd.mint(address(pegKeeper), 100e18);

        vm.prank(caller);
        vm.expectRevert();
        surplusModule.claimSurplus(type(uint256).max);
    }

    function test_claimSurplusRequiresExpansionDirection() public {
        _createSurplus(pegKeeper);
        crvUsd.mint(address(pegKeeper), 100e18);
        vm.prank(governance);
        pegKeeper.set_direction_paused(0, true);

        vm.prank(caller);
        vm.expectRevert();
        surplusModule.claimSurplus(type(uint256).max);
    }

    function test_claimSurplusRequiresGlobalExecution() public {
        _createSurplus(pegKeeper);
        crvUsd.mint(address(pegKeeper), 100e18);
        vm.prank(governance);
        pegKeeper.set_direction_paused(5, true);

        vm.prank(caller);
        vm.expectRevert();
        surplusModule.claimSurplus(type(uint256).max);
    }

    function _createSurplus(IPegKeeperV3 targetPegKeeper) internal {
        crvUsd.mint(address(targetPegKeeper), EXPANSION_AMOUNT);
        _enableExpansion(targetPegKeeper);
        vm.warp(1_800_000_000);
        vm.prank(keeper);
        targetPegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _enableExpansion(IPegKeeperV3 targetPegKeeper) internal {
        vm.startPrank(governance);
        targetPegKeeper.set_expansion_config(0, 500_000, 100_000);
        targetPegKeeper.set_direction_paused(5, false);
        targetPegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function _deploy(uint256 maxDeployed) internal returns (IPegKeeperV3 deployedPegKeeper) {
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
            maxDeployed
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
