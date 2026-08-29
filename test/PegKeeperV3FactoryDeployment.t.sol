// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3Factory} from "../script/DeployPegKeeperV3Factory.s.sol";
import {PegKeeperV3Factory} from "../src/PegKeeperV3Factory.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {MockFactory, MockToken} from "./PegKeeperV3Foundation.t.sol";

contract PegKeeperV3FactoryDeploymentTest is Test {
    function test_deploymentScriptCreatesVerifiedBlueprintAndFactory() public {
        MockToken crvUsd = new MockToken(18);
        MockFactory controllerFactory =
            new MockFactory(address(crvUsd), address(this), address(0xBEEF), address(0xFEE));
        address admin = makeAddr("admin");
        address emergencyAdmin = makeAddr("emergencyAdmin");
        address feeReceiver = makeAddr("feeReceiver");

        DeployPegKeeperV3Factory deployer = new DeployPegKeeperV3Factory();
        DeployPegKeeperV3Factory.Config memory config = DeployPegKeeperV3Factory.Config({
            owner: address(this),
            controllerFactory: address(controllerFactory),
            admin: admin,
            emergencyAdmin: emergencyAdmin,
            feeReceiver: feeReceiver,
            maxDeployedCrvUsd: 25_000_000e18,
            targetAmmExecutionBufferBps: 5,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100
        });

        (address blueprint, address deployedFactory) = deployer.deploy(config);
        PegKeeperV3Factory factory = PegKeeperV3Factory(deployedFactory);
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();

        assertGt(blueprint.code.length, 3);
        assertLe(blueprint.code.length, 24_576);
        assertEq(uint8(blueprint.code[0]), 0xfe);
        assertEq(uint8(blueprint.code[1]), 0x71);
        assertEq(uint8(blueprint.code[2]), 0x00);
        assertEq(factory.owner(), address(this));
        assertEq(factory.controllerFactory(), address(controllerFactory));
        assertEq(factory.implementation(), blueprint);
        assertEq(defaults_.admin, admin);
        assertEq(defaults_.emergencyAdmin, emergencyAdmin);
        assertEq(defaults_.feeReceiver, feeReceiver);
        assertEq(defaults_.maxDeployedCrvUsd, 25_000_000e18);
        assertEq(defaults_.targetAmmExecutionBufferBps, 5);
        assertEq(defaults_.minDownstreamAttemptGas, 1_500_000);
        assertEq(defaults_.fallbackSettlementGasReserve, 300_000);
        assertEq(defaults_.expansionMaxRouteLossBps, 100);
        assertEq(factory.keeperCount(), 0);
    }
}
