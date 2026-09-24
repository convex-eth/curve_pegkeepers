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
import {IERC20} from "../../../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../../../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperRegistry} from "../../../src/interfaces/IPegKeeperRegistry.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../../../src/interfaces/IStableSwap2Pool.sol";

contract CurveDebtCeilingProposalHarness is BaseCurveProposal {
    address internal immutable keeper;
    uint256 internal immutable ceiling;

    constructor(address keeper_, uint256 ceiling_) {
        keeper = keeper_;
        ceiling = ceiling_;
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        Action[] memory actions = new Action[](1);
        actions[0] = _executeViaCrvUsdEDAOProxy(
            CURVE_CRVUSD_CONTROLLER_FACTORY,
            abi.encodeCall(IControllerFactory.set_debt_ceiling, (keeper, ceiling))
        );
        script = buildScript(CURVE_OWNERSHIP_AGENT, actions);
    }
}

contract CurveProposalLaunchPegKeeperV3Test is Test {
    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant OWNERSHIP_VOTING = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant EDAO_PROXY = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address internal constant LEGACY_MONETARY_POLICY = 0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;
    address internal constant CONVEX_VOTEPROXY = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    address internal constant YEARN_VOTEPROXY = 0xF147b8125d2ef93FB6965Db97D6746952a133934;
    address internal constant SD_VOTEPROXY = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;

    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address internal constant USDC_CRVUSD_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    uint256 internal constant CAP = 150_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3 internal proposal;
    IPegKeeperPolicy internal keeperPolicy;
    IPegKeeperRegistry internal keeperRegistry;
    address internal expectedFrxUsdKeeper;
    address internal expectedUsdcKeeper;
    address internal expectedUsdtKeeper;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), 25_911_411
        );

        proposal = new CurveProposalLaunchPegKeeperV3();
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(deployer.mainnetConfig());
        address[3] memory oracles =
            [deployment.frxUsdUsdOracle, deployment.usdcUsdOracle, deployment.usdtUsdOracle];
        address[3] memory keepers =
            [deployment.frxUsdPegKeeper, deployment.usdcPegKeeper, deployment.usdtPegKeeper];
        proposal.setDeployment(deployment.policy, deployment.registry, oracles, keepers);

        keeperPolicy = IPegKeeperPolicy(deployment.policy);
        keeperRegistry = IPegKeeperRegistry(deployment.registry);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedUsdcKeeper = proposal.expectedKeeper(2);
        expectedUsdtKeeper = proposal.expectedKeeper(3);
    }

    function test_actionsRegisterPreconfiguredKeepersThenRegisterWithPoliciesAndFund() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 10);

        address[3] memory keepers = [expectedFrxUsdKeeper, expectedUsdcKeeper, expectedUsdtKeeper];
        _assertRegistryEnrollmentAction(actions[0], keepers);
        for (uint256 i; i < keepers.length; ++i) {
            _assertRegistrationAction(actions[1 + i * 2], MONETARY_POLICY, keepers[i]);
            _assertRegistrationAction(actions[2 + i * 2], LEGACY_MONETARY_POLICY, keepers[i]);
        }

        _assertDebtCeilingAction(actions[7], expectedFrxUsdKeeper, CAP);
        _assertDebtCeilingAction(actions[8], expectedUsdcKeeper, CAP);
        _assertDebtCeilingAction(actions[9], expectedUsdtKeeper, CAP);

        for (uint256 i; i < actions.length; ++i) {
            bytes4 selector = _selector(actions[i].data);
            assertNotEq(selector, IPegKeeperV3.set_backing_oracle_policy.selector);
            assertNotEq(selector, IPegKeeperV3.set_policy.selector);
            assertNotEq(selector, IPegKeeperV3.set_intervention_policy.selector);
            assertNotEq(selector, IPegKeeperV3.set_direction_paused.selector);
            assertNotEq(selector, bytes4(keccak256("remove_peg_keeper(address)")));
            assertNotEq(selector, bytes4(keccak256("remove_peg_keepers(address[])")));
            assertNotEq(selector, bytes4(keccak256("remove_price_pair(uint256)")));
            assertNotEq(selector, bytes4(keccak256("set_new_regulator(address)")));
        }
    }

    function test_proposalRejectsMutatedKeeperBytecode() public {
        vm.etch(expectedFrxUsdKeeper, bytes.concat(expectedFrxUsdKeeper.code, hex"00"));
        vm.expectRevert(bytes("keeper size"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsMutatedPolicyRegistryAndOracleBytecode() public {
        bytes memory policyCode = address(keeperPolicy).code;
        vm.etch(address(keeperPolicy), bytes.concat(policyCode, hex"00"));
        vm.expectRevert(bytes("policy size"));
        proposal.buildProposalActions();
        vm.etch(address(keeperPolicy), policyCode);

        bytes memory registryCode = address(keeperRegistry).code;
        vm.etch(address(keeperRegistry), bytes.concat(registryCode, hex"00"));
        vm.expectRevert(bytes("registry size"));
        proposal.buildProposalActions();
        vm.etch(address(keeperRegistry), registryCode);

        address oracle = proposal.frxUsdOracle();
        vm.etch(oracle, bytes.concat(oracle.code, hex"00"));
        vm.expectRevert(bytes("chainlink oracle size"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsSameSizeCodeHashDrift() public {
        bytes memory keeperCode = expectedFrxUsdKeeper.code;
        vm.etch(expectedFrxUsdKeeper, _flipByteFromEnd(keeperCode, 33));
        vm.expectRevert(bytes("keeper hash"));
        proposal.buildProposalActions();
        vm.etch(expectedFrxUsdKeeper, keeperCode);

        bytes memory policyCode = address(keeperPolicy).code;
        vm.etch(address(keeperPolicy), _flipByteFromEnd(policyCode, 1));
        vm.expectRevert(bytes("policy hash"));
        proposal.buildProposalActions();
        vm.etch(address(keeperPolicy), policyCode);

        bytes memory registryCode = address(keeperRegistry).code;
        vm.etch(address(keeperRegistry), _flipByteFromEnd(registryCode, 1));
        vm.expectRevert(bytes("registry hash"));
        proposal.buildProposalActions();
        vm.etch(address(keeperRegistry), registryCode);

        address oracle = proposal.frxUsdOracle();
        bytes memory oracleCode = oracle.code;
        vm.etch(oracle, _flipByteFromEnd(oracleCode, 97));
        vm.expectRevert(bytes("chainlink oracle hash"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsWrongKeeperLocalRewardShare() public {
        vm.prank(OWNERSHIP_AGENT);
        IPegKeeperV3(expectedFrxUsdKeeper).set_keeper_profit_share_bps(2_999);

        vm.expectRevert(bytes("profit share"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsWrongGlobalPolicyFeeReceiver() public {
        vm.prank(OWNERSHIP_AGENT);
        keeperPolicy.set_fee_receiver(makeAddr("wrong fee receiver"));

        vm.expectRevert(bytes("fee receiver"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsPausedOrPrefundedCandidate() public {
        vm.prank(OWNERSHIP_AGENT);
        IPegKeeperV3(expectedFrxUsdKeeper).set_direction_paused(0, true);
        vm.expectRevert(bytes("keeper expansion paused"));
        proposal.buildProposalActions();

        vm.prank(OWNERSHIP_AGENT);
        IPegKeeperV3(expectedFrxUsdKeeper).set_direction_paused(0, false);
        vm.prank(OWNERSHIP_AGENT);
        ICurveEDAOAdminProxy(EDAO_PROXY)
            .execute(
                CONTROLLER_FACTORY,
                abi.encodeCall(IControllerFactory.set_debt_ceiling, (expectedFrxUsdKeeper, 1))
            );
        vm.expectRevert(bytes("keeper prefunded"));
        proposal.buildProposalActions();
    }

    function test_proposalActivatesAndFundsThreePreconfiguredKeepers() public {
        uint256[3] memory currentPolicySlots =
            _firstThreeEmptySlots(IAggMonetaryPolicy(MONETARY_POLICY));
        uint256[3] memory legacySlots =
            _firstThreeEmptySlots(IAggMonetaryPolicy(LEGACY_MONETARY_POLICY));
        assertEq(keeperPolicy.owner(), OWNERSHIP_AGENT);
        assertEq(keeperPolicy.pendingOwner(), address(0));
        assertEq(keeperRegistry.owner(), OWNERSHIP_AGENT);
        assertEq(keeperRegistry.pendingOwner(), address(0));
        assertEq(keeperRegistry.peg_keeper_count(), 0);
        _executeProposal();

        assertEq(keeperPolicy.owner(), OWNERSHIP_AGENT);
        assertEq(keeperPolicy.pendingOwner(), address(0));
        assertEq(keeperRegistry.peg_keeper_count(), 3);
        assertEq(keeperRegistry.peg_keepers(0), expectedFrxUsdKeeper);
        assertEq(keeperRegistry.peg_keepers(1), expectedUsdcKeeper);
        assertEq(keeperRegistry.peg_keepers(2), expectedUsdtKeeper);

        _assertKeeper(
            expectedFrxUsdKeeper,
            proposal.FRXUSD_CRVUSD_POOL(),
            FRXUSD,
            FRXUSD,
            false,
            true,
            proposal.frxUsdOracle()
        );
        _assertKeeper(
            expectedUsdcKeeper,
            proposal.USDC_CRVUSD_POOL(),
            USDC,
            USDC,
            false,
            false,
            proposal.usdcOracle()
        );
        _assertKeeper(
            expectedUsdtKeeper,
            proposal.USDT_CRVUSD_POOL(),
            USDT,
            USDT,
            false,
            false,
            proposal.usdtOracle()
        );

        assertTrue(keeperPolicy.can_expand());

        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedFrxUsdKeeper), CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdcKeeper), CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdtKeeper), CAP);

        address[3] memory keepers = [expectedFrxUsdKeeper, expectedUsdcKeeper, expectedUsdtKeeper];
        for (uint256 i; i < keepers.length; ++i) {
            assertEq(
                IAggMonetaryPolicy(MONETARY_POLICY).peg_keepers(currentPolicySlots[i]), keepers[i]
            );
            assertEq(
                IAggMonetaryPolicy(LEGACY_MONETARY_POLICY).peg_keepers(legacySlots[i]), keepers[i]
            );
        }
    }

    function test_liveControllerFactoryCanBurnUnusedV3Allocation() public {
        _executeProposal();
        IControllerFactory controllerFactory = IControllerFactory(CONTROLLER_FACTORY);
        IERC20 crvUsd = IERC20(controllerFactory.stablecoin());

        assertEq(crvUsd.balanceOf(expectedFrxUsdKeeper), CAP);
        assertEq(crvUsd.allowance(expectedFrxUsdKeeper, CONTROLLER_FACTORY), type(uint256).max);
        assertEq(controllerFactory.debt_ceiling_residual(expectedFrxUsdKeeper), CAP);

        CurveDebtCeilingProposalHarness zeroCeilingProposal =
            new CurveDebtCeilingProposalHarness(expectedFrxUsdKeeper, 0);
        _executeOwnershipVote(
            zeroCeilingProposal.buildProposalScript(), "Remove unused PegKeeperV3 allocation"
        );

        assertEq(crvUsd.balanceOf(expectedFrxUsdKeeper), 0);
        assertEq(controllerFactory.debt_ceiling(expectedFrxUsdKeeper), 0);
        assertEq(controllerFactory.debt_ceiling_residual(expectedFrxUsdKeeper), 0);
    }

    function test_eachKeeperUsesConfiguredSoftProfitFloors() public {
        _executeActionsDirectly();

        assertEq(IPegKeeperV3(expectedFrxUsdKeeper).entry_min_profit_ppm(), 10);
        assertEq(IPegKeeperV3(expectedFrxUsdKeeper).normal_exit_min_profit_ppm(), 150);
        assertEq(IPegKeeperV3(expectedUsdcKeeper).entry_min_profit_ppm(), 300);
        assertEq(IPegKeeperV3(expectedUsdcKeeper).normal_exit_min_profit_ppm(), 80);
        assertEq(IPegKeeperV3(expectedUsdtKeeper).entry_min_profit_ppm(), 300);
        assertEq(IPegKeeperV3(expectedUsdtKeeper).normal_exit_min_profit_ppm(), 80);
    }

    function test_oneKeeperCooldownDoesNotBlockAnotherInSameBlock() public {
        _executeActionsDirectly();

        address trader = makeAddr("frxUSD expansion trader");
        uint256 marketTrade = 2_000_000e18;
        deal(FRXUSD, trader, marketTrade);
        vm.startPrank(trader);
        IERC20(FRXUSD).approve(FRXUSD_CRVUSD_POOL, marketTrade);
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(0, 1, marketTrade, 0);
        vm.stopPrank();

        address usdcTrader = makeAddr("USDC expansion trader");
        uint256 usdcTradeChunk = 2_000_000e6;
        deal(USDC, usdcTrader, 6_000_000e6);
        vm.startPrank(usdcTrader);
        IERC20(USDC).approve(USDC_CRVUSD_POOL, 6_000_000e6);
        for (uint256 i; i < 3; ++i) {
            IStableSwap2Pool(USDC_CRVUSD_POOL).exchange(0, 1, usdcTradeChunk, 0);
        }
        vm.stopPrank();

        IPegKeeperV3 frxUsdKeeper = IPegKeeperV3(expectedFrxUsdKeeper);
        IPegKeeperV3 usdcKeeper = IPegKeeperV3(expectedUsdcKeeper);
        assertTrue(keeperPolicy.can_expand());
        assertTrue(usdcKeeper.can_expand_without_policy());

        frxUsdKeeper.expand_supply();

        assertFalse(frxUsdKeeper.can_expand_without_policy());
        assertTrue(keeperPolicy.can_expand());
        (uint256 debtAdded, uint256 lpReceived,) = usdcKeeper.expand_supply();
        assertGt(debtAdded, 0);
        assertGt(lpReceived, 0);
    }

    function _executeProposal() internal {
        _executeOwnershipVote(
            proposal.buildProposalScript(),
            "Activate and fund three standalone direct PegKeeperV3 keepers"
        );
    }

    function _executeOwnershipVote(bytes memory script, string memory description) internal {
        vm.prank(CONVEX_VOTEPROXY);
        uint256 proposalId = OWNERSHIP_VOTE.newVote(script, description, false, false);

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

    function _executeActionsDirectly() internal {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(OWNERSHIP_AGENT);
            (bool success, bytes memory result) = actions[i].target.call(actions[i].data);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }

    function _assertKeeper(
        address keeperAddress,
        address amm,
        address yieldToken,
        address backingAsset,
        bool isErc4626,
        bool usesDynamicArrays,
        address oracle
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.pool(), amm);
        assertEq(keeper.paired_token(), yieldToken);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.paired_token_is_erc4626(), isErc4626);
        assertEq(keeper.pool_uses_dynamic_arrays(), usesDynamicArrays);
        assertEq(keeper.backing_oracle(), oracle);
        assertEq(keeper.min_backing_oracle_price(), proposal.MIN_BACKING_ORACLE_PRICE());
        assertEq(keeper.keeper_profit_share_bps(), proposal.KEEPER_PROFIT_SHARE_BPS());
        assertEq(keeper.max_debt(), CAP);
        assertEq(keeper.debt(), 0);
        assertTrue(keeperRegistry.is_active(keeperAddress));
        assertFalse(keeper.expansion_paused());
        assertFalse(keeper.contraction_paused());
        assertFalse(keeper.all_execution_paused());
    }

    function _assertRegistryEnrollmentAction(
        BaseCurveProposal.Action memory action,
        address[3] memory expectedKeepers
    ) internal view {
        assertEq(action.target, address(keeperRegistry));
        assertEq(_selector(action.data), IPegKeeperRegistry.add_peg_keepers.selector);
        address[] memory keepers = abi.decode(_withoutSelector(action.data), (address[]));
        assertEq(keepers.length, expectedKeepers.length);
        for (uint256 i; i < keepers.length; ++i) {
            assertEq(keepers[i], expectedKeepers[i]);
        }
    }

    function _assertRegistrationAction(
        BaseCurveProposal.Action memory action,
        address monetaryPolicy,
        address keeper
    ) internal pure {
        assertEq(action.target, monetaryPolicy);
        assertEq(_selector(action.data), IAggMonetaryPolicy.add_peg_keeper.selector);
        assertEq(abi.decode(_withoutSelector(action.data), (address)), keeper);
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
        (address configuredKeeper, uint256 configuredCap) =
            abi.decode(_withoutSelector(innerData), (address, uint256));
        assertEq(configuredKeeper, keeper);
        assertEq(configuredCap, cap);
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
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _flipByteFromEnd(bytes memory code, uint256 offsetFromEnd)
        internal
        pure
        returns (bytes memory mutated)
    {
        require(offsetFromEnd > 0 && offsetFromEnd <= code.length, "invalid byte offset");
        mutated = bytes.concat(code);
        uint256 index = mutated.length - offsetFromEnd;
        mutated[index] = bytes1(uint8(mutated[index]) ^ 1);
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory result) {
        result = new bytes(data.length - 4);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[i + 4];
        }
    }
}
