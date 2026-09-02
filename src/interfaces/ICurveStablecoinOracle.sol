// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Lists the public functions on the Curve pool price reader.
interface ICurveStablecoinOracle {
    /// @notice Returns the Curve pool used for prices.
    function pool() external view returns (address);
    /// @notice Returns the token being priced.
    function asset() external view returns (address);
    /// @notice Returns the token used as the price reference.
    function reference_asset() external view returns (address);
    /// @notice Returns whether the pool price must be reversed.
    function inverted() external view returns (bool);
    /// @notice Returns the latest smoothed pool price in a standard 18-decimal format.
    function price() external view returns (uint256);
}
