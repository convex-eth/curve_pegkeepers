// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {RoutePool} from "./PegKeeperV3Routes.t.sol";

interface IERC4626ExpansionLive {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

contract PegKeeperV3DownstreamExpansionForkTest is Test {
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

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveExpansionRoutesUsdtThroughUsdsIntoSusds() public {
        IPegKeeperV3 pegKeeper = _deploy();
        RoutePool localUsdsCrvUsdPool = new RoutePool(USDS, CRVUSD);
        vm.prank(governance);
        pegKeeper.setPaths(_expansionPath(), 100, _contractionPath(localUsdsCrvUsdPool));

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 1_500_000, 300_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();

        uint256 purchaseAmount = 10_000_000e6;
        deal(USDT, address(this), purchaseAmount);
        IUSDT(USDT).approve(USDT_POOL, purchaseAmount);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, purchaseAmount, 0);

        uint256 keeperUsdsBefore = IERC20(USDS).balanceOf(keeper);
        uint256 protocolSusdsBefore = IERC20(SUSDS).balanceOf(address(pegKeeper));
        vm.prank(keeper);
        (
            uint256 sold,
            uint256 retained,
            uint256 yieldReceived,
            uint256 reward,
            bool deployedToYield
        ) = pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(sold, EXPANSION_AMOUNT);
        assertEq(retained, 0);
        assertGt(yieldReceived, 0);
        assertGt(reward, 0);
        assertTrue(deployedToYield);
        assertEq(IERC20(USDS).balanceOf(keeper) - keeperUsdsBefore, reward);
        assertEq(IERC20(SUSDS).balanceOf(address(pegKeeper)) - protocolSusdsBefore, yieldReceived);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldReceived);
        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.deployed_crvusd(), EXPANSION_AMOUNT);
        assertEq(IERC20(USDT).balanceOf(address(pegKeeper)), 0);
        assertEq(IERC20(DAI).balanceOf(address(pegKeeper)), 0);
        assertEq(IERC20(USDS).balanceOf(address(pegKeeper)), 0);
        assertGe(
            IERC4626ExpansionLive(SUSDS).convertToAssets(yieldReceived),
            EXPANSION_AMOUNT + EXPANSION_AMOUNT * 50 / 1_000_000
        );
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
        assertEq(IERC20Allowance(USDT).allowance(address(pegKeeper), THREE_POOL), 0);
        assertEq(IERC20Allowance(DAI).allowance(address(pegKeeper), DAI_USDS), 0);
        assertEq(IERC20Allowance(USDS).allowance(address(pegKeeper), SUSDS), 0);
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: THREE_POOL,
            tokenIn: USDT,
            tokenOut: DAI,
            poolIndexIn: 2,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: DAI_USDS,
            tokenIn: DAI,
            tokenOut: USDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: SUSDS,
            tokenIn: USDS,
            tokenOut: SUSDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
    }

    function _contractionPath(RoutePool localPool)
        internal
        pure
        returns (IPegKeeperV3.RouteStep[] memory path)
    {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: SUSDS,
            tokenIn: SUSDS,
            tokenOut: USDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(localPool),
            tokenIn: USDS,
            tokenOut: CRVUSD,
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
    }

    function _deploy() internal returns (IPegKeeperV3 pegKeeper) {
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
        pegKeeper = IPegKeeperV3(deployed);
    }
}
