// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";

contract PegKeeperV3ExpansionForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_837_866;
    string internal constant DEFAULT_RPC_URL = "https://mainnet.gateway.tenderly.co";

    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant SFRXUSD = 0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    uint256 internal constant MAX_DEPLOYED = 1_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;

    IControllerFactory internal constant factory = IControllerFactory(FACTORY);
    IStableSwap2Pool internal constant usdtPool = IStableSwap2Pool(USDT_POOL);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", DEFAULT_RPC_URL), FORK_BLOCK);
        assertEq(usdtPool.coins(0), USDT);
        assertEq(usdtPool.coins(1), CRVUSD);
    }

    function test_liveUsdtPoolFallbackExpansion() public {
        address governance = makeAddr("v3 governance");
        address emergencyAdmin = makeAddr("v3 emergency admin");
        address keeper = makeAddr("v3 keeper");
        IPegKeeperV3 pegKeeper = _deploy(governance, emergencyAdmin);

        vm.prank(FACTORY_ADMIN);
        factory.set_debt_ceiling(address(pegKeeper), MAX_DEPLOYED);
        assertEq(IERC20(CRVUSD).balanceOf(address(pegKeeper)), MAX_DEPLOYED);

        uint256 purchaseAmount = 10_000_000e6;
        deal(USDT, address(this), purchaseAmount);
        IUSDT(USDT).approve(USDT_POOL, purchaseAmount);
        usdtPool.exchange(0, 1, purchaseAmount, 0);

        uint256 expectedTarget = usdtPool.get_dy(1, 0, EXPANSION_AMOUNT);
        uint256 targetValue = expectedTarget * 1e12;
        assertGt(targetValue, EXPANSION_AMOUNT);
        uint256 grossProfit = targetValue - EXPANSION_AMOUNT;
        uint256 expectedReward = (grossProfit * 3_000 / 10_000) / 1e12;
        uint256 expectedRetained = expectedTarget - expectedReward;
        assertGe(expectedRetained * 1e12, EXPANSION_AMOUNT + EXPANSION_AMOUNT * 50 / 1e6);

        vm.startPrank(governance);
        pegKeeper.set_expansion_config(0, 500_000, 100_000);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();

        vm.prank(keeper);
        (
            uint256 sold,
            uint256 retained,
            uint256 yieldReceived,
            uint256 reward,
            bool deployedToYield
        ) = pegKeeper.expand(EXPANSION_AMOUNT);

        assertEq(sold, EXPANSION_AMOUNT);
        assertEq(retained, expectedRetained);
        assertEq(yieldReceived, 0);
        assertEq(reward, expectedReward);
        assertFalse(deployedToYield);
        assertEq(IERC20(USDT).balanceOf(keeper), expectedReward);
        assertEq(IERC20(USDT).balanceOf(address(pegKeeper)), expectedRetained);
        assertEq(pegKeeper.undeployed_backing(), expectedRetained);
        assertEq(pegKeeper.deployed_crvusd(), EXPANSION_AMOUNT);
        assertGe(pegKeeper.trusted_backing_value(), pegKeeper.deployed_crvusd());
    }

    function _deploy(address governance, address emergencyAdmin)
        internal
        returns (IPegKeeperV3 pegKeeper)
    {
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
            MAX_DEPLOYED
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
