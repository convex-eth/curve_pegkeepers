// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {MockPegKeeperFactory} from "./PegKeeperV3Foundation.t.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";

interface IERC20AllowanceView {
    function allowance(address owner, address spender) external view returns (uint256);
}

contract PegKeeperV3FlashRoundTripForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_857_270;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    uint256 internal constant TEMPORARY_USDT = 10_000_000e6;
    uint256 internal constant CAPACITY = 5_000_000e18;
    uint256 internal constant EXPANSION_STEP = 100_000e18;
    uint256 internal constant MAX_CALLS = 50;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal actor = makeAddr("roundTripActor");
    IPegKeeperV3 internal pegKeeper;

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        pegKeeper = _deploy();
        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), CAPACITY);
        deal(CRVUSD, address(pegKeeper), CAPACITY);

        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 1_500_000, 300_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();
    }

    function test_flashStyleRoundTripWithSplitRewardsLosesWhileV3RetainsSurplus() public {
        deal(USDT, actor, TEMPORARY_USDT);
        vm.startPrank(actor);
        IUSDT(USDT).approve(USDT_POOL, TEMPORARY_USDT);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, TEMPORARY_USDT, 0);
        vm.stopPrank();

        uint256 expanded;
        uint256 aggregateReward;
        for (uint256 i; i < MAX_CALLS; ++i) {
            vm.prank(actor);
            try pegKeeper.expand(EXPANSION_STEP) returns (
                uint256 sold, uint256, uint256, uint256 reward, bool
            ) {
                expanded += sold;
                aggregateReward += reward;
            } catch {
                break;
            }
        }

        uint256 actorCrvUsd = IERC20(CRVUSD).balanceOf(actor);
        vm.startPrank(actor);
        IERC20(CRVUSD).approve(USDT_POOL, actorCrvUsd);
        IStableSwap2Pool(USDT_POOL).exchange(1, 0, actorCrvUsd, 0);
        vm.stopPrank();

        uint256 finalUsdt = IERC20(USDT).balanceOf(actor);
        assertGt(expanded, EXPANSION_STEP);
        assertGt(aggregateReward, 20e6);
        assertLt(finalUsdt, TEMPORARY_USDT);
        assertEq(IERC20(CRVUSD).balanceOf(actor), 0);
        assertEq(pegKeeper.deployed_crvusd(), expanded);
        assertGt(pegKeeper.protocol_surplus(), 0);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
        assertEq(IERC20AllowanceView(CRVUSD).allowance(address(pegKeeper), USDT_POOL), 0);
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        MockPegKeeperFactory pegKeeperFactory =
            new MockPegKeeperFactory(FACTORY, governance, emergencyAdmin, FEE_SPLITTER);
        bytes memory constructorArgs =
            abi.encode(address(pegKeeperFactory), USDT_POOL, USDT, USDS, SUSDS, CAPACITY, 1);
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
