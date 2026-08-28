// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";

contract PegKeeperV3UndeployedContractionForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_837_866;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    uint256 internal constant ALLOCATION = 1_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;
    uint256 internal constant TARGET_AMOUNT = 50_000e6;
    uint256 internal constant TARGET_MULTIPLIER = 1e12;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveUsdtPoolUndeployedBackingContraction() public {
        IPegKeeperV3 pegKeeper = _deploy();
        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);

        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_direction_paused(3, false);
        vm.stopPrank();

        deal(USDT, address(this), 10_000_000e6);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);

        vm.prank(keeper);
        pegKeeper.expand(EXPANSION_AMOUNT);
        uint256 backingBefore = pegKeeper.undeployed_backing();
        uint256 deployedBefore = pegKeeper.deployed_crvusd();
        assertGe(backingBefore, TARGET_AMOUNT);

        deal(CRVUSD, address(this), 45_000_000e18);
        IERC20(CRVUSD).approve(USDT_POOL, 45_000_000e18);
        IStableSwap2Pool(USDT_POOL).exchange(1, 0, 45_000_000e18, 0);

        uint256 expectedOut = IStableSwap2Pool(USDT_POOL).get_dy(0, 1, TARGET_AMOUNT);
        uint256 targetValue = TARGET_AMOUNT * TARGET_MULTIPLIER;
        uint256 grossProfit = expectedOut - targetValue;
        uint256 expectedReward = grossProfit * 3_000 / 10_000;
        if (expectedReward > 20e18) expectedReward = 20e18;
        uint256 expectedNet = expectedOut - expectedReward;
        assertGe(expectedNet, targetValue + targetValue * 5_000 / 1_000_000);

        uint256 keeperCrvUsdBefore = IERC20(CRVUSD).balanceOf(keeper);
        vm.prank(keeper);
        (uint256 spent, uint256 received, uint256 reward) =
            pegKeeper.contractUndeployedBacking(TARGET_AMOUNT);

        assertEq(spent, TARGET_AMOUNT);
        assertEq(received, expectedOut);
        assertEq(reward, expectedReward);
        assertEq(IERC20(CRVUSD).balanceOf(keeper) - keeperCrvUsdBefore, expectedReward);
        assertEq(pegKeeper.undeployed_backing(), backingBefore - TARGET_AMOUNT);
        assertEq(pegKeeper.deployed_crvusd(), deployedBefore - expectedNet);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            FACTORY,
            USDT_POOL,
            USDT,
            FRXUSD,
            SFRXUSD,
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
