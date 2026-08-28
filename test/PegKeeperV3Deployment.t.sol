// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {
    MockFactory,
    MockToken,
    MockTwoCoinPool,
    MockYieldToken
} from "./PegKeeperV3Foundation.t.sol";

contract PegKeeperV3DeploymentTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    function test_deploymentScriptCreatesVerifiedPausedV3() public {
        MockToken crvUsd = new MockToken(18);
        MockToken targetAsset = new MockToken(6);
        MockToken backingAsset = new MockToken(18);
        MockYieldToken yieldToken = new MockYieldToken(address(backingAsset));
        MockFactory factory = new MockFactory(address(crvUsd), makeAddr("factoryAdmin"));
        MockTwoCoinPool targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));
        address admin = makeAddr("admin");
        address emergencyAdmin = makeAddr("emergencyAdmin");
        address feeReceiver = makeAddr("feeReceiver");

        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = DeployPegKeeperV3.Config({
            factory: address(factory),
            targetAmm: address(targetAmm),
            targetAsset: address(targetAsset),
            backingAsset: address(backingAsset),
            yieldToken: address(yieldToken),
            feeReceiver: feeReceiver,
            admin: admin,
            emergencyAdmin: emergencyAdmin,
            maxDeployedCrvUsd: MAX_DEPLOYED
        });

        address deployed = deployer.deploy(config);
        IPegKeeperV3 pegKeeper = IPegKeeperV3(deployed);

        assertEq(pegKeeper.factory(), address(factory));
        assertEq(pegKeeper.crv_usd(), address(crvUsd));
        assertEq(pegKeeper.target_amm(), address(targetAmm));
        assertEq(pegKeeper.target_asset(), address(targetAsset));
        assertEq(pegKeeper.backing_asset(), address(backingAsset));
        assertEq(pegKeeper.yield_token(), address(yieldToken));
        assertEq(pegKeeper.fee_receiver(), feeReceiver);
        assertEq(pegKeeper.admin(), admin);
        assertEq(pegKeeper.emergency_admin(), emergencyAdmin);
        assertEq(pegKeeper.max_deployed_crvusd(), MAX_DEPLOYED);
        assertTrue(pegKeeper.all_execution_paused());
        assertTrue(pegKeeper.expansion_paused());
        assertTrue(pegKeeper.backing_deployment_paused());
        assertTrue(pegKeeper.direct_buyback_paused());
        assertTrue(pegKeeper.undeployed_contraction_paused());
        assertTrue(pegKeeper.yield_contraction_paused());
        assertLe(deployed.code.length, 24_576);
    }
}
