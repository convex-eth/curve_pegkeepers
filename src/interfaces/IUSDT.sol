// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Legacy USDT does not return a value from approve.
interface IUSDT {
    function approve(address spender, uint256 amount) external;
}
