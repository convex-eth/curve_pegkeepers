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

contract SpoofPegKeeperV3Factory {
    address public immutable owner;
    address public immutable controllerFactory;
    address public immutable aggregateCrvUsdOracle;
    address public immutable implementation;
    uint256 public keeperCount;

    constructor(
        address owner_,
        address controllerFactory_,
        address aggregateCrvUsdOracle_,
        address implementation_
    ) {
        owner = owner_;
        controllerFactory = controllerFactory_;
        aggregateCrvUsdOracle = aggregateCrvUsdOracle_;
        implementation = implementation_;
    }
}

contract SpoofChainlinkStablecoinOracle {
    address public immutable feed;
    uint256 public immutable feed_decimals = 8;
    uint256 public immutable max_delay;

    constructor(address feed_, uint256 maxDelay_) {
        feed = feed_;
        max_delay = maxDelay_;
    }

    function price() external pure returns (uint256) {
        return 1e18;
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

    uint256 internal constant FRXUSD_CAP = 20_000_000e18;
    uint256 internal constant USDC_CAP = 20_000_000e18;
    uint256 internal constant USDT_CAP = 20_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3 internal proposal;
    IPegKeeperV3Factory internal factory;
    address internal expectedFrxUsdKeeper;
    address internal expectedUsdcKeeper;
    address internal expectedUsdtKeeper;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), 25_868_730
        );
        // This repository targets Shanghai bytecode. The live eDAO proxy now executes an opcode
        // from a later fork after forwarding the call, so use an ABI-equivalent forwarding harness
        // while retaining the real proxy address and ControllerFactory authorization boundary.
        CurveEDAOProxyHarness proxyHarness = new CurveEDAOProxyHarness();
        vm.etch(EDAO_PROXY, address(proxyHarness).code);

        proposal = new CurveProposalLaunchPegKeeperV3();
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(deployer.mainnetConfig());
        proposal.setOracleAdapter(deployment.frxUsdUsdOracle);

        factory = IPegKeeperV3Factory(deployment.factory);

        proposal.setDeploymentFactory(deployment.factory);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedUsdcKeeper = proposal.expectedKeeper(2);
        expectedUsdtKeeper = proposal.expectedKeeper(3);
    }

    function test_ProposalActionsOnlyConfigureNewV3Keepers() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 22);

        assertEq(actions[0].target, address(factory));
        assertEq(_selector(actions[0].data), IPegKeeperV3Factory.setDefaults.selector);
        assertEq(actions[1].target, address(factory));
        assertEq(_selector(actions[1].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        _assertYieldOraclePolicyAction(actions[2], expectedFrxUsdKeeper);
        assertEq(actions[3].target, expectedFrxUsdKeeper);
        assertEq(_selector(actions[3].data), IPegKeeperV3.set_policy.selector);
        assertEq(actions[4].target, expectedFrxUsdKeeper);
        assertEq(_selector(actions[4].data), IPegKeeperV3.set_intervention_policy.selector);
        _assertDebtCeilingAction(actions[5], expectedFrxUsdKeeper, FRXUSD_CAP);
        _assertMonetaryPolicyAction(actions[6], MONETARY_POLICY, expectedFrxUsdKeeper);
        _assertMonetaryPolicyAction(actions[7], LEGACY_MONETARY_POLICY, expectedFrxUsdKeeper);

        assertEq(actions[8].target, address(factory));
        assertEq(_selector(actions[8].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        _assertYieldOraclePolicyAction(actions[9], expectedUsdcKeeper);
        assertEq(actions[10].target, expectedUsdcKeeper);
        assertEq(_selector(actions[10].data), IPegKeeperV3.set_policy.selector);
        assertEq(actions[11].target, expectedUsdcKeeper);
        assertEq(_selector(actions[11].data), IPegKeeperV3.set_intervention_policy.selector);
        _assertDebtCeilingAction(actions[12], expectedUsdcKeeper, USDC_CAP);
        _assertMonetaryPolicyAction(actions[13], MONETARY_POLICY, expectedUsdcKeeper);
        _assertMonetaryPolicyAction(actions[14], LEGACY_MONETARY_POLICY, expectedUsdcKeeper);

        assertEq(actions[15].target, address(factory));
        assertEq(_selector(actions[15].data), IPegKeeperV3Factory.deployPegKeeper.selector);
        _assertYieldOraclePolicyAction(actions[16], expectedUsdtKeeper);
        assertEq(actions[17].target, expectedUsdtKeeper);
        assertEq(_selector(actions[17].data), IPegKeeperV3.set_policy.selector);
        assertEq(actions[18].target, expectedUsdtKeeper);
        assertEq(_selector(actions[18].data), IPegKeeperV3.set_intervention_policy.selector);
        _assertDebtCeilingAction(actions[19], expectedUsdtKeeper, USDT_CAP);
        _assertMonetaryPolicyAction(actions[20], MONETARY_POLICY, expectedUsdtKeeper);
        _assertMonetaryPolicyAction(actions[21], LEGACY_MONETARY_POLICY, expectedUsdtKeeper);
    }

    function test_OracleAdapterUsesSelectedFrxUsdChainlinkFeed() public view {
        _assertChainlinkOracle(
            proposal.frxUsdOracle(), proposal.FRXUSD_USD_PROXY(), proposal.CHAINLINK_MAX_DELAY()
        );
    }

    function test_AggregateCrvUsdOracleIsCanonicalAndLive() public view {
        address oracle = factory.aggregateCrvUsdOracle();
        assertEq(oracle, proposal.CRVUSD_AGGREGATE_ORACLE());

        (bool success, bytes memory response) =
            oracle.staticcall(abi.encodeWithSignature("price()"));
        assertTrue(success);
        assertEq(response.length, 32);
        uint256 price = abi.decode(response, (uint256));
        assertGt(price, 0.9e18);
        assertLt(price, 1.1e18);
    }

    function test_FactoryRuntimeMatchesProposalIdentityPin() public view {
        bytes memory runtime = address(factory).code;
        assertEq(runtime.length, proposal.FACTORY_RUNTIME_SIZE());
        uint256 coreSize = proposal.FACTORY_CORE_SIZE();
        bytes32 coreHash;
        assembly {
            coreHash := keccak256(add(runtime, 0x20), coreSize)
        }
        assertEq(coreHash, proposal.EXPECTED_FACTORY_CORE_HASH());
    }

    function test_OracleRuntimesMatchProposalIdentityPins() public view {
        bytes memory chainlinkRuntime = proposal.frxUsdOracle().code;
        assertEq(chainlinkRuntime.length, proposal.CHAINLINK_ORACLE_RUNTIME_SIZE());
        uint256 chainlinkCoreSize = proposal.CHAINLINK_ORACLE_CORE_SIZE();
        bytes32 chainlinkCoreHash;
        assembly {
            chainlinkCoreHash := keccak256(add(chainlinkRuntime, 0x20), chainlinkCoreSize)
        }
        assertEq(chainlinkCoreHash, proposal.EXPECTED_CHAINLINK_ORACLE_CORE_HASH());
    }

    function test_ProposalRejectsSwappedChainlinkFeeds() public {
        address wrongFrxUsdOracle =
            _deployChainlinkOracle(WRONG_FRXUSD_FEED, proposal.CHAINLINK_MAX_DELAY());
        proposal.setOracleAdapter(wrongFrxUsdOracle);

        vm.expectRevert("oracle feed");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsChainlinkDelayDrift() public {
        address frxUsdOracle = _deployChainlinkOracle(proposal.FRXUSD_USD_PROXY(), 24 hours);
        proposal.setOracleAdapter(frxUsdOracle);

        vm.expectRevert("oracle delay");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsSpoofFactoryWithCorrectGetters() public {
        SpoofPegKeeperV3Factory spoof = new SpoofPegKeeperV3Factory(
            proposal.CURVE_OWNERSHIP_AGENT(),
            proposal.CURVE_CRVUSD_CONTROLLER_FACTORY(),
            proposal.CRVUSD_AGGREGATE_ORACLE(),
            factory.implementation()
        );
        proposal.setDeploymentFactory(address(spoof));

        vm.expectRevert("factory size");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsFactoryWithPendingOwner() public {
        vm.prank(OWNERSHIP_AGENT);
        factory.transferOwnership(makeAddr("pending factory owner"));

        vm.expectRevert("factory pending owner");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsSpoofChainlinkOracleWithCorrectGetters() public {
        SpoofChainlinkStablecoinOracle spoof = new SpoofChainlinkStablecoinOracle(
            proposal.FRXUSD_USD_PROXY(), proposal.CHAINLINK_MAX_DELAY()
        );
        proposal.setOracleAdapter(address(spoof));

        vm.expectRevert("chainlink oracle size");
        proposal.buildProposalActions();
    }

    function test_ProposalRejectsSameSizeMutatedChainlinkOracle() public {
        address adapter = proposal.frxUsdOracle();
        bytes memory runtime = adapter.code;
        runtime[0] = bytes1(uint8(runtime[0]) ^ 1);
        vm.etch(adapter, runtime);

        vm.expectRevert("chainlink oracle hash");
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
            proposal.FRXUSD_CRVUSD_POOL(),
            false,
            proposal.frxUsdOracle(),
            FRXUSD_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdcKeeper,
            proposal.USDC_CRVUSD_POOL(),
            proposal.USDC(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            proposal.FRXUSD_CRVUSD_POOL(),
            false,
            proposal.frxUsdOracle(),
            USDC_CAP
        );
        _assertKeeperEndpoints(
            expectedUsdtKeeper,
            proposal.USDT_CRVUSD_POOL(),
            proposal.USDT(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            proposal.FRXUSD_CRVUSD_POOL(),
            false,
            proposal.frxUsdOracle(),
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
        assertEq(frxUsdKeeper.yield_amm(), proposal.FRXUSD_CRVUSD_POOL());

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
        assertEq(defaults_.yieldAmmExecutionBufferBps, 3);
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
        address yieldAmm,
        bool yieldTokenIsErc4626,
        address yieldOracle,
        uint256 cap
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.target_amm(), targetAmm);
        assertEq(keeper.target_asset(), targetAsset);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.yield_token(), yieldToken);
        assertEq(keeper.yield_amm(), yieldAmm);
        assertEq(keeper.coins(1), yieldAmm);
        assertEq(keeper.yield_token_is_erc4626(), yieldTokenIsErc4626);
        assertEq(keeper.yield_oracle(), yieldOracle);
        assertEq(keeper.min_yield_oracle_price(), proposal.MIN_YIELD_ORACLE_PRICE());
        assertEq(keeper.max_expansion_burst_bps(), 500);
        assertEq(keeper.expansion_refill_period(), 300);
        assertEq(keeper.max_deployed_crvusd(), cap);
        assertEq(keeper.expansion_pressure(), 0);
        assertEq(keeper.available_expansion_velocity(), cap * 500 / 10_000);
        assertEq(factory.implementationOf(keeperAddress), factory.implementation());
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function _assertChainlinkOracle(address adapter, address feed, uint256 maxDelay) internal view {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertEq(oracle.feed(), feed);
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), maxDelay);
        assertGe(oracle.price(), proposal.MIN_YIELD_ORACLE_PRICE());
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
        assertEq(keeper.normal_exit_min_profit_ppm(), 500);
        assertEq(keeper.keeper_profit_share_bps(), 3_000);
        assertEq(keeper.min_expansion_amount(), 10_000e18);
        assertEq(keeper.max_deployed_crvusd(), cap);
        assertEq(keeper.max_intervention_share_bps(), 3_333);
        assertEq(keeper.min_intervention_delay(), 12);
        assertEq(keeper.last_intervention_at(), 0);
    }

    function _assertFrxUsdRoutes(IPegKeeperV3 keeper, address targetAsset, int128 threePoolIndex)
        internal
        view
    {
        bool isUsdt = targetAsset == proposal.USDT();
        assertEq(keeper.expansion_path_length(), isUsdt ? 2 : 1);
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

    function _assertYieldOraclePolicyAction(BaseCurveProposal.Action memory action, address keeper)
        internal
        view
    {
        assertEq(action.target, keeper);
        assertEq(_selector(action.data), IPegKeeperV3.set_yield_oracle_policy.selector);
        (address oracle, uint256 minimum) =
            abi.decode(_withoutSelector(action.data), (address, uint256));
        assertEq(oracle, proposal.frxUsdOracle());
        assertEq(minimum, proposal.MIN_YIELD_ORACLE_PRICE());
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
