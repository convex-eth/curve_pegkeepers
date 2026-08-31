// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../script/DeployPegKeeperV3.s.sol";
import {
    CurveProposalLaunchPegKeeperV3
} from "../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol";

contract PegKeeperV3ProposalDeploymentJsonTest is Test {
    string internal constant TEST_OUTPUT =
        "deployments/mainnet/PegKeeperV3-proposal-input.test.json";

    function test_proposalLoadsFactoryAndCurveOraclesFromDeploymentJson() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = DeployPegKeeperV3.Deployment({
            previewModule: makeAddr("previewModule"),
            implementation: makeAddr("implementation"),
            factory: makeAddr("factory"),
            frxUsdTargetOracle: makeAddr("frxUsdTargetOracle"),
            sfrxUsdBackingOracle: makeAddr("sfrxUsdBackingOracle"),
            usdcTargetOracle: makeAddr("usdcTargetOracle"),
            usdtTargetOracle: makeAddr("usdtTargetOracle"),
            susdsBackingOracle: makeAddr("susdsBackingOracle"),
            frxUsdChainlinkOracle: makeAddr("frxUsdChainlinkOracle"),
            usdsChainlinkOracle: makeAddr("usdsChainlinkOracle")
        });
        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);

        CurveProposalLaunchPegKeeperV3 proposal = new CurveProposalLaunchPegKeeperV3();
        proposal.loadDeployment(TEST_OUTPUT);

        assertEq(proposal.deploymentFactory(), deployment.factory);
        assertEq(proposal.frxUsdOracle(), deployment.frxUsdTargetOracle);
        assertEq(proposal.frxUsdBackingOracle(), deployment.sfrxUsdBackingOracle);
        assertEq(proposal.usdcOracle(), deployment.usdcTargetOracle);
        assertEq(proposal.usdtOracle(), deployment.usdtTargetOracle);
        assertEq(proposal.susdsBackingOracle(), deployment.susdsBackingOracle);
        vm.removeFile(TEST_OUTPUT);
    }

    function test_proposalRejectsDeploymentJsonFromAnotherChain() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment;
        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);
        vm.writeJson("1", TEST_OUTPUT, ".chainId");

        CurveProposalLaunchPegKeeperV3 proposal = new CurveProposalLaunchPegKeeperV3();
        vm.expectRevert(bytes("deployment chain"));
        proposal.loadDeployment(TEST_OUTPUT);
        vm.removeFile(TEST_OUTPUT);
    }
}
