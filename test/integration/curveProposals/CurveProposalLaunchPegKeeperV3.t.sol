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
import {IPegKeeperPolicy} from "../../../src/interfaces/IPegKeeperPolicy.sol";
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
        CurveEDAOProxyHarness proxyHarness = new CurveEDAOProxyHarness();
        vm.etch(EDAO_PROXY, address(proxyHarness).code);

        proposal = new CurveProposalLaunchPegKeeperV3();
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(deployer.mainnetConfig());
        proposal.setDeployment(
            deployment.factory,
            deployment.policy,
            deployment.frxUsdUsdOracle,
            deployment.usdeUsdOracle,
            deployment.usdcUsdOracle,
            deployment.usdtUsdOracle
        );

        factory = IPegKeeperV3Factory(deployment.factory);
        keeperPolicy = IPegKeeperPolicy(deployment.policy);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedSUsdeKeeper = proposal.expectedKeeper(2);
        expectedUsdcKeeper = proposal.expectedKeeper(3);
        expectedUsdtKeeper = proposal.expectedKeeper(4);
    }

    function test_actionsAreDirectAndConfigureThreePriorityLayers() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 33);

        assertEq(actions[0].target, address(keeperPolicy));
        assertEq(_selector(actions[0].data), IPegKeeperPolicy.set_factory.selector);
        assertEq(actions[1].target, address(factory));
        assertEq(_selector(actions[1].data), IPegKeeperV3Factory.setDefaults.selector);

        _assertDeployAction(
            actions[2], proposal.FRXUSD_CRVUSD_POOL(), false, proposal.frxUsdOracle()
        );
        _assertTierAction(actions[3], expectedFrxUsdKeeper, 1);
        _assertDeployAction(actions[10], proposal.SUSDE_CRVUSD_POOL(), true, proposal.usdeOracle());
        _assertTierAction(actions[11], expectedSUsdeKeeper, 2);
        _assertDeployAction(actions[17], proposal.USDC_CRVUSD_POOL(), false, proposal.usdcOracle());
        _assertTierAction(actions[18], expectedUsdcKeeper, 3);
        _assertDeployAction(actions[25], proposal.USDT_CRVUSD_POOL(), false, proposal.usdtOracle());
        _assertTierAction(actions[26], expectedUsdtKeeper, 3);

        for (uint256 i; i < actions.length; ++i) {
            assertNotEq(
                _selector(actions[i].data),
                bytes4(
                    keccak256(
                        "setPaths((uint256,address,address,address,int128,int128,uint256)[],uint256)"
                    )
                )
            );
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

    function test_proposalDeploysFourPausedDirectKeepersAndPriorityState() public {
        uint256[4] memory primarySlots = _firstFourEmptySlots(IAggMonetaryPolicy(MONETARY_POLICY));
        uint256[4] memory legacySlots =
            _firstFourEmptySlots(IAggMonetaryPolicy(LEGACY_MONETARY_POLICY));
        _executeProposal();

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
            proposal.frxUsdOracle()
        );
        _assertKeeper(
            expectedSUsdeKeeper,
            proposal.SUSDE_CRVUSD_POOL(),
            SUSDE,
            USDE,
            true,
            proposal.usdeOracle()
        );
        _assertKeeper(
            expectedUsdcKeeper,
            proposal.USDC_CRVUSD_POOL(),
            USDC,
            USDC,
            false,
            proposal.usdcOracle()
        );
        _assertKeeper(
            expectedUsdtKeeper,
            proposal.USDT_CRVUSD_POOL(),
            USDT,
            USDT,
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

    function test_secondaryCanExpandWhenPausedPrimaryCannot() public {
        _executeActionsDirectly();
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedSUsdeKeeper), 0);

        vm.prank(EDAO_PROXY);
        IControllerFactory(CONTROLLER_FACTORY).set_debt_ceiling(expectedSUsdeKeeper, 20_000e18);
        IPegKeeperV3 sUsdeKeeper = IPegKeeperV3(expectedSUsdeKeeper);
        vm.startPrank(OWNERSHIP_AGENT);
        sUsdeKeeper.set_direction_paused(2, false);
        sUsdeKeeper.set_direction_paused(0, false);
        vm.stopPrank();

        assertFalse(IPegKeeperV3(expectedFrxUsdKeeper).can_expand_without_policy());
        assertTrue(keeperPolicy.can_expand(expectedSUsdeKeeper));
        (uint256 expectedDebt,,, uint256 expectedLp) = sUsdeKeeper.previewExpansion(10_000e18);
        assertEq(expectedDebt, 10_000e18);
        assertGt(expectedLp, 0);

        (uint256 debtAdded, uint256 lpReceived,) = sUsdeKeeper.expand(10_000e18);
        assertEq(debtAdded, 10_000e18);
        assertGt(lpReceived, 0);
        assertGe(sUsdeKeeper.trusted_backing_value(), sUsdeKeeper.deployed_crvusd());
    }

    function _executeProposal() internal {
        bytes memory script = proposal.buildProposalScript();
        vm.prank(CONVEX_VOTEPROXY);
        uint256 proposalId = OWNERSHIP_VOTE.newVote(
            script,
            "Deploy four paused direct PegKeeperV3 keepers with three-tier priority",
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
        address oracle
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.yield_amm(), amm);
        assertEq(keeper.yield_token(), yieldToken);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.yield_token_is_erc4626(), isErc4626);
        assertEq(keeper.yield_oracle(), oracle);
        assertEq(keeper.min_yield_oracle_price(), proposal.MIN_YIELD_ORACLE_PRICE());
        assertEq(keeper.max_deployed_crvusd(), CAP);
        assertTrue(factory.is_active(keeperAddress));
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function _assertDeployAction(
        BaseCurveProposal.Action memory action,
        address amm,
        bool isErc4626,
        address oracle
    ) internal view {
        assertEq(action.target, address(factory));
        assertEq(_selector(action.data), IPegKeeperV3Factory.deployPegKeeper.selector);
        (address encodedAmm, bool encodedErc4626, address encodedOracle) =
            abi.decode(_withoutSelector(action.data), (address, bool, address));
        assertEq(encodedAmm, amm);
        assertEq(encodedErc4626, isErc4626);
        assertEq(encodedOracle, oracle);
    }

    function _assertTierAction(
        BaseCurveProposal.Action memory action,
        address keeper,
        uint256 expectedTier
    ) internal view {
        assertEq(action.target, address(keeperPolicy));
        assertEq(_selector(action.data), IPegKeeperPolicy.set_tier.selector);
        (address configuredKeeper, uint256 tier) =
            abi.decode(_withoutSelector(action.data), (address, uint256));
        assertEq(configuredKeeper, keeper);
        assertEq(tier, expectedTier);
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
