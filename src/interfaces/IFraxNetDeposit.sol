// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice FraxNet account that redeems frxUSD through Frax's configured USDC routes.
interface IFraxNetDeposit {
    /// @notice Returns the token accepted by this account.
    function asset() external view returns (address);

    /// @notice Returns the frxUSD token.
    function frxUSD() external view returns (address);

    /// @notice Returns the USDC token paid by Ethereum redemptions.
    function USDC() external view returns (address);

    /// @notice Returns the factory that configures this account's routes.
    function factory() external view returns (address);

    /// @notice Returns the destination chain identifier.
    function targetEid() external view returns (uint32);

    /// @notice Returns the fixed redemption recipient.
    function targetAddress() external view returns (bytes32);

    /// @notice Redeems frxUSD already transferred to this account.
    function processRedemption(uint256 amount) external payable returns (uint256 usdcOut);
}
