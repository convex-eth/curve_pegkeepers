// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3Simple} from "../../../script/DeployPegKeeperV3Simple.s.sol";
import {BaseCurveProposal} from "../../../script/proposals/curve/BaseCurveProposal.sol";
import {
    CurveProposalLaunchPegKeeperV3Simple
} from "../../../script/proposals/curve/CurveProposalLaunchPegKeeperV3Simple.s.sol";
import {IAggMonetaryPolicy} from "../../../src/interfaces/IAggMonetaryPolicy.sol";
import {IControllerFactory} from "../../../src/interfaces/IControllerFactory.sol";
import {ICurveEDAOAdminProxy} from "../../../src/interfaces/ICurveEDAOAdminProxy.sol";
import {ICurveVoting} from "../../../src/interfaces/ICurveVoting.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";
import {IChainlinkStablecoinOracle} from "../../../src/interfaces/IChainlinkStablecoinOracle.sol";

contract SimpleCurveEDAOProxyHarness {
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

contract CurveProposalLaunchPegKeeperV3SimpleTest is Test {
    string internal constant TEST_DEPLOYMENT_OUTPUT =
        "deployments/mainnet/PegKeeperV3-simple-deployment.test.json";
    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant OWNERSHIP_VOTING = 0xE478de485ad2fe566d49342Cbd03E49ed7DB3356;
    address internal constant EDAO_PROXY = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address internal constant LEGACY_MONETARY_POLICY = 0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;
    address internal constant CONVEX_VOTEPROXY = 0x989AEb4d175e16225E39E87d0D97A3360524AD80;
    address internal constant YEARN_VOTEPROXY = 0xF147b8125d2ef93FB6965Db97D6746952a133934;
    address internal constant SD_VOTEPROXY = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;

    uint256 internal constant CAP = 20_000_000e18;
    uint256 internal constant VOTING_PERIOD = 8 days;

    ICurveVoting internal constant OWNERSHIP_VOTE = ICurveVoting(OWNERSHIP_VOTING);

    CurveProposalLaunchPegKeeperV3Simple internal proposal;
    IPegKeeperV3Factory internal factory;
    DeployPegKeeperV3Simple.SimpleDeployment internal deployment;
    address internal expectedFrxUsdKeeper;
    address internal expectedSUsdeKeeper;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), 25_911_411
        );
        SimpleCurveEDAOProxyHarness proxyHarness = new SimpleCurveEDAOProxyHarness();
        vm.etch(EDAO_PROXY, address(proxyHarness).code);

        DeployPegKeeperV3Simple deployer = new DeployPegKeeperV3Simple();
        deployment = deployer.deploySimple(deployer.mainnetConfig());

        proposal = new CurveProposalLaunchPegKeeperV3Simple();
        proposal.setDeploymentFactory(deployment.factory);
        proposal.setOracleAdapters(deployment.frxUsdUsdOracle, deployment.usDeUsdOracle);
        factory = IPegKeeperV3Factory(deployment.factory);
        expectedFrxUsdKeeper = proposal.expectedKeeper(1);
        expectedSUsdeKeeper = proposal.expectedKeeper(2);
    }

    function test_simpleDependencyDeploymentPinsCanonicalBackingFeeds() public view {
        IChainlinkStablecoinOracle frxUsdOracle =
            IChainlinkStablecoinOracle(deployment.frxUsdUsdOracle);
        IChainlinkStablecoinOracle usDeOracle = IChainlinkStablecoinOracle(deployment.usDeUsdOracle);

        assertEq(frxUsdOracle.feed(), proposal.FRXUSD_USD_PROXY());
        assertEq(usDeOracle.feed(), proposal.USDE_USD_PROXY());
        assertEq(frxUsdOracle.max_delay(), proposal.FRXUSD_CHAINLINK_MAX_DELAY());
        assertEq(usDeOracle.max_delay(), proposal.USDE_CHAINLINK_MAX_DELAY());
        assertGe(frxUsdOracle.price(), proposal.MIN_YIELD_ORACLE_PRICE());
        assertGe(usDeOracle.price(), proposal.MIN_YIELD_ORACLE_PRICE());
    }

    function test_simpleDependencyDeploymentWritesCompleteJson() public {
        DeployPegKeeperV3Simple deployer = new DeployPegKeeperV3Simple();
        deployer.writeSimpleDeploymentJson(deployment, TEST_DEPLOYMENT_OUTPUT);
        string memory json = vm.readFile(TEST_DEPLOYMENT_OUTPUT);

        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(json, ".previewModule"), deployment.previewModule);
        assertEq(vm.parseJsonAddress(json, ".implementation"), deployment.implementation);
        assertEq(vm.parseJsonAddress(json, ".factory"), deployment.factory);
        assertEq(vm.parseJsonAddress(json, ".frxUsdUsdOracle"), deployment.frxUsdUsdOracle);
        assertEq(vm.parseJsonAddress(json, ".usDeUsdOracle"), deployment.usDeUsdOracle);
        vm.removeFile(TEST_DEPLOYMENT_OUTPUT);
    }

    function test_simpleProposalContainsOnlyTwoDirectEmptyPathDeployments() public view {
        BaseCurveProposal.Action[] memory actions = proposal.buildProposalActions();
        assertEq(actions.length, 14);

        assertEq(actions[0].target, address(factory));
        assertEq(_selector(actions[0].data), IPegKeeperV3Factory.setDefaults.selector);
        _assertDirectDeployment(
            actions[1],
            proposal.FRXUSD_CRVUSD_POOL(),
            proposal.FRXUSD(),
            false,
            deployment.frxUsdUsdOracle
        );
        _assertDirectDeployment(
            actions[8],
            proposal.SUSDE_CRVUSD_POOL(),
            proposal.SUSDE(),
            true,
            deployment.usDeUsdOracle
        );

        for (uint256 i; i < actions.length; ++i) {
            assertNotEq(_selector(actions[i].data), IPegKeeperV3.setPaths.selector);
        }
    }

    function test_simpleProposalDeploysPausedDirectFrxUsdAndSUsdeKeepers() public {
        _executeProposal();

        assertEq(factory.keeperCount(), 2);
        assertEq(factory.keeperAt(1), expectedFrxUsdKeeper);
        assertEq(factory.keeperAt(2), expectedSUsdeKeeper);

        _assertKeeper(
            expectedFrxUsdKeeper,
            proposal.FRXUSD_CRVUSD_POOL(),
            proposal.FRXUSD(),
            proposal.FRXUSD(),
            false,
            deployment.frxUsdUsdOracle
        );
        _assertKeeper(
            expectedSUsdeKeeper,
            proposal.SUSDE_CRVUSD_POOL(),
            proposal.SUSDE(),
            proposal.USDE(),
            true,
            deployment.usDeUsdOracle
        );

        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedFrxUsdKeeper), CAP);
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedSUsdeKeeper), 0);
    }

    function test_simpleSUsdeKeeperExecutesDirectDepositAgainstLivePool() public {
        _executeActionsDirectly();
        assertEq(IControllerFactory(CONTROLLER_FACTORY).debt_ceiling(expectedSUsdeKeeper), 0);

        vm.prank(OWNERSHIP_AGENT);
        SimpleCurveEDAOProxyHarness(EDAO_PROXY)
            .execute(
                CONTROLLER_FACTORY,
                abi.encodeCall(
                    IControllerFactory.set_debt_ceiling, (expectedSUsdeKeeper, 20_000e18)
                )
            );
        _assertDirectExpansion(expectedSUsdeKeeper, 10_000e18);
    }

    function test_simpleFrxUsdKeeperRejectsUnprofitableLiveDirectDeposit() public {
        _executeActionsDirectly();
        IPegKeeperV3 keeper = IPegKeeperV3(expectedFrxUsdKeeper);
        vm.startPrank(OWNERSHIP_AGENT);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        vm.expectRevert();
        keeper.previewExpansion(10_000e18);
        vm.expectRevert();
        keeper.expand(10_000e18);
        assertEq(keeper.deployed_crvusd(), 0);
    }

    function test_simpleProposalRegistersBothKeepersInBothMonetaryPolicies() public {
        IAggMonetaryPolicy policy = IAggMonetaryPolicy(MONETARY_POLICY);
        IAggMonetaryPolicy legacyPolicy = IAggMonetaryPolicy(LEGACY_MONETARY_POLICY);
        uint256[2] memory slots = _firstTwoEmptySlots(policy);
        uint256[2] memory legacySlots = _firstTwoEmptySlots(legacyPolicy);

        _executeProposal();

        assertEq(policy.peg_keepers(slots[0]), expectedFrxUsdKeeper);
        assertEq(policy.peg_keepers(slots[1]), expectedSUsdeKeeper);
        assertEq(legacyPolicy.peg_keepers(legacySlots[0]), expectedFrxUsdKeeper);
        assertEq(legacyPolicy.peg_keepers(legacySlots[1]), expectedSUsdeKeeper);
    }

    function _assertDirectExpansion(address keeperAddress, uint256 amount) internal {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        vm.startPrank(OWNERSHIP_AGENT);
        keeper.set_direction_paused(2, false);
        keeper.set_direction_paused(0, false);
        vm.stopPrank();

        (
            uint256 expectedTargetOut,
            uint256 expectedCrvUsdMatched,,,
            uint256 expectedLpTokensOut,
            bool previewDirect
        ) = keeper.previewExpansion(amount);
        assertEq(expectedTargetOut, 0);
        assertEq(expectedCrvUsdMatched, amount);
        assertGt(expectedLpTokensOut, 0);
        assertTrue(previewDirect);

        (
            uint256 crvUsdSold,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,,
            bool executionDirect
        ) = keeper.expand(amount);
        assertEq(crvUsdSold, 0);
        assertEq(crvUsdMatched, amount);
        assertGt(lpTokensReceived, 0);
        assertTrue(executionDirect);
        assertEq(keeper.deployed_crvusd(), amount);
    }

    function _executeProposal() internal {
        bytes memory script = proposal.buildProposalScript();
        vm.prank(CONVEX_VOTEPROXY);
        uint256 proposalId = OWNERSHIP_VOTE.newVote(
            script,
            "Deploy and register two paused direct PegKeeperV3 keepers for frxUSD and sUSDe",
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

    function _assertDirectDeployment(
        BaseCurveProposal.Action memory action,
        address pool,
        address yieldToken,
        bool isErc4626,
        address oracle
    ) internal view {
        assertEq(action.target, address(factory));
        assertEq(_selector(action.data), IPegKeeperV3Factory.deployPegKeeper.selector);
        (
            address targetAmm,
            address deployedYieldToken,
            address yieldAmm,
            bool deployedIsErc4626,
            address deployedOracle,
            IPegKeeperV3.RouteStep[] memory expansion
        ) = abi.decode(
            _withoutSelector(action.data),
            (address, address, address, bool, address, IPegKeeperV3.RouteStep[])
        );
        assertEq(targetAmm, pool);
        assertEq(deployedYieldToken, yieldToken);
        assertEq(yieldAmm, pool);
        assertEq(deployedIsErc4626, isErc4626);
        assertEq(deployedOracle, oracle);
        assertEq(expansion.length, 0);
    }

    function _assertKeeper(
        address keeperAddress,
        address pool,
        address targetAsset,
        address backingAsset,
        bool isErc4626,
        address oracle
    ) internal view {
        IPegKeeperV3 keeper = IPegKeeperV3(keeperAddress);
        assertEq(keeper.target_amm(), pool);
        assertEq(keeper.target_asset(), targetAsset);
        assertEq(keeper.backing_asset(), backingAsset);
        assertEq(keeper.yield_token(), targetAsset);
        assertEq(keeper.yield_amm(), pool);
        assertEq(keeper.coins(1), pool);
        assertEq(keeper.yield_token_is_erc4626(), isErc4626);
        assertEq(keeper.yield_oracle(), oracle);
        assertEq(keeper.min_yield_oracle_price(), proposal.MIN_YIELD_ORACLE_PRICE());
        assertEq(keeper.expansion_path_length(), 0);
        assertEq(keeper.max_deployed_crvusd(), CAP);
        assertEq(keeper.entry_min_profit_ppm(), proposal.ENTRY_MIN_PROFIT_PPM());
        assertEq(keeper.normal_exit_min_profit_ppm(), proposal.NORMAL_EXIT_MIN_PROFIT_PPM());
        assertTrue(keeper.expansion_paused());
        assertTrue(keeper.yield_contraction_paused());
        assertTrue(keeper.all_execution_paused());
    }

    function _firstTwoEmptySlots(IAggMonetaryPolicy policy)
        internal
        view
        returns (uint256[2] memory slots)
    {
        uint256 found;
        for (uint256 i; i < 20 && found < 2; ++i) {
            if (policy.peg_keepers(i) == address(0)) {
                slots[found] = i;
                ++found;
            }
        }
        assertEq(found, 2);
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        require(data.length >= 4, "selector");
        assembly {
            selector := mload(add(data, 0x20))
        }
    }

    function _withoutSelector(bytes memory data) internal pure returns (bytes memory stripped) {
        require(data.length >= 4, "selector");
        stripped = new bytes(data.length - 4);
        for (uint256 i; i < stripped.length; ++i) {
            stripped[i] = data[i + 4];
        }
    }
}
