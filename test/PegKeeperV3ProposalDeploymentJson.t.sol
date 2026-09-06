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
    string internal constant WRONG_CHAIN_OUTPUT =
        "deployments/mainnet/PegKeeperV3-proposal-input-wrong-chain.test.json";

    function test_proposalLoadsFactoryAndSelectedOraclesFromDeploymentJson() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = DeployPegKeeperV3.Deployment({
            implementation: makeAddr("implementation"),
            policy: makeAddr("policy"),
            factory: makeAddr("factory"),
            frxUsdUsdOracle: makeAddr("frxUsdUsdOracle"),
            usdeUsdOracle: makeAddr("usdeUsdOracle"),
            usdcUsdOracle: makeAddr("usdcUsdOracle"),
            usdtUsdOracle: makeAddr("usdtUsdOracle")
        });
        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);

        CurveProposalLaunchPegKeeperV3 proposal = new CurveProposalLaunchPegKeeperV3();
        proposal.loadDeployment(TEST_OUTPUT);

        assertEq(proposal.deploymentFactory(), deployment.factory);
        assertEq(proposal.pegKeeperPolicy(), deployment.policy);
        assertEq(proposal.frxUsdOracle(), deployment.frxUsdUsdOracle);
        assertEq(proposal.usdeOracle(), deployment.usdeUsdOracle);
        assertEq(proposal.usdcOracle(), deployment.usdcUsdOracle);
        assertEq(proposal.usdtOracle(), deployment.usdtUsdOracle);

        vm.removeFile(TEST_OUTPUT);
    }

    function test_proposalRejectsDeploymentJsonFromAnotherChain() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment;
        deployer.writeDeploymentJson(deployment, WRONG_CHAIN_OUTPUT);
        vm.writeJson(vm.toString(block.chainid + 1), WRONG_CHAIN_OUTPUT, ".chainId");

        CurveProposalLaunchPegKeeperV3 proposal = new CurveProposalLaunchPegKeeperV3();
        vm.expectRevert(bytes("deployment chain"));
        proposal.loadDeployment(WRONG_CHAIN_OUTPUT);
        vm.removeFile(WRONG_CHAIN_OUTPUT);
    }
}
