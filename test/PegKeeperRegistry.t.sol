// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPegKeeperRegistry} from "../src/interfaces/IPegKeeperRegistry.sol";

contract RegistryKeeperMock {}

contract PegKeeperRegistryTest is Test {
    uint256 internal constant ADMIN_ACTIONS_DELAY = 3 days;

    IPegKeeperRegistry internal registry;

    function setUp() public {
        registry =
            IPegKeeperRegistry(vm.deployCode("PegKeeperRegistry.vy", abi.encode(address(this))));
    }

    function test_registryUsesPopAndSwapAndSupportsReadding() public {
        address first = address(new RegistryKeeperMock());
        address second = address(new RegistryKeeperMock());
        address[] memory keepers = new address[](2);
        keepers[0] = first;
        keepers[1] = second;
        registry.add_peg_keepers(keepers);

        assertEq(registry.peg_keeper_count(), 2);
        assertEq(registry.peg_keepers(0), first);
        assertEq(registry.peg_keepers(1), second);
        assertTrue(registry.is_active(first));
        assertTrue(registry.is_active(second));

        address[] memory removed = new address[](1);
        removed[0] = first;
        registry.remove_peg_keepers(removed);
        assertEq(registry.peg_keeper_count(), 1);
        assertEq(registry.peg_keepers(0), second);
        assertFalse(registry.is_active(first));
        assertTrue(registry.is_active(second));

        registry.add_peg_keepers(removed);
        assertEq(registry.peg_keeper_count(), 2);
        assertEq(registry.peg_keepers(1), first);
        assertTrue(registry.is_active(first));
    }

    function test_registryRejectsDuplicateMissingAndNonContractKeepers() public {
        address keeper = address(new RegistryKeeperMock());
        address[] memory one = new address[](1);
        one[0] = keeper;
        registry.add_peg_keepers(one);

        vm.expectRevert(IPegKeeperRegistry.DuplicateKeeper.selector);
        registry.add_peg_keepers(one);

        one[0] = address(new RegistryKeeperMock());
        vm.expectRevert(IPegKeeperRegistry.InvalidKeeper.selector);
        registry.remove_peg_keepers(one);

        one[0] = address(0);
        vm.expectRevert(IPegKeeperRegistry.InvalidKeeper.selector);
        registry.add_peg_keepers(one);

        one[0] = makeAddr("no code");
        vm.expectRevert(IPegKeeperRegistry.InvalidKeeper.selector);
        registry.add_peg_keepers(one);
    }

    function test_registryIsBoundedToThirtyTwoAndThirtyThirdAdditionRollsBack() public {
        address[] memory keepers = new address[](32);
        for (uint256 i; i < keepers.length; ++i) {
            keepers[i] = address(new RegistryKeeperMock());
        }
        registry.add_peg_keepers(keepers);
        assertEq(registry.peg_keeper_count(), 32);

        address thirtyThird = address(new RegistryKeeperMock());
        address[] memory one = new address[](1);
        one[0] = thirtyThird;
        vm.expectRevert();
        registry.add_peg_keepers(one);
        assertEq(registry.peg_keeper_count(), 32);
        assertFalse(registry.is_active(thirtyThird));
    }

    function test_onlyAdminCanMutateRegistry() public {
        address[] memory one = new address[](1);
        one[0] = address(new RegistryKeeperMock());

        vm.startPrank(makeAddr("not admin"));
        vm.expectRevert();
        registry.add_peg_keepers(one);
        vm.expectRevert();
        registry.remove_peg_keepers(one);
        vm.stopPrank();
    }

    function test_curveAdminCommitCanBeOverwrittenAndLegacyOwnershipSelectorsAreAbsent() public {
        address firstAdmin = makeAddr("firstAdmin");
        address correctedAdmin = makeAddr("correctedAdmin");

        registry.commit_new_admin(firstAdmin);
        uint256 firstDeadline = registry.new_admin_deadline();
        vm.warp(block.timestamp + 1 days);
        registry.commit_new_admin(correctedAdmin);
        assertEq(registry.future_admin(), correctedAdmin);
        assertGt(registry.new_admin_deadline(), firstDeadline);

        vm.expectRevert();
        registry.commit_new_admin(address(0));

        (bool transferOwnershipExists,) = address(registry)
            .call(abi.encodeWithSignature("transferOwnership(address)", correctedAdmin));
        assertFalse(transferOwnershipExists);
        (bool acceptOwnershipExists,) =
            address(registry).call(abi.encodeWithSignature("acceptOwnership(uint256)", 1));
        assertFalse(acceptOwnershipExists);
        (bool ownerGetterExists,) = address(registry).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerGetterExists);
        (bool pendingOwnerGetterExists,) =
            address(registry).staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertFalse(pendingOwnerGetterExists);
        (bool ownershipNonceGetterExists,) =
            address(registry).staticcall(abi.encodeWithSignature("ownershipTransferNonce()"));
        assertFalse(ownershipNonceGetterExists);
    }

    function test_curveAdminTransferKeepsCurrentAdminActiveDuringDelay() public {
        address nextAdmin = makeAddr("nextAdmin");
        uint256 committedAt = block.timestamp;
        registry.commit_new_admin(nextAdmin);

        assertEq(registry.admin(), address(this));
        assertEq(registry.future_admin(), nextAdmin);
        assertEq(registry.new_admin_deadline(), committedAt + ADMIN_ACTIONS_DELAY);

        address[] memory one = new address[](1);
        one[0] = address(new RegistryKeeperMock());
        registry.add_peg_keepers(one);
        assertTrue(registry.is_active(one[0]));

        vm.prank(nextAdmin);
        vm.expectRevert();
        registry.apply_new_admin();
        vm.warp(registry.new_admin_deadline());
        vm.prank(makeAddr("wrongAdmin"));
        vm.expectRevert();
        registry.apply_new_admin();
        vm.prank(nextAdmin);
        registry.apply_new_admin();

        assertEq(registry.admin(), nextAdmin);
        assertEq(registry.future_admin(), nextAdmin);
        assertEq(registry.new_admin_deadline(), 0);

        address[] memory second = new address[](1);
        second[0] = address(new RegistryKeeperMock());
        vm.expectRevert();
        registry.add_peg_keepers(second);
        vm.prank(nextAdmin);
        registry.add_peg_keepers(second);
        assertTrue(registry.is_active(second[0]));
    }
}
