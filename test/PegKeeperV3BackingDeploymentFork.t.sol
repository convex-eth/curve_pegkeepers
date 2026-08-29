// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {MockPegKeeperFactory} from "./PegKeeperV3Foundation.t.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {RoutePool} from "./PegKeeperV3Routes.t.sol";

interface IERC4626Live {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract PegKeeperV3BackingDeploymentForkTest is Test {
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
    uint256 internal constant TARGET_AMOUNT = 1_000e6;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal keeper = makeAddr("keeper");
    address internal caller = makeAddr("caller");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveUsdtToSusdsBackingDeployment() public {
        IPegKeeperV3 pegKeeper = _deploy();
        RoutePool localUsdsCrvUsdPool = new RoutePool(USDS, CRVUSD);

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(1, false);
        vm.stopPrank();

        deal(USDT, address(this), 10_000_000e6);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);
        vm.prank(keeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        vm.prank(governance);
        pegKeeper.setPaths(_expansionPath(), 100, _contractionPath(localUsdsCrvUsdPool));

        uint256 undeployedBefore = pegKeeper.undeployed_backing();
        uint256 trustedBefore = pegKeeper.trusted_backing_value();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        uint256 expansionTime = pegKeeper.last_expansion_at();
        uint256 yieldBefore = IERC20(SUSDS).balanceOf(address(pegKeeper));
        assertGe(pegKeeper.protocol_surplus(), 1e18);
        assertGe(undeployedBefore, TARGET_AMOUNT);

        vm.prank(caller);
        (uint256 targetSpent, uint256 yieldReceived) =
            pegKeeper.deployUndeployedBacking(TARGET_AMOUNT);

        uint256 trustedYieldReceived = IERC4626Live(SUSDS).convertToAssets(yieldReceived);
        assertEq(targetSpent, TARGET_AMOUNT);
        assertGt(yieldReceived, 0);
        assertEq(IERC20(SUSDS).balanceOf(address(pegKeeper)) - yieldBefore, yieldReceived);
        assertEq(pegKeeper.accounted_yield_token_units(), yieldReceived);
        assertEq(pegKeeper.undeployed_backing(), undeployedBefore - TARGET_AMOUNT);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore);
        assertEq(pegKeeper.last_expansion_at(), expansionTime);
        assertGe(trustedYieldReceived, 990e18);
        assertLe(trustedBefore - pegKeeper.trusted_backing_value(), 10e18);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
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

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        MockPegKeeperFactory pegKeeperFactory =
            new MockPegKeeperFactory(FACTORY, governance, emergencyAdmin, FEE_SPLITTER);
        bytes memory constructorArgs =
            abi.encode(address(pegKeeperFactory), USDT_POOL, USDT, USDS, SUSDS, ALLOCATION, 1);
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
