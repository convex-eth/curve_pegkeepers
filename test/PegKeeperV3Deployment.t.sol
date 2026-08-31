// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";

contract PegKeeperV3DeploymentTest is Test {
    function test_deploymentScriptCreatesLockedImplementationAndPreviewModule() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        (address implementation, address previewModule) = deployer.deploy();
        IPegKeeperV3 pegKeeper = IPegKeeperV3(implementation);

        assertGt(implementation.code.length, 0);
        assertLe(implementation.code.length, 24_576);
        assertGt(previewModule.code.length, 0);
        assertTrue(pegKeeper.initialized());
        assertEq(pegKeeper.preview_module(), previewModule);
        assertEq(pegKeeper.factory(), address(0));
        assertEq(pegKeeper.controller_factory(), address(0));
        assertEq(pegKeeper.crv_usd(), address(0));
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertTrue(pegKeeper.all_execution_paused());
        assertTrue(pegKeeper.expansion_paused());
        assertTrue(pegKeeper.backing_deployment_paused());
        assertTrue(pegKeeper.direct_buyback_paused());
        assertTrue(pegKeeper.undeployed_contraction_paused());
        assertTrue(pegKeeper.yield_contraction_paused());
    }
}
