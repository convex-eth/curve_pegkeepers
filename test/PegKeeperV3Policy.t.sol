// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {
    MockFactory,
    MockToken,
    MockTwoCoinPool,
    MockYieldToken
} from "./PegKeeperV3Foundation.t.sol";

interface IPegKeeperV3Policy is IPegKeeperV3 {}

contract PegKeeperV3PolicyTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    MockToken internal crvUsd;
    MockToken internal targetAsset;
    MockToken internal backingAsset;
    MockYieldToken internal yieldToken;
    MockFactory internal factory;
    MockTwoCoinPool internal targetAmm;
    IPegKeeperV3Policy internal pegKeeper;

    function setUp() public {
        crvUsd = new MockToken(18);
        targetAsset = new MockToken(6);
        backingAsset = new MockToken(18);
        yieldToken = new MockYieldToken(address(backingAsset));
        factory = new MockFactory(address(crvUsd), governance);
        targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));
        pegKeeper = _deploy();
    }

    function test_adminAtomicallyUpdatesPolicy() public {
        vm.expectEmit(false, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.PolicyUpdated(25, 750, 7_500, 2_500, 3 days, 50_000e18, 10_000_000e18);

        vm.prank(governance);
        pegKeeper.set_policy(25, 750, 7_500, 2_500, 3 days, 50_000e18, 10_000_000e18);

        assertEq(pegKeeper.entry_min_profit_ppm(), 25);
        assertEq(pegKeeper.normal_exit_min_profit_ppm(), 750);
        assertEq(pegKeeper.early_exit_min_profit_ppm(), 7_500);
        assertEq(pegKeeper.keeper_profit_share_bps(), 2_500);
        assertEq(pegKeeper.min_deployment_time(), 3 days);
        assertEq(pegKeeper.min_expansion_amount(), 50_000e18);
        assertEq(pegKeeper.max_deployed_crvusd(), 10_000_000e18);
    }

    function test_policyAllowsZeroEntryMarginZeroRewardAndZeroMaturityDelay() public {
        vm.prank(governance);
        pegKeeper.set_policy(0, 1, 2, 0, 0, 1, 1);

        assertEq(pegKeeper.entry_min_profit_ppm(), 0);
        assertEq(pegKeeper.keeper_profit_share_bps(), 0);
        assertEq(pegKeeper.min_deployment_time(), 0);
    }

    function test_policyRejectsUnauthorizedCallerWithBareVyperRevert() public {
        vm.prank(makeAddr("keeper"));
        (bool success, bytes memory revertData) = address(pegKeeper)
            .call(
                abi.encodeCall(
                    IPegKeeperV3.set_policy,
                    (25, 750, 7_500, 2_500, 3 days, 50_000e18, 10_000_000e18)
                )
            );

        assertFalse(success);
        assertEq(revertData.length, 0);
    }

    function test_policyRejectsInvalidMarginOrderingAndBounds() public {
        vm.startPrank(governance);

        vm.expectRevert();
        pegKeeper.set_policy(751, 750, 7_500, 2_500, 3 days, 50_000e18, 10_000_000e18);

        vm.expectRevert();
        pegKeeper.set_policy(25, 750, 750, 2_500, 3 days, 50_000e18, 10_000_000e18);

        vm.expectRevert();
        pegKeeper.set_policy(25, 750, 1_000_001, 2_500, 3 days, 50_000e18, 10_000_000e18);

        vm.stopPrank();
    }

    function test_policyRejectsInvalidProfitShareAndExposureBounds() public {
        vm.startPrank(governance);

        vm.expectRevert();
        pegKeeper.set_policy(25, 750, 7_500, 10_001, 3 days, 50_000e18, 10_000_000e18);

        vm.expectRevert();
        pegKeeper.set_policy(25, 750, 7_500, 2_500, 3 days, 0, 10_000_000e18);

        vm.expectRevert();
        pegKeeper.set_policy(25, 750, 7_500, 2_500, 3 days, 50_000e18, 0);

        vm.stopPrank();
    }

    function test_adminUpdatesTargetAmmAndDiscoversPairOrder() public {
        MockTwoCoinPool replacement = new MockTwoCoinPool(address(crvUsd), address(targetAsset));

        vm.expectEmit(true, true, false, true, address(pegKeeper));
        emit IPegKeeperV3.TargetAmmUpdated(address(targetAmm), address(replacement), 0, 1, 7);
        vm.prank(governance);
        pegKeeper.set_target_amm(address(replacement), 7);

        assertEq(pegKeeper.target_amm(), address(replacement));
        assertEq(pegKeeper.target_amm_crvusd_index(), 0);
        assertEq(pegKeeper.target_amm_target_index(), 1);
        assertEq(pegKeeper.target_amm_execution_buffer_bps(), 7);
    }

    function test_targetAmmUpdateRejectsUnauthorizedInvalidPairAndBuffer() public {
        MockTwoCoinPool replacement = new MockTwoCoinPool(address(crvUsd), address(targetAsset));
        MockTwoCoinPool wrongPair = new MockTwoCoinPool(address(backingAsset), address(targetAsset));

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        pegKeeper.set_target_amm(address(replacement), 7);

        vm.startPrank(governance);
        vm.expectRevert();
        pegKeeper.set_target_amm(address(0), 7);

        vm.expectRevert();
        pegKeeper.set_target_amm(address(replacement), 10_001);

        vm.expectRevert();
        pegKeeper.set_target_amm(address(wrongPair), 7);
        vm.stopPrank();

        assertEq(pegKeeper.target_amm(), address(targetAmm));
        assertEq(pegKeeper.target_amm_crvusd_index(), 1);
        assertEq(pegKeeper.target_amm_target_index(), 0);
    }

    function test_adminAtomicallyRotatesRoles() public {
        address newAdmin = makeAddr("newAdmin");
        address newEmergencyAdmin = makeAddr("newEmergencyAdmin");

        vm.expectEmit(true, true, true, true, address(pegKeeper));
        emit IPegKeeperV3.RolesUpdated(governance, newAdmin, newEmergencyAdmin);
        vm.prank(governance);
        pegKeeper.set_roles(newAdmin, newEmergencyAdmin);

        assertEq(pegKeeper.admin(), newAdmin);
        assertEq(pegKeeper.emergency_admin(), newEmergencyAdmin);

        vm.prank(governance);
        vm.expectRevert();
        pegKeeper.set_fee_receiver(makeAddr("oldAdminReceiver"));

        vm.prank(newAdmin);
        pegKeeper.set_fee_receiver(makeAddr("newReceiver"));

        vm.prank(newEmergencyAdmin);
        pegKeeper.set_direction_paused(2, true);
        assertTrue(pegKeeper.direct_buyback_paused());

        vm.prank(emergencyAdmin);
        vm.expectRevert();
        pegKeeper.set_direction_paused(3, true);
    }

    function test_roleRotationRejectsUnauthorizedZeroAndOverlap() public {
        address newAdmin = makeAddr("newAdmin");
        address newEmergencyAdmin = makeAddr("newEmergencyAdmin");

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        pegKeeper.set_roles(newAdmin, newEmergencyAdmin);

        vm.startPrank(governance);
        vm.expectRevert();
        pegKeeper.set_roles(address(0), newEmergencyAdmin);

        vm.expectRevert();
        pegKeeper.set_roles(newAdmin, address(0));

        vm.expectRevert();
        pegKeeper.set_roles(newAdmin, newAdmin);
        vm.stopPrank();
    }

    function _deploy() internal returns (IPegKeeperV3Policy deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory),
            address(targetAmm),
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
        deployedPegKeeper = IPegKeeperV3Policy(deployed);
    }
}
