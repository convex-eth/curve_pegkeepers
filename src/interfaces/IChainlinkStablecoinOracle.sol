// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IChainlinkStablecoinOracle {
    function feed() external view returns (address);
    function feed_decimals() external view returns (uint256);
    function max_delay() external view returns (uint256);
    function price() external view returns (uint256);
}
