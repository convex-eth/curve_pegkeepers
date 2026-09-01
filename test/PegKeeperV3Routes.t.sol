// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    ExpansionFactory,
    ExpansionPool,
    ExpansionToken,
    ExpansionYieldToken
} from "./PegKeeperV3Expansion.t.sol";

contract RoutePool {
    address[2] internal poolCoins;

    constructor(address coin0, address coin1) {
        poolCoins[0] = coin0;
        poolCoins[1] = coin1;
    }

    function coins(uint256 index) external view returns (address) {
        return poolCoins[index];
    }
}

contract RouteDaiUsds {
    address public immutable dai;
    address public immutable usds;

    constructor(address dai_, address usds_) {
        dai = dai_;
        usds = usds_;
    }
}

contract RouteFrxUsdMinter {
    address public immutable asset;
    address public immutable frxUSD;

    constructor(address asset_, address frxUsd_) {
        asset = asset_;
        frxUSD = frxUsd_;
    }
}

contract PegKeeperV3RoutesTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant FRXUSD_MINT = 4;
    uint256 internal constant FRXUSD_REDEEM = 5;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal keeper = makeAddr("keeper");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExpansionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    RoutePool internal targetToDaiPool;
    RoutePool internal targetToBackingPool;
    RoutePool internal daiToCrvUsdPool;
    RouteDaiUsds internal daiUsds;
    RouteFrxUsdMinter internal frxUsdMinter;
    IPegKeeperV3 internal pegKeeper;
    IPegKeeperV3 internal routes;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        dai = new ExpansionToken(18);
        yieldToken = new ExpansionYieldToken(address(backingAsset));
        factory = new ExpansionFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        targetPool = new ExpansionPool(crvUsd, targetAsset);
        targetToDaiPool = new RoutePool(address(targetAsset), address(dai));
        targetToBackingPool = new RoutePool(address(targetAsset), address(backingAsset));
        daiToCrvUsdPool = new RoutePool(address(dai), address(crvUsd));
        daiUsds = new RouteDaiUsds(address(dai), address(backingAsset));
        frxUsdMinter = new RouteFrxUsdMinter(address(targetAsset), address(backingAsset));
        pegKeeper = _deploy();
        routes = IPegKeeperV3(address(pegKeeper));
    }

    function test_governanceAtomicallyStoresValidatedDirectionalPaths() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contraction = _contractionPath();
        bytes32 expansionHash = keccak256(abi.encode(expansion));
        bytes32 contractionHash = keccak256(abi.encode(contraction));

        vm.expectEmit(true, true, false, true, address(pegKeeper));
        emit IPegKeeperV3.PathsUpdated(expansionHash, contractionHash, 25);
        vm.prank(governance);
        routes.setPaths(expansion, 25, contraction);

        assertEq(routes.expansion_path_length(), expansion.length);
        assertEq(routes.contraction_path_length(), contraction.length);
        assertEq(routes.expansion_max_route_loss_bps(), 25);
        _assertStepEq(routes.expansion_path_step(0), expansion[0]);
        _assertStepEq(routes.expansion_path_step(2), expansion[2]);
        _assertStepEq(routes.contraction_path_step(0), contraction[0]);
        _assertStepEq(routes.contraction_path_step(2), contraction[2]);
    }

    function test_onlyGovernanceCanSetPaths() public {
        vm.prank(keeper);
        vm.expectRevert();
        routes.setPaths(_expansionPath(), 25, _contractionPath());
    }

    function test_pathRejectsMoreThanSixteenSteps() public {
        IPegKeeperV3.RouteStep[] memory expansion = new IPegKeeperV3.RouteStep[](17);
        IPegKeeperV3.RouteStep memory step =
            _curveStep(address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5);
        for (uint256 i; i < expansion.length; ++i) {
            expansion[i] = step;
        }

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_pathAcceptsExactlySixteenSteps() public {
        IPegKeeperV3.RouteStep[] memory expansion = new IPegKeeperV3.RouteStep[](16);
        for (uint256 i; i < 14; ++i) {
            if (i % 2 == 0) {
                expansion[i] = _curveStep(
                    address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5
                );
            } else {
                expansion[i] = _curveStep(
                    address(targetToDaiPool), address(dai), address(targetAsset), 1, 0, 5
                );
            }
        }
        expansion[14] = _curveStep(
            address(targetToBackingPool), address(targetAsset), address(backingAsset), 0, 1, 5
        );
        expansion[15] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });

        vm.prank(governance);
        routes.setPaths(expansion, 25, _contractionPath());

        assertEq(routes.MAX_ROUTE_STEPS(), 16);
        assertEq(routes.expansion_path_length(), 16);
        _assertStepEq(routes.expansion_path_step(15), expansion[15]);
    }

    function test_pathsCannotBeEmpty() public {
        IPegKeeperV3.RouteStep[] memory empty = new IPegKeeperV3.RouteStep[](0);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(empty, 25, _contractionPath());
    }

    function test_expansionPathRequiresFixedEndpoints() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[0].tokenIn = address(dai);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_contractionPathRequiresFixedEndpoints() public {
        IPegKeeperV3.RouteStep[] memory contraction = _contractionPath();
        contraction[contraction.length - 1].tokenOut = address(dai);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(_expansionPath(), 25, contraction);
    }

    function test_pathRejectsDiscontinuousTokens() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[1].tokenIn = address(targetAsset);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_curveStepValidatesExplicitCoinIndices() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[0].poolIndexIn = 1;
        expansion[0].poolIndexOut = 0;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_daiUsdsStepRequiresCanonicalDirectionAndZeroBuffer() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[1].executionBufferBps = 1;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_stepExecutionBufferCannotExceedDenominator() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[0].executionBufferBps = 10_001;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_unknownStepKindIsRejected() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[0].kind = 6;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdMintStepAcceptsExternalShareMinter() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();

        vm.prank(governance);
        routes.setPaths(expansion, 25, _contractionPath());

        _assertStepEq(routes.expansion_path_step(0), expansion[0]);
    }

    function test_frxUsdMintStepRejectsWrongAssetEndpoint() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();
        expansion[0].venue = address(new RouteFrxUsdMinter(address(dai), address(backingAsset)));

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdMintStepRejectsWrongFrxUsdEndpoint() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();
        expansion[0].venue = address(new RouteFrxUsdMinter(address(targetAsset), address(dai)));

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdMintStepRejectsReverseDirection() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();
        expansion[0].venue =
            address(new RouteFrxUsdMinter(address(backingAsset), address(targetAsset)));

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdMintStepRejectsPoolIndices() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();
        expansion[0].poolIndexIn = 1;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdMintStepRejectsOutputPoolIndex() public {
        IPegKeeperV3.RouteStep[] memory expansion = _frxUsdMintExpansionPath();
        expansion[0].poolIndexOut = 1;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_frxUsdRedeemStepAcceptsExternalShareCustodian() public {
        IPegKeeperV3 plainRoutes = _deployPlainFrxUsdEndpoint();
        IPegKeeperV3.RouteStep[] memory contraction = _frxUsdRedeemContractionPath();

        vm.prank(governance);
        plainRoutes.setPaths(_plainFrxUsdMintExpansionPath(), 25, contraction);

        _assertStepEq(plainRoutes.contraction_path_step(0), contraction[0]);
    }

    function test_frxUsdRedeemStepRejectsWrongAssetEndpoint() public {
        IPegKeeperV3 plainRoutes = _deployPlainFrxUsdEndpoint();
        IPegKeeperV3.RouteStep[] memory contraction = _frxUsdRedeemContractionPath();
        contraction[0].venue = address(new RouteFrxUsdMinter(address(dai), address(backingAsset)));

        vm.prank(governance);
        vm.expectRevert();
        plainRoutes.setPaths(_plainFrxUsdMintExpansionPath(), 25, contraction);
    }

    function test_frxUsdRedeemStepRejectsWrongFrxUsdEndpoint() public {
        IPegKeeperV3 plainRoutes = _deployPlainFrxUsdEndpoint();
        IPegKeeperV3.RouteStep[] memory contraction = _frxUsdRedeemContractionPath();
        contraction[0].venue = address(new RouteFrxUsdMinter(address(backingAsset), address(dai)));

        vm.prank(governance);
        vm.expectRevert();
        plainRoutes.setPaths(_plainFrxUsdMintExpansionPath(), 25, contraction);
    }

    function test_frxUsdRedeemStepRejectsPoolIndices() public {
        IPegKeeperV3 plainRoutes = _deployPlainFrxUsdEndpoint();
        IPegKeeperV3.RouteStep[] memory contraction = _frxUsdRedeemContractionPath();
        contraction[0].poolIndexOut = 1;

        vm.prank(governance);
        vm.expectRevert();
        plainRoutes.setPaths(_plainFrxUsdMintExpansionPath(), 25, contraction);
    }

    function test_erc4626StepValidatesVaultAssetAndShareEndpoint() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[2].venue = address(targetToDaiPool);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_erc4626DepositStepRequiresItsConfiguredAssetInput() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        expansion[2].tokenIn = address(dai);
        expansion[1].tokenOut = address(dai);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 25, _contractionPath());
    }

    function test_erc4626RedeemStepRequiresItsConfiguredAssetOutput() public {
        IPegKeeperV3.RouteStep[] memory contraction = _contractionPath();
        contraction[0].tokenOut = address(dai);
        contraction[1].tokenIn = address(dai);

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(_expansionPath(), 25, contraction);
    }

    function test_expansionRouteLossCannotExceedDenominator() public {
        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(_expansionPath(), 10_001, _contractionPath());
    }

    function test_invalidReplacementRollsBackBothPaths() public {
        IPegKeeperV3.RouteStep[] memory expansion = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contraction = _contractionPath();
        vm.prank(governance);
        routes.setPaths(expansion, 25, contraction);
        contraction[1].executionBufferBps = 1;

        vm.prank(governance);
        vm.expectRevert();
        routes.setPaths(expansion, 50, contraction);

        assertEq(routes.expansion_max_route_loss_bps(), 25);
        _assertStepEq(routes.expansion_path_step(0), expansion[0]);
        _assertStepEq(routes.contraction_path_step(1), _contractionPath()[1]);
    }

    function _expansionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 5);
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(dai),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: address(yieldToken),
            tokenIn: address(yieldToken),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(backingAsset),
            tokenOut: address(dai),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = _curveStep(address(daiToCrvUsdPool), address(dai), address(crvUsd), 0, 1, 5);
    }

    function _frxUsdMintExpansionPath()
        internal
        view
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_MINT,
            venue: address(frxUsdMinter),
            tokenIn: address(targetAsset),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _frxUsdRedeemContractionPath()
        internal
        view
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_REDEEM,
            venue: address(frxUsdMinter),
            tokenIn: address(backingAsset),
            tokenOut: address(targetAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        path[1] = _curveStep(address(targetPool), address(targetAsset), address(crvUsd), 0, 1, 5);
    }

    function _plainFrxUsdMintExpansionPath()
        internal
        view
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        path = new IPegKeeperV3.RouteStep[](1);
        path[0] = IPegKeeperV3.RouteStep({
            kind: FRXUSD_MINT,
            venue: address(frxUsdMinter),
            tokenIn: address(targetAsset),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut,
        uint256 executionBufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory step) {
        step = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: poolIndexIn,
            poolIndexOut: poolIndexOut,
            executionBufferBps: executionBufferBps
        });
    }

    function _assertStepEq(
        IPegKeeperV3.RouteStep memory actual,
        IPegKeeperV3.RouteStep memory expected
    ) internal pure {
        assertEq(actual.kind, expected.kind);
        assertEq(actual.venue, expected.venue);
        assertEq(actual.tokenIn, expected.tokenIn);
        assertEq(actual.tokenOut, expected.tokenOut);
        assertEq(actual.poolIndexIn, expected.poolIndexIn);
        assertEq(actual.poolIndexOut, expected.poolIndexOut);
        assertEq(actual.executionBufferBps, expected.executionBufferBps);
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        deployedPegKeeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetPool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            MAX_DEPLOYED,
            1
        );
    }

    function _deployPlainFrxUsdEndpoint() internal returns (IPegKeeperV3 deployedPegKeeper) {
        deployedPegKeeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetPool),
            address(targetAsset),
            address(backingAsset),
            address(backingAsset),
            MAX_DEPLOYED,
            2
        );
    }
}
