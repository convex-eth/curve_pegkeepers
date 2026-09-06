// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IStableSwap2Pool {
    function coins(uint256 index) external view returns (address);
    function balances(uint256 index) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
    function calc_withdraw_one_coin(uint256 lpTokens, int128 index)
        external
        view
        returns (uint256 amountOut);
    function remove_liquidity_one_coin(uint256 lpTokens, int128 index, uint256 minAmount)
        external
        returns (uint256 amountOut);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256 amountOut);
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut);
}

interface IStableSwap2PoolDynamic is IStableSwap2Pool {
    function calc_token_amount(uint256[] calldata amounts, bool isDeposit)
        external
        view
        returns (uint256 lpTokens);
    function add_liquidity(uint256[] calldata amounts, uint256 minMintAmount)
        external
        returns (uint256 lpTokens);
}

interface IStableSwap2PoolFixed is IStableSwap2Pool {
    function calc_token_amount(uint256[2] calldata amounts, bool isDeposit)
        external
        view
        returns (uint256 lpTokens);
    function add_liquidity(uint256[2] calldata amounts, uint256 minMintAmount)
        external
        returns (uint256 lpTokens);
}
