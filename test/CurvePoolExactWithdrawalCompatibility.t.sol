// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "../src/interfaces/IERC20.sol";
import {
    IStableSwap2PoolDynamic,
    IStableSwap2PoolFixed
} from "../src/interfaces/IStableSwap2Pool.sol";

contract CurvePoolExactWithdrawalCompatibilityTest is Test {
    uint256 internal constant PINNED_BLOCK = 25_868_730;
    uint256 internal constant CRVUSD_WITHDRAWAL = 100e18;

    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    address internal constant FRXUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
    address internal constant SUSDE_POOL = 0x57064F49Ad7123C92560882a45518374ad982e85;
    address internal constant USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")), PINNED_BLOCK
        );
    }

    function test_frxUsdDynamicExactWithdrawal() public {
        _exerciseDynamic(FRXUSD_POOL, FRXUSD, 0, 1, 1_000e18);
    }

    function test_sUsdeDynamicExactWithdrawal() public {
        _exerciseDynamic(SUSDE_POOL, SUSDE, 1, 0, 1_000e18);
    }

    function test_usdcFixedExactWithdrawal() public {
        _exerciseFixed(USDC_POOL, USDC, 1_000e6);
    }

    function test_usdtFixedExactWithdrawal() public {
        _exerciseFixed(USDT_POOL, USDT, 1_000e6);
    }

    function _exerciseDynamic(
        address pool,
        address pairedToken,
        uint256 pairedIndex,
        uint256 crvUsdIndex,
        uint256 pairedAmount
    ) internal {
        address provider = makeAddr(string.concat("dynamic provider ", vm.toString(pool)));
        deal(pairedToken, provider, pairedAmount);
        deal(CRVUSD, provider, 1_000e18);

        vm.startPrank(provider);
        IERC20(pairedToken).approve(pool, pairedAmount);
        IERC20(CRVUSD).approve(pool, 1_000e18);
        uint256[] memory depositAmounts = new uint256[](2);
        depositAmounts[pairedIndex] = pairedAmount;
        depositAmounts[crvUsdIndex] = 1_000e18;
        IStableSwap2PoolDynamic(pool).add_liquidity(depositAmounts, 0);
        vm.stopPrank();

        _withdrawDynamic(pool, provider, crvUsdIndex);
    }

    function _withdrawDynamic(address pool, address provider, uint256 crvUsdIndex) internal {
        uint256[] memory amounts = new uint256[](2);
        amounts[crvUsdIndex] = CRVUSD_WITHDRAWAL;
        uint256 quote = IStableSwap2PoolDynamic(pool).calc_token_amount(amounts, false);
        uint256 lpBefore = IERC20(pool).balanceOf(provider);
        uint256 crvUsdBefore = IERC20(CRVUSD).balanceOf(provider);

        vm.prank(provider);
        uint256 reportedBurn =
            IStableSwap2PoolDynamic(pool).remove_liquidity_imbalance(amounts, quote + 1);

        assertEq(reportedBurn, quote + 1);
        assertEq(lpBefore - IERC20(pool).balanceOf(provider), reportedBurn);
        assertEq(IERC20(CRVUSD).balanceOf(provider) - crvUsdBefore, CRVUSD_WITHDRAWAL);
    }

    function _exerciseFixed(address pool, address pairedToken, uint256 pairedAmount) internal {
        address provider = makeAddr(string.concat("fixed provider ", vm.toString(pool)));
        _fundFixedProvider(provider, pairedToken, pairedAmount);

        vm.startPrank(provider);
        _approvePairedToken(pairedToken, pool, pairedAmount);
        IERC20(CRVUSD).approve(pool, 1_000e18);
        uint256[2] memory depositAmounts = [pairedAmount, 1_000e18];
        IStableSwap2PoolFixed(pool).add_liquidity(depositAmounts, 0);
        vm.stopPrank();

        _withdrawFixed(pool, provider);
    }

    function _withdrawFixed(address pool, address provider) internal {
        uint256[2] memory amounts = [uint256(0), CRVUSD_WITHDRAWAL];
        uint256 quote = IStableSwap2PoolFixed(pool).calc_token_amount(amounts, false);
        uint256 lpBefore = IERC20(pool).balanceOf(provider);
        uint256 crvUsdBefore = IERC20(CRVUSD).balanceOf(provider);

        vm.prank(provider);
        uint256 reportedBurn =
            IStableSwap2PoolFixed(pool).remove_liquidity_imbalance(amounts, quote + 1);

        assertEq(reportedBurn, quote + 1);
        assertEq(lpBefore - IERC20(pool).balanceOf(provider), reportedBurn);
        assertEq(IERC20(CRVUSD).balanceOf(provider) - crvUsdBefore, CRVUSD_WITHDRAWAL);
    }

    function _fundFixedProvider(address provider, address pairedToken, uint256 pairedAmount)
        internal
    {
        if (pairedToken == USDT) {
            vm.prank(USDT_WHALE);
            (bool funded,) = USDT.call(abi.encodeCall(IERC20.transfer, (provider, pairedAmount)));
            require(funded, "USDT funding");
        } else {
            deal(pairedToken, provider, pairedAmount);
        }
        deal(CRVUSD, provider, 1_000e18);
    }

    function _approvePairedToken(address pairedToken, address pool, uint256 amount) internal {
        if (pairedToken == USDT) {
            (bool approved,) = USDT.call(abi.encodeCall(IERC20.approve, (pool, amount)));
            require(approved, "USDT approval");
        } else {
            IERC20(pairedToken).approve(pool, amount);
        }
    }
}
