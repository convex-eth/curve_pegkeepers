// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3} from "../../../script/DeployPegKeeperV3.s.sol";
import {BaseCurveProposal} from "../../../script/proposals/curve/BaseCurveProposal.sol";
import {
    CurveProposalLaunchPegKeeperV3
} from "../../../script/proposals/curve/CurveProposalLaunchPegKeeperV3.s.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {ICurveEDAOAdminProxy} from "../../../src/interfaces/ICurveEDAOAdminProxy.sol";
import {ICurveVoting} from "../../../src/interfaces/ICurveVoting.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";
import {ICurveStablecoinOracle} from "../../../src/interfaces/ICurveStablecoinOracle.sol";

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
    address internal constant MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address internal constant LEGACY_MONETARY_POLICY = 0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;
    address internal constant WRONG_FRXUSD_FEED = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    address internal constant CONVEX_VOTEPROXY = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    address internal constant YEARN_VOTEPROXY = 0xF147b8125d2ef93FB6965Db97D6746952a133934;
    address internal constant SD_VOTEPROXY = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;

    uint256 internal constant FRXUSD_CAP = 2_500_000e18;
    uint256 internal constant USDC_CAP = 2_500_000e18;
    uint256 internal constant USDT_CAP = 5_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3 internal proposal;
    IPegKeeperV3Factory internal factory;
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
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(deployer.mainnetConfig());
        proposal.setOracleAdapters(
            deployment.frxUsdUsdOracle, deployment.usdcTargetOracle, deployment.usdtTargetOracle
        );

        factory = IPegKeeperV3Factory(deployment.factory);

        proposal.setDeploymentFactory(deployment.factory);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedUsdcKeeper = proposal.expectedKeeper(2);
        expectedUsdtKeeper = proposal.expectedKeeper(3);
    }

    function test_ProposalActionsOnlyConfigureNewV3Keepers() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 17);

        assertEq(actions[0].target, address(factory));
        assertEq(_selector(actions[0].data), IPegKeeperV3Factory.setDefaults.selector);
        assertEq(actions[1].target, address(factory));
        assertEq(_selector(actions[1].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[2].target, expectedFrxUsdKeeper);
        assertEq(_selector(actions[2].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[3], expectedFrxUsdKeeper, FRXUSD_CAP);
        _assertMonetaryPolicyAction(actions[4], MONETARY_POLICY, expectedFrxUsdKeeper);
        _assertMonetaryPolicyAction(actions[5], LEGACY_MONETARY_POLICY, expectedFrxUsdKeeper);

        assertEq(actions[6].target, address(factory));
        assertEq(_selector(actions[6].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[7].target, expectedUsdcKeeper);
        assertEq(_selector(actions[7].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[8], expectedUsdcKeeper, USDC_CAP);
        _assertMonetaryPolicyAction(actions[9], MONETARY_POLICY, expectedUsdcKeeper);
        _assertMonetaryPolicyAction(actions[10], LEGACY_MONETARY_POLICY, expectedUsdcKeeper);

        assertEq(actions[11].target, address(factory));
        assertEq(_selector(actions[11].data), IPegKeeperV3Factory.setDefaults.selector);
        assertEq(actions[12].target, address(factory));
        assertEq(_selector(actions[12].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        assertEq(actions[13].target, expectedUsdtKeeper);
        assertEq(_selector(actions[13].data), IPegKeeperV3.set_policy.selector);
        _assertDebtCeilingAction(actions[14], expectedUsdtKeeper, USDT_CAP);
        _assertMonetaryPolicyAction(actions[15], MONETARY_POLICY, expectedUsdtKeeper);
        _assertMonetaryPolicyAction(actions[16], LEGACY_MONETARY_POLICY, expectedUsdtKeeper);
    }

    function test_OracleAdaptersUseSelectedFrxUsdChainlinkFeed() public view {
        assertEq(proposal.frxUsdOracle(), proposal.frxUsdBackingOracle());
        _assertChainlinkOracle(
            proposal.frxUsdOracle(), proposal.FRXUSD_USD_PROXY(), proposal.CHAINLINK_MAX_DELAY()
        );
        _assertOracle(
            proposal.usdcOracle(),
            proposal.USDC_USDT_ORACLE_POOL(),
            proposal.USDC(),
            proposal.USDT(),
            true
        );
        _assertOracle(
            proposal.usdtOracle(),
            proposal.USDC_USDT_ORACLE_POOL(),
            proposal.USDT(),
            proposal.USDC(),
            false
        );
    }

    function test_ProposalRejectsSwappedChainlinkFeeds() public {
        address wrongFrxUsdOracle =
            _deployChainlinkOracle(WRONG_FRXUSD_FEED, proposal.CHAINLINK_MAX_DELAY());
        proposal.setOracleAdapters(wrongFrxUsdOracle, proposal.usdcOracle(), proposal.usdtOracle());

        vm.expectRevert("oracle feed");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsChainlinkDelayDrift() public {
        address frxUsdOracle = _deployChainlinkOracle(proposal.FRXUSD_USD_PROXY(), 24 hours);
        proposal.setOracleAdapters(frxUsdOracle, proposal.usdcOracle(), proposal.usdtOracle());

        vm.expectRevert("oracle delay");
        proposal.buildProposalActions();
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
            proposal.FRXUSD(),
            false,
            proposal.frxUsdOracle(),
            proposal.frxUsdBackingOracle(),
            FRXUSD_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdcKeeper,
            proposal.USDC_CRVUSD_POOL(),
            proposal.USDC(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            false,
            proposal.usdcOracle(),
            proposal.frxUsdBackingOracle(),
            USDC_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdtKeeper,
            proposal.USDT_CRVUSD_POOL(),
            proposal.USDT(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            false,
            proposal.usdtOracle(),
            proposal.frxUsdBackingOracle(),
            USDT_CAP
        );

        assertEq(
            IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedFrxUsdKeeper), FRXUSD_CAP
        );
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdcKeeper), USDC_CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdtKeeper), USDT_CAP);
    }

    function test_ProposalRegistersThreeV3KeepersInMonetaryPolicy() public {
        IAggMonetaryPolicy monetaryPolicy = IAggMonetaryPolicy(MONETARY_POLICY);
        IAggMonetaryPolicy legacyMonetaryPolicy = IAggMonetaryPolicy(LEGACY_MONETARY_POLICY);
        uint256[3] memory emptySlots = _firstThreeEmptySlots(monetaryPolicy);
        uint256[3] memory legacyEmptySlots = _firstThreeEmptySlots(legacyMonetaryPolicy);

        _executeProposal();

        assertEq(monetaryPolicy.peg_keepers(emptySlots[0]), expectedFrxUsdKeeper);
        assertEq(monetaryPolicy.peg_keepers(emptySlots[1]), expectedUsdcKeeper);
        assertEq(monetaryPolicy.peg_keepers(emptySlots[2]), expectedUsdtKeeper);
        assertEq(legacyMonetaryPolicy.peg_keepers(legacyEmptySlots[0]), expectedFrxUsdKeeper);
        assertEq(legacyMonetaryPolicy.peg_keepers(legacyEmptySlots[1]), expectedUsdcKeeper);
        assertEq(legacyMonetaryPolicy.peg_keepers(legacyEmptySlots[2]), expectedUsdtKeeper);
    }

    function test_ProposalSetsExactSuggestedRoutes() public {
        _executeProposal();

        IPegKeeperV3 frxUsdKeeper = IPegKeeperV3(expectedFrxUsdKeeper);
        assertEq(frxUsdKeeper.expansion_path_length(), 0);
        assertEq(frxUsdKeeper.contraction_path_length(), 1);
        _assertStep(
            frxUsdKeeper.contraction_path_step(0),
            0,
            proposal.FRXUSD_CRVUSD_POOL(),
            proposal.FRXUSD(),
            proposal.CRVUSD(),
            0,
            1,
            3
        );

        _assertFrxUsdRoutes(IPegKeeperV3(expectedUsdcKeeper), proposal.USDC(), 1);
        _assertFrxUsdRoutes(IPegKeeperV3(expectedUsdtKeeper), proposal.USDT(), 2);
    }

    function test_ProposalSetsSharedFactoryAndKeeperPolicyDefaults() public {
        _executeProposal();

        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        assertEq(defaults_.admin, OWNERSHIP_AGENT);
        assertEq(defaults_.emergencyAdmin, proposal.CURVE_EMERGENCY_ADMIN());
        assertEq(defaults_.feeReceiver, proposal.FEE_SPLITTER());
        assertEq(defaults_.maxDeployedCrvUsd, USDT_CAP);
        assertEq(defaults_.targetAmmExecutionBufferBps, 3);
        assertEq(defaults_.minDownstreamAttemptGas, 1_500_000);
        assertEq(defaults_.fallbackSettlementGasReserve, 300_000);
        assertEq(defaults_.expansionMaxRouteLossBps, 5);

        _assertPolicy(IPegKeeperV3(expectedFrxUsdKeeper), FRXUSD_CAP);
        _assertPolicy(IPegKeeperV3(expectedUsdcKeeper), USDC_CAP);
        _assertPolicy(IPegKeeperV3(expectedUsdtKeeper), USDT_CAP);
    }

    function _executeProposal() internal {
        bytes memory script = proposal.buildProposalScript();
        vm.prank(CONVEX_VOTEPROXY);
        uint256 proposalId = OWNERSHIP_VOTE.newVote(
            script,
            "Deploy and register three paused PegKeeperV3 keepers for frxUSD, USDC, and USDT",
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
        bool yieldTokenIsErc4626,
        address targetOracle,
        address yieldOracle,
        uint256 cap
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.target_amm(), targetAmm);
        assertEq(keeper.target_asset(), targetAsset);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.yield_token(), yieldToken);
        assertEq(keeper.yield_token_is_erc4626(), yieldTokenIsErc4626);
        assertEq(keeper.target_oracle(), targetOracle);
        assertEq(keeper.yield_oracle(), yieldOracle);
        assertEq(keeper.min_target_oracle_price(), proposal.MIN_ORACLE_PRICE());
        assertEq(keeper.min_yield_oracle_price(), proposal.MIN_ORACLE_PRICE());
        assertEq(keeper.max_expansion_burst_bps(), 500);
        assertEq(keeper.expansion_refill_period(), 300);
        assertEq(keeper.max_deployed_crvusd(), cap);
        assertEq(keeper.expansion_pressure(), 0);
        assertEq(keeper.available_expansion_velocity(), cap * 500 / 10_000);
        assertEq(factory.implementationOf(keeperAddress), factory.implementation());
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.backing_deployment_paused());
        assertTrue(keeper.direct_buyback_paused());
        assertTrue(keeper.undeployed_contraction_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function _assertOracle(
        address adapter,
        address pool,
        address asset,
        address referenceAsset,
        bool inverted
    ) internal view {
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(adapter);
        assertEq(oracle.pool(), pool);
        assertEq(oracle.asset(), asset);
        assertEq(oracle.reference_asset(), referenceAsset);
        assertEq(oracle.inverted(), inverted);
        assertGe(oracle.price(), proposal.MIN_ORACLE_PRICE());
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), maxDelay);
        assertGe(oracle.price(), proposal.MIN_ORACLE_PRICE());
    }

    function _deployChainlinkOracle(address feed, uint256 maxDelay)
        internal
        returns (address deployed)
    {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(feed, maxDelay));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "oracle deployment failed");
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

    function _assertFrxUsdRoutes(IPegKeeperV3 keeper, address targetAsset, int128 threePoolIndex)
        internal
        view
    {
        bool isUsdt = targetAsset == proposal.USDT();
        assertEq(keeper.expansion_path_length(), isUsdt ? 2 : 1);
        assertEq(keeper.contraction_path_length(), isUsdt ? 3 : 2);
        uint256 mintIndex;
        if (isUsdt) {
            _assertStep(
                keeper.expansion_path_step(0),
                0,
                proposal.THREE_POOL(),
                proposal.USDT(),
                proposal.USDC(),
                threePoolIndex,
                1,
                3
            );
            mintIndex = 1;
        }
        _assertStep(
            keeper.expansion_path_step(mintIndex),
            4,
            proposal.FRXUSD_CUSTODIAN(),
            proposal.USDC(),
            proposal.FRXUSD(),
            0,
            0,
            1
        );
        _assertStep(
            keeper.contraction_path_step(0),
            5,
            proposal.FRXUSD_CUSTODIAN(),
            proposal.FRXUSD(),
            proposal.USDC(),
            0,
            0,
            1
        );
        uint256 targetAmmIndex = 1;
        if (isUsdt) {
            _assertStep(
                keeper.contraction_path_step(1),
                0,
                proposal.THREE_POOL(),
                proposal.USDC(),
                proposal.USDT(),
                1,
                threePoolIndex,
                3
            );
            targetAmmIndex = 2;
        }
        _assertStep(
            keeper.contraction_path_step(targetAmmIndex),
            0,
            keeper.target_amm(),
            targetAsset,
            proposal.CRVUSD(),
            0,
            1,
            3
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

    function _assertMonetaryPolicyAction(
        BaseCurveProposal.Action memory action,
        address monetaryPolicy,
        address keeper
    ) internal pure {
        assertEq(action.target, monetaryPolicy);
        assertEq(_selector(action.data), IAggMonetaryPolicy.add_peg_keeper.selector);
        assertEq(abi.decode(_withoutSelector(action.data), (address)), keeper);
    }

    function _firstThreeEmptySlots(IAggMonetaryPolicy monetaryPolicy)
        internal
        view
        returns (uint256[3] memory slots)
    {
        uint256 found;
        for (uint256 i; i < 1_000; ++i) {
            if (monetaryPolicy.peg_keepers(i) != address(0)) continue;
            slots[found] = i;
            ++found;
            if (found == slots.length) return slots;
        }
        revert("fewer than three policy slots");
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
