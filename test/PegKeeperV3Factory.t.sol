// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {LpYieldToken, LpYieldAmm, LpYieldFactory, LpYieldOracle} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3LpFactoryTest is Test {
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    LpYieldToken internal crvUsd;
    LpYieldToken internal yieldToken;
    LpYieldAmm internal yieldAmm;
    LpYieldFactory internal controllerFactory;
    LpYieldOracle internal yieldOracle;
    LpYieldOracle internal aggregateCrvUsdOracle;
    IPegKeeperV3Factory internal factory;
    IPegKeeperPolicy internal policy;
    address internal implementation;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        yieldToken = new LpYieldToken(18);
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        yieldOracle = new LpYieldOracle();
        aggregateCrvUsdOracle = new LpYieldOracle();
        controllerFactory = new LpYieldFactory(
            address(crvUsd), admin, emergencyAdmin, feeReceiver, address(aggregateCrvUsdOracle)
        );

        implementation = _create(vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"));
        policy = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(owner, address(aggregateCrvUsdOracle), 8_000)
            )
        );
        factory = _newFactory(policy);
        vm.prank(owner);
        policy.set_factory(address(factory));
    }

    function test_deployDerivesPairedTokenAndTracksActiveKeeper() public {
        address deployed = _deployKeeper();
        IPegKeeperV3 keeper = IPegKeeperV3(deployed);

        assertEq(factory.policy(), address(policy));
        assertEq(factory.activePegKeeperCount(), 1);
        assertEq(factory.activePegKeeperAt(0), deployed);
        assertTrue(factory.is_active(deployed));
        assertEq(keeper.paired_token(), address(yieldToken));
        assertEq(keeper.backing_asset(), address(yieldToken));
        assertEq(keeper.pool(), address(yieldAmm));
        assertEq(keeper.coins(1), address(yieldAmm));
        assertEq(keeper.amm_execution_buffer_bps(), 4);
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function test_deployRequiresPolicyBoundToThisFactory() public {
        IPegKeeperPolicy unbound = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(owner, address(aggregateCrvUsdOracle), 8_000)
            )
        );
        IPegKeeperV3Factory unboundFactory = _newFactory(unbound);

        vm.prank(owner);
        vm.expectRevert(IPegKeeperV3Factory.InvalidPolicy.selector);
        unboundFactory.deployPegKeeper(address(yieldAmm), false, address(yieldOracle));
    }

    function test_deployRejectsNonOwner() public {
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.deployPegKeeper(address(yieldAmm), false, address(yieldOracle));
    }

    function test_deployRejectsAmmWithoutCrvUsd() public {
        LpYieldToken other = new LpYieldToken(18);
        LpYieldAmm invalidAmm = new LpYieldAmm(address(yieldToken), address(other));

        vm.prank(owner);
        vm.expectRevert(IPegKeeperV3Factory.InvalidAmm.selector);
        factory.deployPegKeeper(address(invalidAmm), false, address(yieldOracle));
    }

    function test_defaultsContainOnlyDirectAmmExecutionBuffer() public view {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.ammExecutionBufferBps, 4);
    }

    function test_ownerCanInstallBoundReplacementPolicy() public {
        IPegKeeperPolicy replacement = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(owner, address(aggregateCrvUsdOracle), 8_000)
            )
        );
        vm.prank(owner);
        replacement.set_factory(address(factory));

        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.setPolicy(address(replacement));

        vm.prank(owner);
        factory.setPolicy(address(replacement));
        assertEq(factory.policy(), address(replacement));
    }

    function test_existingKeeperReadsReplacementPolicyDynamically() public {
        address deployed = _deployKeeper();
        IPegKeeperV3 keeper = IPegKeeperV3(deployed);
        controllerFactory.setDebtCeiling(deployed, 25_000_000e18);
        crvUsd.mint(deployed, 100_000e18);
        yieldAmm.setBalances(0, 100_000_000e18);
        yieldAmm.setLpMintBps(10_001);

        vm.startPrank(admin);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();
        vm.prank(owner);
        policy.set_tier(deployed, 1);
        assertGt(keeper.available_expansion(), 0);

        LpYieldOracle belowPeg = new LpYieldOracle();
        belowPeg.setPrice(1e18 - 1);
        IPegKeeperPolicy replacement = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(owner, address(belowPeg), 8_000))
        );
        vm.startPrank(owner);
        replacement.set_factory(address(factory));
        replacement.set_tier(deployed, 1);
        factory.setPolicy(address(replacement));
        vm.stopPrank();

        assertEq(factory.policy(), address(replacement));
        assertEq(keeper.available_expansion(), 0);
        assertTrue(policy.can_expand(deployed));
    }

    function test_policyUpdateRejectsUnboundAndInvalidContracts() public {
        IPegKeeperPolicy unbound = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(owner, address(aggregateCrvUsdOracle), 8_000)
            )
        );
        vm.startPrank(owner);
        vm.expectRevert(IPegKeeperV3Factory.InvalidPolicy.selector);
        factory.setPolicy(address(unbound));
        vm.expectRevert(IPegKeeperV3Factory.InvalidPolicy.selector);
        factory.setPolicy(address(0));
        vm.expectRevert(IPegKeeperV3Factory.InvalidPolicy.selector);
        factory.setPolicy(makeAddr("no code"));
        vm.stopPrank();

        assertEq(factory.policy(), address(policy));
    }

    function test_activeListUsesPopAndSwapAndSupportsReactivation() public {
        address first = _deployKeeper();
        address second = _deployKeeper();

        vm.prank(owner);
        factory.set_active(first, false);
        assertFalse(factory.is_active(first));
        assertTrue(factory.is_active(second));
        assertEq(factory.activePegKeeperCount(), 1);
        assertEq(factory.activePegKeeperAt(0), second);

        vm.prank(owner);
        factory.set_active(first, true);
        assertTrue(factory.is_active(first));
        assertEq(factory.activePegKeeperCount(), 2);
        assertEq(factory.activePegKeeperAt(0), second);
        assertEq(factory.activePegKeeperAt(1), first);
    }

    function test_setActiveRejectsUnknownKeeperAndNonOwner() public {
        address deployed = _deployKeeper();

        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.set_active(deployed, false);

        vm.prank(owner);
        vm.expectRevert(IPegKeeperV3Factory.InvalidKeeper.selector);
        factory.set_active(makeAddr("unknown"), true);
    }

    function _newFactory(IPegKeeperPolicy initialPolicy)
        internal
        returns (IPegKeeperV3Factory deployedFactory)
    {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: admin,
                emergencyAdmin: emergencyAdmin,
                feeReceiver: feeReceiver,
                maxDeployedCrvUsd: 25_000_000e18,
                ammExecutionBufferBps: 4
            });
        return IPegKeeperV3Factory(
            _create(
                bytes.concat(
                    vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json"),
                    abi.encode(
                        owner,
                        address(controllerFactory),
                        implementation,
                        address(initialPolicy),
                        defaults_
                    )
                )
            )
        );
    }

    function _deployKeeper() internal returns (address) {
        vm.prank(owner);
        return factory.deployPegKeeper(address(yieldAmm), false, address(yieldOracle));
    }

    function _create(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
