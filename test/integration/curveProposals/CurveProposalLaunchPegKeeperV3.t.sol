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
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
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
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;

    uint256 internal constant CAP = 20_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3 internal proposal;
    IPegKeeperV3Factory internal factory;
    IPegKeeperPolicy internal keeperPolicy;
    address internal expectedFrxUsdKeeper;
    address internal expectedSUsdeKeeper;
    address internal expectedUsdcKeeper;
    address internal expectedUsdtKeeper;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), 25_911_411
        );

        proposal = new CurveProposalLaunchPegKeeperV3();
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment =
            deployer.deploy(deployer.mainnetConfig(address(deployer)));
        address[4] memory oracles = [
            deployment.frxUsdUsdOracle,
            deployment.usdeUsdOracle,
            deployment.usdcUsdOracle,
            deployment.usdtUsdOracle
        ];
        address[4] memory keepers = [
            deployment.frxUsdPegKeeper,
            deployment.sUsdePegKeeper,
            deployment.usdcPegKeeper,
            deployment.usdtPegKeeper
        ];
        uint256[2] memory handoffNonces =
            [deployment.factoryOwnershipNonce, deployment.policyOwnershipNonce];
        proposal.setDeployment(
            deployment.initialOwner,
            deployment.factory,
            deployment.policy,
            oracles,
            keepers,
            handoffNonces
        );

        factory = IPegKeeperV3Factory(deployment.factory);
        keeperPolicy = IPegKeeperPolicy(deployment.policy);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedSUsdeKeeper = proposal.expectedKeeper(2);
        expectedUsdcKeeper = proposal.expectedKeeper(3);
        expectedUsdtKeeper = proposal.expectedKeeper(4);
    }

    function test_actionsAcceptPreconfiguredKeepersThenRegisterAndFund() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 13);

        _assertOwnershipAcceptance(actions[0], address(factory), factory.ownershipTransferNonce());
        _assertOwnershipAcceptance(
            actions[1], address(keeperPolicy), keeperPolicy.ownershipTransferNonce()
        );

        address[4] memory keepers =
            [expectedFrxUsdKeeper, expectedSUsdeKeeper, expectedUsdcKeeper, expectedUsdtKeeper];
        for (uint256 i; i < keepers.length; ++i) {
            _assertRegistrationAction(actions[2 + i * 2], MONETARY_POLICY, keepers[i]);
            _assertRegistrationAction(actions[3 + i * 2], LEGACY_MONETARY_POLICY, keepers[i]);
        }

        _assertDebtCeilingAction(actions[10], expectedFrxUsdKeeper, CAP);
        _assertDebtCeilingAction(actions[11], expectedUsdcKeeper, CAP);
        _assertDebtCeilingAction(actions[12], expectedUsdtKeeper, CAP);

        for (uint256 i; i < actions.length; ++i) {
            bytes4 selector = _selector(actions[i].data);
            assertNotEq(selector, IPegKeeperV3Factory.deployPegKeeper.selector);
            assertNotEq(selector, IPegKeeperV3Factory.setDefaults.selector);
            assertNotEq(selector, IPegKeeperPolicy.set_factory.selector);
            assertNotEq(selector, IPegKeeperPolicy.set_tier.selector);
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

    function test_proposalRejectsMutatedCodeBearingDependencies() public {
        address implementation = factory.implementation();
        vm.etch(implementation, bytes.concat(implementation.code, hex"00"));
        vm.expectRevert(bytes("implementation size"));
        proposal.buildProposalActions();
    }

    function test_proposalRejectsMutatedPolicyFactoryAndOracleBytecode() public {
        bytes memory policyCode = address(keeperPolicy).code;
        vm.etch(address(keeperPolicy), bytes.concat(policyCode, hex"00"));
        vm.expectRevert(bytes("policy size"));
        proposal.buildProposalActions();
        vm.etch(address(keeperPolicy), policyCode);

        bytes memory factoryCode = address(factory).code;
        vm.etch(address(factory), bytes.concat(factoryCode, hex"00"));
        vm.expectRevert(bytes("factory size"));
        proposal.buildProposalActions();
        vm.etch(address(factory), factoryCode);

        address oracle = proposal.frxUsdOracle();
        vm.etch(oracle, bytes.concat(oracle.code, hex"00"));
        vm.expectRevert(bytes("chainlink oracle size"));
        proposal.buildProposalActions();
    }

    function test_pendingOwnershipRedirectInvalidatesReviewedProposal() public {
        BaseCurveProposal.Action[] memory reviewedActions = proposal.buildProposalActions();

        vm.prank(proposal.deploymentInitialOwner());
        factory.transferOwnership(makeAddr("wrong pending owner"));

        assertEq(factory.ownershipTransferNonce(), 2);
        vm.expectRevert(bytes("factory pending owner"));
        proposal.buildProposalActions();

        vm.prank(proposal.deploymentInitialOwner());
        factory.transferOwnership(OWNERSHIP_AGENT);
        assertEq(factory.pendingOwner(), OWNERSHIP_AGENT);
        assertEq(factory.ownershipTransferNonce(), 3);
        vm.expectRevert(bytes("factory handoff nonce"));
        proposal.buildProposalActions();

        vm.prank(OWNERSHIP_AGENT);
        vm.expectRevert(IPegKeeperV3Factory.InvalidOwnershipTransferNonce.selector);
        factory.acceptOwnership(_ownershipAcceptanceNonce(reviewedActions[0]));
        assertEq(factory.owner(), proposal.deploymentInitialOwner());
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

    function test_proposalAcceptsFourActivePreconfiguredKeepersAndFundsThree() public {
        uint256[4] memory primarySlots = _firstFourEmptySlots(IAggMonetaryPolicy(MONETARY_POLICY));
        uint256[4] memory legacySlots =
            _firstFourEmptySlots(IAggMonetaryPolicy(LEGACY_MONETARY_POLICY));
        assertEq(factory.owner(), proposal.deploymentInitialOwner());
        assertEq(factory.pendingOwner(), OWNERSHIP_AGENT);
        assertEq(keeperPolicy.owner(), proposal.deploymentInitialOwner());
        assertEq(keeperPolicy.pendingOwner(), OWNERSHIP_AGENT);
        _executeProposal();

        assertEq(factory.owner(), OWNERSHIP_AGENT);
        assertEq(factory.pendingOwner(), address(0));
        assertEq(keeperPolicy.owner(), OWNERSHIP_AGENT);
        assertEq(keeperPolicy.pendingOwner(), address(0));
        assertEq(factory.activePegKeeperCount(), 4);
        assertEq(factory.activePegKeeperAt(0), expectedFrxUsdKeeper);
        assertEq(factory.activePegKeeperAt(1), expectedSUsdeKeeper);
        assertEq(factory.activePegKeeperAt(2), expectedUsdcKeeper);
        assertEq(factory.activePegKeeperAt(3), expectedUsdtKeeper);

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
            expectedSUsdeKeeper,
            proposal.SUSDE_CRVUSD_POOL(),
            SUSDE,
            USDE,
            true,
            true,
            proposal.usdeOracle()
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

        assertEq(keeperPolicy.factory(), address(factory));
        assertEq(keeperPolicy.primary(), expectedFrxUsdKeeper);
        assertEq(keeperPolicy.tier(expectedFrxUsdKeeper), 1);
        assertEq(keeperPolicy.tier(expectedSUsdeKeeper), 2);
        assertEq(keeperPolicy.tier(expectedUsdcKeeper), 3);
        assertEq(keeperPolicy.tier(expectedUsdtKeeper), 3);
        assertEq(keeperPolicy.secondaryCount(), 1);
        assertEq(keeperPolicy.secondaryAt(0), expectedSUsdeKeeper);
        assertEq(keeperPolicy.tertiaryCount(), 2);

        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedFrxUsdKeeper), CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedSUsdeKeeper), 0);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdcKeeper), CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedUsdtKeeper), CAP);

        address[4] memory keepers =
            [expectedFrxUsdKeeper, expectedSUsdeKeeper, expectedUsdcKeeper, expectedUsdtKeeper];
        for (uint256 i; i < keepers.length; ++i) {
            assertEq(IAggMonetaryPolicy(MONETARY_POLICY).peg_keepers(primarySlots[i]), keepers[i]);
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

    function test_eachTierUsesConfiguredProfitFloors() public {
        _executeActionsDirectly();

        assertEq(IPegKeeperV3(expectedFrxUsdKeeper).entry_min_profit_ppm(), 10);
        assertEq(IPegKeeperV3(expectedFrxUsdKeeper).normal_exit_min_profit_ppm(), 150);
        assertEq(IPegKeeperV3(expectedSUsdeKeeper).entry_min_profit_ppm(), 10);
        assertEq(IPegKeeperV3(expectedSUsdeKeeper).normal_exit_min_profit_ppm(), 110);

        assertEq(IPegKeeperV3(expectedUsdcKeeper).entry_min_profit_ppm(), 400);
        assertEq(IPegKeeperV3(expectedUsdcKeeper).normal_exit_min_profit_ppm(), 80);
        assertEq(IPegKeeperV3(expectedUsdtKeeper).entry_min_profit_ppm(), 400);
        assertEq(IPegKeeperV3(expectedUsdtKeeper).normal_exit_min_profit_ppm(), 80);
    }

    function test_secondaryCanExpandWhenPausedPrimaryCannot() public {
        _executeActionsDirectly();
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedSUsdeKeeper), 0);

        vm.prank(OWNERSHIP_AGENT);
        IPegKeeperV3(expectedFrxUsdKeeper).set_direction_paused(0, true);
        vm.prank(OWNERSHIP_AGENT);
        ICurveEDAOAdminProxy(EDAO_PROXY)
            .execute(
                CONTROLLER_FACTORY,
                abi.encodeCall(
                    IControllerFactory.set_debt_ceiling, (expectedSUsdeKeeper, 20_000e18)
                )
            );
        IPegKeeperV3 sUsdeKeeper = IPegKeeperV3(expectedSUsdeKeeper);

        assertFalse(IPegKeeperV3(expectedFrxUsdKeeper).can_expand_without_policy());
        assertTrue(keeperPolicy.can_expand(expectedSUsdeKeeper));
        (uint256 expectedDebt,,, uint256 expectedLp) = sUsdeKeeper.preview_expansion(10_000e18);
        assertEq(expectedDebt, 10_000e18);
        assertGt(expectedLp, 0);

        (uint256 debtAdded, uint256 lpReceived,) = sUsdeKeeper.expand_supply(10_000e18);
        assertEq(debtAdded, 10_000e18);
        assertGt(lpReceived, 0);
        assertGe(sUsdeKeeper.trusted_backing_value(), sUsdeKeeper.deployed_crvusd());
    }

    function test_primaryCooldownCannotUnlockSecondaryInSameBlock() public {
        _executeActionsDirectly();
        vm.prank(OWNERSHIP_AGENT);
        ICurveEDAOAdminProxy(EDAO_PROXY)
            .execute(
                CONTROLLER_FACTORY,
                abi.encodeCall(
                    IControllerFactory.set_debt_ceiling, (expectedSUsdeKeeper, 20_000_000e18)
                )
            );

        address trader = makeAddr("frxUSD expansion trader");
        uint256 marketTrade = 2_000_000e18;
        deal(FRXUSD, trader, marketTrade);
        vm.startPrank(trader);
        IERC20(FRXUSD).approve(FRXUSD_CRVUSD_POOL, marketTrade);
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(0, 1, marketTrade, 0);
        vm.stopPrank();

        IPegKeeperV3 primaryKeeper = IPegKeeperV3(expectedFrxUsdKeeper);
        IPegKeeperV3 secondaryKeeper = IPegKeeperV3(expectedSUsdeKeeper);
        assertTrue(keeperPolicy.can_expand(expectedFrxUsdKeeper));
        assertTrue(secondaryKeeper.can_expand_without_policy());

        primaryKeeper.expand_supply(10_000e18);

        assertFalse(primaryKeeper.can_expand_without_policy());
        assertLt(primaryKeeper.debt() * 10_000, primaryKeeper.max_deployed_crvusd() * 8_000);
        assertFalse(keeperPolicy.can_allocate(expectedSUsdeKeeper));
        assertFalse(keeperPolicy.can_expand(expectedSUsdeKeeper));
    }

    function _executeProposal() internal {
        _executeOwnershipVote(
            proposal.buildProposalScript(),
            "Accept and activate four direct PegKeeperV3 keepers with three-tier priority"
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
        assertEq(keeper.max_deployed_crvusd(), CAP);
        assertEq(keeper.debt(), 0);
        assertTrue(factory.is_active(keeperAddress));
        assertFalse(keeper.expansion_paused());
        assertFalse(keeper.contraction_paused());
        assertFalse(keeper.all_execution_paused());
    }

    function _assertOwnershipAcceptance(
        BaseCurveProposal.Action memory action,
        address target,
        uint256 expectedNonce
    ) internal pure {
        assertEq(action.target, target);
        assertEq(_selector(action.data), IPegKeeperV3Factory.acceptOwnership.selector);
        assertEq(_ownershipAcceptanceNonce(action), expectedNonce);
    }

    function _ownershipAcceptanceNonce(BaseCurveProposal.Action memory action)
        internal
        pure
        returns (uint256 nonce)
    {
        bytes memory data = action.data;
        assembly {
            nonce := mload(add(data, 36))
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

    function _firstFourEmptySlots(IAggMonetaryPolicy monetaryPolicy)
        internal
        view
        returns (uint256[4] memory slots)
    {
        uint256 found;
        for (uint256 i; i < 1_000; ++i) {
            if (monetaryPolicy.peg_keepers(i) != address(0)) continue;
            slots[found] = i;
            ++found;
            if (found == slots.length) return slots;
        }
        revert("fewer than four policy slots");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
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
