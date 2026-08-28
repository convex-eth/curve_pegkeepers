// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";

interface IERC4626ContractionLive {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract PegKeeperV3YieldContractionForkTest is Test {
    struct PreviewState {
        uint256 accountedBefore;
        uint256 yieldAmount;
        uint256 deployedBefore;
        uint256 expansionTime;
        uint256 trustedBefore;
        uint256 keeperBalanceBefore;
        uint256 expectedOut;
        uint256 expectedReward;
        uint256 trustedRemoved;
    }

    uint256 internal constant FORK_BLOCK = 25_851_930;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant ALLOCATION = 1_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;
    uint256 internal constant TARGET_TO_DEPLOY = 50_000e6;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal keeper = makeAddr("keeper");
    address internal caller = makeAddr("caller");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveSusdsYieldContractionToCrvUsd() public {
        IPegKeeperV3 pegKeeper = _deploy();
        vm.prank(governance);
        pegKeeper.setPaths(_expansionPath(), 100, _contractionPath());

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(4, false);
        vm.stopPrank();

        deal(USDT, address(this), 10_000_000e6);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);
        vm.prank(keeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        vm.prank(keeper);
        pegKeeper.deployUndeployedBacking(TARGET_TO_DEPLOY);

        deal(CRVUSD, address(this), 45_000_000e18);
        IERC20(CRVUSD).approve(USDT_POOL, 45_000_000e18);
        IStableSwap2Pool(USDT_POOL).exchange(1, 0, 45_000_000e18, 0);

        PreviewState memory state;
        state.accountedBefore = pegKeeper.accounted_yield_token_units();
        state.yieldAmount = state.accountedBefore / 5;
        state.deployedBefore = pegKeeper.deployed_crvusd();
        state.expansionTime = pegKeeper.last_expansion_at();
        state.trustedBefore = pegKeeper.trusted_backing_value();
        state.keeperBalanceBefore = IERC20(CRVUSD).balanceOf(caller);
        uint256 expectedGross;
        bool earlyExit;
        (state.expectedOut, expectedGross, state.expectedReward, earlyExit) =
            pegKeeper.previewKeeperBuyback(state.yieldAmount);
        uint256 trustedYieldBefore =
            IERC4626ContractionLive(SUSDS).convertToAssets(state.accountedBefore);
        uint256 trustedYieldAfter = IERC4626ContractionLive(SUSDS)
            .convertToAssets(state.accountedBefore - state.yieldAmount);
        state.trustedRemoved = trustedYieldBefore - trustedYieldAfter;
        assertTrue(earlyExit);
        assertGt(expectedGross, 0);
        assertGe(
            state.expectedOut - state.expectedReward,
            state.trustedRemoved + state.trustedRemoved * pegKeeper.early_exit_min_profit_ppm()
                / 1_000_000
        );

        vm.prank(caller);
        (uint256 spent, uint256 received, uint256 reward) =
            pegKeeper.contractViaAmm(state.yieldAmount);
        uint256 netRetained = received - reward;

        assertEq(spent, state.yieldAmount);
        assertEq(received, state.expectedOut);
        assertEq(reward, state.expectedReward);
        assertEq(IERC20(CRVUSD).balanceOf(caller) - state.keeperBalanceBefore, reward);
        assertEq(pegKeeper.accounted_yield_token_units(), state.accountedBefore - state.yieldAmount);
        uint256 expectedDeployedAfter =
            netRetained < state.deployedBefore ? state.deployedBefore - netRetained : 0;
        assertEq(pegKeeper.deployed_crvusd(), expectedDeployedAfter);
        assertEq(pegKeeper.last_expansion_at(), state.expansionTime);
        assertEq(state.trustedBefore - pegKeeper.trusted_backing_value(), state.trustedRemoved);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(THREE_POOL, USDT, DAI, 2, 0, 5);
        path[1] = _converterStep(DAI, USDS);
        path[2] = _vaultStep(ERC4626_DEPOSIT, USDS, SUSDS);
    }

    function _contractionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](4);
        path[0] = _vaultStep(ERC4626_REDEEM, SUSDS, USDS);
        path[1] = _converterStep(USDS, DAI);
        path[2] = _curveStep(THREE_POOL, DAI, USDT, 0, 2, 5);
        path[3] = _curveStep(USDT_POOL, USDT, CRVUSD, 0, 1, 5);
    }

    function _converterStep(address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory step)
    {
        step = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: DAI_USDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _vaultStep(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory step)
    {
        step = IPegKeeperV3.RouteStep({
            kind: kind,
            venue: SUSDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
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

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            FACTORY,
            USDT_POOL,
            USDT,
            USDS,
            SUSDS,
            FEE_SPLITTER,
            governance,
            emergencyAdmin,
            ALLOCATION
        );
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        address deployed;

        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        deployedPegKeeper = IPegKeeperV3(deployed);
    }
}
