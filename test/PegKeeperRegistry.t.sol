// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface IPegKeeperRegistryTest {
    error NotOwner();
    error NotPendingOwner();
    error OwnershipHandoffPending();
    error InvalidOwnershipTransferNonce();
    error InvalidOwner();
    error InvalidKeeper();
    error DuplicateKeeper();

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownershipTransferNonce() external view returns (uint256);
    function peg_keeper_count() external view returns (uint256);
    function peg_keepers(uint256 index) external view returns (address);
    function is_active(address pegKeeper) external view returns (bool);
    function add_peg_keepers(address[] calldata pegKeepers) external;
    function remove_peg_keepers(address[] calldata pegKeepers) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership(uint256 expectedNonce) external;
}

contract RegistryKeeperMock {}

contract PegKeeperRegistryTest is Test {
    IPegKeeperRegistryTest internal registry;

    function setUp() public {
        registry = IPegKeeperRegistryTest(
            vm.deployCode("PegKeeperRegistry.vy", abi.encode(address(this)))
        );
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

        vm.expectRevert(IPegKeeperRegistryTest.DuplicateKeeper.selector);
        registry.add_peg_keepers(one);

        one[0] = address(new RegistryKeeperMock());
        vm.expectRevert(IPegKeeperRegistryTest.InvalidKeeper.selector);
        registry.remove_peg_keepers(one);

        one[0] = address(0);
        vm.expectRevert(IPegKeeperRegistryTest.InvalidKeeper.selector);
        registry.add_peg_keepers(one);

        one[0] = makeAddr("no code");
        vm.expectRevert(IPegKeeperRegistryTest.InvalidKeeper.selector);
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

    function test_onlyOwnerCanMutateRegistry() public {
        address[] memory one = new address[](1);
        one[0] = address(new RegistryKeeperMock());

        vm.startPrank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperRegistryTest.NotOwner.selector);
        registry.add_peg_keepers(one);
        vm.expectRevert(IPegKeeperRegistryTest.NotOwner.selector);
        registry.remove_peg_keepers(one);
        vm.stopPrank();
    }

    function test_pendingOwnershipHandoffFreezesRegistryUntilNonceBoundAcceptance() public {
        address nextOwner = makeAddr("nextOwner");
        address correctedOwner = makeAddr("correctedOwner");
        registry.transferOwnership(nextOwner);
        assertEq(registry.ownershipTransferNonce(), 1);

        address[] memory one = new address[](1);
        one[0] = address(new RegistryKeeperMock());
        vm.expectRevert(IPegKeeperRegistryTest.OwnershipHandoffPending.selector);
        registry.add_peg_keepers(one);

        registry.transferOwnership(correctedOwner);
        assertEq(registry.ownershipTransferNonce(), 2);
        vm.prank(nextOwner);
        vm.expectRevert(IPegKeeperRegistryTest.NotPendingOwner.selector);
        registry.acceptOwnership(1);
        vm.prank(correctedOwner);
        vm.expectRevert(IPegKeeperRegistryTest.InvalidOwnershipTransferNonce.selector);
        registry.acceptOwnership(1);
        vm.prank(correctedOwner);
        registry.acceptOwnership(2);
        assertEq(registry.owner(), correctedOwner);
        assertEq(registry.pendingOwner(), address(0));
    }
}
