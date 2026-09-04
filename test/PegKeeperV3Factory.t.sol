// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {
    LpYieldToken,
    LpYieldTargetAmm,
    LpYieldAmm,
    LpYieldRoutePool,
    LpYieldFactory,
    LpYieldOracle
} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3LpFactoryTest is Test {
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    LpYieldToken internal crvUsd;
    LpYieldToken internal target;
    LpYieldToken internal yieldToken;
    LpYieldTargetAmm internal targetAmm;
    LpYieldAmm internal yieldAmm;
    LpYieldRoutePool internal route;
    LpYieldFactory internal controllerFactory;
    LpYieldOracle internal targetOracle;
    LpYieldOracle internal yieldOracle;
    LpYieldOracle internal aggregateCrvUsdOracle;
    IPegKeeperV3Factory internal factory;
    address internal implementation;

    function setUp() public {
        crvUsd = new LpYieldToken(18);
        target = new LpYieldToken(6);
        yieldToken = new LpYieldToken(18);
        targetAmm = new LpYieldTargetAmm(crvUsd, target);
        yieldAmm = new LpYieldAmm(address(crvUsd), address(yieldToken));
        route = new LpYieldRoutePool(target, yieldToken);
        targetOracle = new LpYieldOracle();
        yieldOracle = new LpYieldOracle();
        aggregateCrvUsdOracle = new LpYieldOracle();
        controllerFactory = new LpYieldFactory(
            address(crvUsd), admin, emergencyAdmin, feeReceiver, address(aggregateCrvUsdOracle)
        );

        address preview =
            _create(vm.getCode("out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json"));
        implementation = _create(
            bytes.concat(vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"), abi.encode(preview))
        );
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: admin,
                emergencyAdmin: emergencyAdmin,
                feeReceiver: feeReceiver,
                maxDeployedCrvUsd: 25_000_000e18,
                targetAmmExecutionBufferBps: 3,
                yieldAmmExecutionBufferBps: 4,
                expansionMaxRouteLossBps: 100
            });
        factory = IPegKeeperV3Factory(
            _create(
                bytes.concat(
                    vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json"),
                    abi.encode(
                        owner,
                        address(controllerFactory),
                        implementation,
                        address(aggregateCrvUsdOracle),
                        defaults_
                    )
                )
            )
        );
    }

    function test_deployPinsYieldAmmAndOnlyExpansionPath() public {
        IPegKeeperV3.RouteStep[] memory path = _path();
        vm.prank(owner);
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            address(yieldAmm),
            false,
            address(targetOracle),
            address(yieldOracle),
            path
        );

        IPegKeeperV3 keeper = IPegKeeperV3(deployed);
        assertEq(factory.keeperCount(), 1);
        assertEq(factory.keeperAt(1), deployed);
        assertTrue(factory.isPegKeeper(deployed));
        assertEq(factory.implementationOf(deployed), implementation);
        assertEq(keeper.target_amm(), address(targetAmm));
        assertEq(keeper.target_asset(), address(target));
        assertEq(keeper.yield_token(), address(yieldToken));
        assertEq(keeper.yield_amm(), address(yieldAmm));
        assertEq(keeper.coins(1), address(yieldAmm));
        assertEq(keeper.expansion_path_length(), 1);
        assertEq(keeper.target_amm_execution_buffer_bps(), 3);
        assertEq(keeper.yield_amm_execution_buffer_bps(), 4);
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function test_deployRejectsNonOwner() public {
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            address(yieldAmm),
            false,
            address(targetOracle),
            address(yieldOracle),
            _path()
        );
    }

    function test_defaultsContainYieldAmmSlippageNotFallbackGas() public view {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.targetAmmExecutionBufferBps, 3);
        assertEq(defaults_.yieldAmmExecutionBufferBps, 4);
        assertEq(defaults_.expansionMaxRouteLossBps, 100);
    }

    function test_ownerCanUpdateSharedAggregateCrvUsdOracle() public {
        assertEq(factory.aggregateCrvUsdOracle(), address(aggregateCrvUsdOracle));

        LpYieldOracle replacement = new LpYieldOracle();
        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.setAggregateCrvUsdOracle(address(replacement));

        vm.prank(owner);
        factory.setAggregateCrvUsdOracle(address(replacement));
        assertEq(factory.aggregateCrvUsdOracle(), address(replacement));
    }

    function test_aggregateCrvUsdOracleUpdateRejectsInvalidAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(IPegKeeperV3Factory.InvalidOracle.selector);
        factory.setAggregateCrvUsdOracle(address(0));
        vm.expectRevert(IPegKeeperV3Factory.InvalidOracle.selector);
        factory.setAggregateCrvUsdOracle(makeAddr("no code"));
        vm.stopPrank();

        assertEq(factory.aggregateCrvUsdOracle(), address(aggregateCrvUsdOracle));
    }

    function _path() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](1);
        path[0] = IPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(route),
            tokenIn: address(target),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 0
        });
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
