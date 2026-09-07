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

    function test_proposalLoadsPreconfiguredCandidatesFromDeploymentJson() public {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = DeployPegKeeperV3.Deployment({
            initialOwner: makeAddr("initialOwner"),
            implementation: makeAddr("implementation"),
            policy: makeAddr("policy"),
            factory: makeAddr("factory"),
            frxUsdUsdOracle: makeAddr("frxUsdUsdOracle"),
            usdeUsdOracle: makeAddr("usdeUsdOracle"),
            usdcUsdOracle: makeAddr("usdcUsdOracle"),
            usdtUsdOracle: makeAddr("usdtUsdOracle"),
            frxUsdPegKeeper: makeAddr("frxUsdPegKeeper"),
            sUsdePegKeeper: makeAddr("sUsdePegKeeper"),
            usdcPegKeeper: makeAddr("usdcPegKeeper"),
            usdtPegKeeper: makeAddr("usdtPegKeeper"),
            factoryOwnershipNonce: 7,
            policyOwnershipNonce: 9
        });
        deployer.writeDeploymentJson(deployment, TEST_OUTPUT);

        CurveProposalLaunchPegKeeperV3 proposal = new CurveProposalLaunchPegKeeperV3();
        proposal.loadDeployment(TEST_OUTPUT);

        assertEq(proposal.deploymentInitialOwner(), deployment.initialOwner);
        assertEq(proposal.deploymentFactory(), deployment.factory);
        assertEq(proposal.pegKeeperPolicy(), deployment.policy);
        assertEq(proposal.frxUsdOracle(), deployment.frxUsdUsdOracle);
        assertEq(proposal.usdeOracle(), deployment.usdeUsdOracle);
        assertEq(proposal.usdcOracle(), deployment.usdcUsdOracle);
        assertEq(proposal.usdtOracle(), deployment.usdtUsdOracle);
        assertEq(proposal.frxUsdKeeper(), deployment.frxUsdPegKeeper);
        assertEq(proposal.sUsdeKeeper(), deployment.sUsdePegKeeper);
        assertEq(proposal.usdcKeeper(), deployment.usdcPegKeeper);
        assertEq(proposal.usdtKeeper(), deployment.usdtPegKeeper);
        assertEq(proposal.factoryOwnershipNonce(), deployment.factoryOwnershipNonce);
        assertEq(proposal.policyOwnershipNonce(), deployment.policyOwnershipNonce);

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
