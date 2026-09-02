// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Lists the public functions on the Chainlink price reader.
interface IChainlinkStablecoinOracle {
    /// @notice Returns the Chainlink price source.
    function feed() external view returns (address);
    /// @notice Returns the number of decimal places used by the price source.
    function feed_decimals() external view returns (uint256);
    /// @notice Returns the maximum accepted age of a price update.
    function max_delay() external view returns (uint256);
    /// @notice Returns the latest valid price in a standard 18-decimal format.
    function price() external view returns (uint256);
}
