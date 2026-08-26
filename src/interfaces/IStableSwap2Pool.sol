// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IStableSwap2Pool {
    function coins(uint256 index) external view returns (address);
    function balances(uint256 index) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy)
        external
        returns (uint256 amountOut);
}
