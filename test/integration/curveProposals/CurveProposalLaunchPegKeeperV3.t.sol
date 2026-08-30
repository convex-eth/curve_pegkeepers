// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3Factory} from "../../../script/DeployPegKeeperV3Factory.s.sol";
import {BaseCurveProposal} from "../../../script/proposals/curve/BaseCurveProposal.sol";
import {
    CurveProposalLaunchPegKeeperV3
} from "../../../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol";
import {PegKeeperV3Factory} from "../../../src/PegKeeperV3Factory.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {ICurveEDAOAdminProxy} from "../../../src/interfaces/ICurveEDAOAdminProxy.sol";
import {ICurveVoting} from "../../../src/interfaces/ICurveVoting.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";

contract CurveEDAOProxyHarness {
    function execute(address target, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{value: msg.value}(data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}

contract CurveProposalLaunchPegKeeperV3Test is Test {
    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant OWNERSHIP_VOTING = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant EDAO_PROXY = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant CONVEX_VOTEPROXY = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    address internal constant YEARN_VOTEPROXY = 0xF147b8125d2ef93FB6965Db97D6746952a133934;
    address internal constant SD_VOTEPROXY = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;

    uint256 internal constant FRXUSD_CAP = 2_500_000e18;
    uint256 internal constant USDC_CAP = 2_500_000e18;
    uint256 internal constant USDT_CAP = 5_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3 internal proposal;
    PegKeeperV3Factory internal factory;
    address internal expectedFrxUsdKeeper;
    address internal expectedUsdcKeeper;
    address internal expectedUsdtKeeper;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        // This repository targets Shanghai bytecode. The live eDAO proxy now executes an opcode
        // from a later fork after forwarding the call, so use an ABI-equivalent forwarding harness
        // while retaining the real proxy address and ControllerFactory authorization boundary.
        CurveEDAOProxyHarness proxyHarness = new CurveEDAOProxyHarness();
        vm.etch(EDAO_PROXY, address(proxyHarness).code);

        proposal = new CurveProposalLaunchPegKeeperV3();
        DeployPegKeeperV3Factory deployer = new DeployPegKeeperV3Factory();
        DeployPegKeeperV3Factory.Config memory config = DeployPegKeeperV3Factory.Config({
            owner: OWNERSHIP_AGENT,
            controllerFactory: CONTROLLER_FACTORY,
            admin: OWNERSHIP_AGENT,
            emergencyAdmin: proposal.CURVE_EMERGENCY_ADMIN(),
            feeReceiver: proposal.FEE_SPLITTER(),
            maxDeployedCrvUsd: FRXUSD_CAP,
            targetAmmExecutionBufferBps: 5,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100
        });
        (, address factoryAddress) = deployer.deploy(config);
        factory = PegKeeperV3Factory(factoryAddress);

        proposal.setDeploymentFactory(factoryAddress);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedUsdcKeeper = proposal.expectedKeeper(2);
        expectedUsdtKeeper = proposal.expectedKeeper(3);
    }

    function test_ProposalActionsOnlyConfigureNewV3Keepers() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 11);

        assertEq(actions[0].target, address(factory));
        assertEq(_selector(actions[0].data), IPegKeeperV3Factory.setDefaults.selector);
        assertEq(actions[1].target, address(factory));
        assertEq(_selector(actions[1].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[2].target, expectedFrxUsdKeeper);
        assertEq(_selector(actions[2].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[3], expectedFrxUsdKeeper, FRXUSD_CAP);

        assertEq(actions[4].target, address(factory));
        assertEq(_selector(actions[4].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[5].target, expectedUsdcKeeper);
        assertEq(_selector(actions[5].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[6], expectedUsdcKeeper, USDC_CAP);

        assertEq(actions[7].target, address(factory));
        assertEq(_selector(actions[7].data), IPegKeeperV3Factory.setDefaults.selector);
        assertEq(actions[8].target, address(factory));
        assertEq(_selector(actions[8].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[9].target, expectedUsdtKeeper);
        assertEq(_selector(actions[9].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[10], expectedUsdtKeeper, USDT_CAP);
    }

    function test_ProposalDeploysThreePausedKeepersWithSuggestedCapacities() public {
        _executeProposal();

        assertEq(factory.keeperCount(), 3);
        assertEq(factory.keeperAt(1), expectedFrxUsdKeeper);
        assertEq(factory.keeperAt(2), expectedUsdcKeeper);
        assertEq(factory.keeperAt(3), expectedUsdtKeeper);

        _assertKeeperEndpoints(
            expectedFrxUsdKeeper,
            proposal.FRXUSD_CRVUSD_POOL(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            proposal.SFRXUSD(),
            FRXUSD_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdcKeeper,
            proposal.USDC_CRVUSD_POOL(),
            proposal.USDC(),
            proposal.USDS(),
            proposal.SUSDS(),
            USDC_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdtKeeper,
            proposal.USDT_CRVUSD_POOL(),
            proposal.USDT(),
            proposal.USDS(),
            proposal.SUSDS(),
            USDT_CAP
        );

        assertEq(
            IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedFrxUsdKeeper), FRXUSD_CAP
        );
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdcKeeper), USDC_CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdtKeeper), USDT_CAP);
    }

    function test_ProposalSetsExactSuggestedRoutes() public {
        _executeProposal();

        IPegKeeperV3 frxUsdKeeper = IPegKeeperV3(expectedFrxUsdKeeper);
        assertEq(frxUsdKeeper.expansion_path_length(), 1);
        assertEq(frxUsdKeeper.contraction_path_length(), 2);
        _assertStep(
            frxUsdKeeper.expansion_path_step(0),
            0,
            proposal.FRXUSD_SFRXUSD_POOL(),
            proposal.FRXUSD(),
            proposal.SFRXUSD(),
            1,
            0,
            5
        );
        _assertStep(
            frxUsdKeeper.contraction_path_step(0),
            0,
            proposal.FRXUSD_SFRXUSD_POOL(),
            proposal.SFRXUSD(),
            proposal.FRXUSD(),
            0,
            1,
            5
        );
        _assertStep(
            frxUsdKeeper.contraction_path_step(1),
            0,
            proposal.FRXUSD_CRVUSD_POOL(),
            proposal.FRXUSD(),
            proposal.CRVUSD(),
            0,
            1,
            5
        );

        _assertSusdsRoutes(IPegKeeperV3(expectedUsdcKeeper), proposal.USDC(), 1);
        _assertSusdsRoutes(IPegKeeperV3(expectedUsdtKeeper), proposal.USDT(), 2);
    }

    function test_ProposalSetsSharedFactoryAndKeeperPolicyDefaults() public {
        _executeProposal();

        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.admin, OWNERSHIP_AGENT);
        assertEq(defaults_.emergencyAdmin, proposal.CURVE_EMERGENCY_ADMIN());
        assertEq(defaults_.feeReceiver, proposal.FEE_SPLITTER());
        assertEq(defaults_.maxDeployedCrvUsd, USDT_CAP);
        assertEq(defaults_.targetAmmExecutionBufferBps, 5);
        assertEq(defaults_.minDownstreamAttemptGas, 1_500_000);
        assertEq(defaults_.fallbackSettlementGasReserve, 300_000);
        assertEq(defaults_.expansionMaxRouteLossBps, 100);

        _assertPolicy(IPegKeeperV3(expectedFrxUsdKeeper), FRXUSD_CAP);
        _assertPolicy(IPegKeeperV3(expectedUsdcKeeper), USDC_CAP);
        _assertPolicy(IPegKeeperV3(expectedUsdtKeeper), USDT_CAP);
    }

    function _executeProposal() internal {
        bytes memory script = proposal.buildProposalScript();
        vm.prank(CONVEX_VOTEPROXY);
        uint256 proposalId = OWNERSHIP_VOTE.newVote(
            script,
            "Deploy three paused PegKeeperV3 keepers for frxUSD, USDC, and USDT",
            false,
            false
        );

        address[3] memory voters = [CONVEX_VOTEPROXY, YEARN_VOTEPROXY, SD_VOTEPROXY];
        for (uint256 i; i < voters.length; ++i) {
            if (!OWNERSHIP_VOTE.canVote(proposalId, voters[i])) continue;
            vm.prank(voters[i]);
            OWNERSHIP_VOTE.votePct(proposalId, 1e18, 0, false);
        }

        (,, uint64 start,,,,,,,) = OWNERSHIP_VOTE.getVote(proposalId);
        vm.warp(uint256(start) + VOTING_PERIOD);
        OWNERSHIP_VOTE.executeVote(proposalId);
    }

    function _assertKeeperEndpoints(
        address keeperAddress,
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        uint256 cap
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.target_amm(), targetAmm);
        assertEq(keeper.target_asset(), targetAsset);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.yield_token(), yieldToken);
        assertEq(keeper.max_deployed_crvusd(), cap);
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.backing_deployment_paused());
        assertTrue(keeper.direct_buyback_paused());
        assertTrue(keeper.undeployed_contraction_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function _assertPolicy(IPegKeeperV3 keeper, uint256 cap) internal view {
        assertEq(keeper.entry_min_profit_ppm(), 10);
        assertEq(keeper.normal_exit_min_profit_ppm(), 1_000);
        assertEq(keeper.early_exit_min_profit_ppm(), 5_000);
        assertEq(keeper.keeper_profit_share_bps(), 3_000);
        assertEq(keeper.min_deployment_time(), 2 days);
        assertEq(keeper.min_expansion_amount(), 10_000e18);
        assertEq(keeper.max_deployed_crvusd(), cap);
    }

    function _assertSusdsRoutes(IPegKeeperV3 keeper, address targetAsset, int128 threePoolIndex)
        internal
        view
    {
        assertEq(keeper.expansion_path_length(), 3);
        assertEq(keeper.contraction_path_length(), 4);
        _assertStep(
            keeper.expansion_path_step(0),
            0,
            proposal.THREE_POOL(),
            targetAsset,
            proposal.DAI(),
            threePoolIndex,
            0,
            5
        );
        _assertStep(
            keeper.expansion_path_step(1),
            1,
            proposal.DAI_USDS_CONVERTER(),
            proposal.DAI(),
            proposal.USDS(),
            0,
            0,
            0
        );
        _assertStep(
            keeper.expansion_path_step(2),
            2,
            proposal.SUSDS(),
            proposal.USDS(),
            proposal.SUSDS(),
            0,
            0,
            5
        );
        _assertStep(
            keeper.contraction_path_step(0),
            3,
            proposal.SUSDS(),
            proposal.SUSDS(),
            proposal.USDS(),
            0,
            0,
            5
        );
        _assertStep(
            keeper.contraction_path_step(1),
            1,
            proposal.DAI_USDS_CONVERTER(),
            proposal.USDS(),
            proposal.DAI(),
            0,
            0,
            0
        );
        _assertStep(
            keeper.contraction_path_step(2),
            0,
            proposal.THREE_POOL(),
            proposal.DAI(),
            targetAsset,
            0,
            threePoolIndex,
            5
        );
        _assertStep(
            keeper.contraction_path_step(3),
            0,
            keeper.target_amm(),
            targetAsset,
            proposal.CRVUSD(),
            0,
            1,
            5
        );
    }

    function _assertStep(
        IPegKeeperV3.RouteStep memory step,
        uint256 kind,
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut,
        uint256 buffer
    ) internal pure {
        assertEq(step.kind, kind);
        assertEq(step.venue, venue);
        assertEq(step.tokenIn, tokenIn);
        assertEq(step.tokenOut, tokenOut);
        assertEq(step.poolIndexIn, poolIndexIn);
        assertEq(step.poolIndexOut, poolIndexOut);
        assertEq(step.executionBufferBps, buffer);
    }

    function _assertDebtCeilingAction(
        BaseCurveProposal.Action memory action,
        address keeper,
        uint256 cap
    ) internal pure {
        assertEq(action.target, EDAO_PROXY);
        assertEq(_selector(action.data), ICurveEDAOAdminProxy.execute.selector);
        (address target, bytes memory innerData) =
            abi.decode(_withoutSelector(action.data), (address, bytes));
        assertEq(target, CONTROLLER_FACTORY);
        assertEq(_selector(innerData), IControllerFactory.set_debt_ceiling.selector);
        (address subject, uint256 ceiling) =
            abi.decode(_withoutSelector(innerData), (address, uint256));
        assertEq(subject, keeper);
        assertEq(ceiling, cap);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory result) {
        result = new bytes(data.length - 4);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[i + 4];
        }
    }
}
