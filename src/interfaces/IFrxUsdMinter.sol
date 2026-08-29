// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Mint-only interface for an external-share USDC-to-frxUSD custodian.
interface IFrxUsdMinter {
    function asset() external view returns (address);
    function frxUSD() external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}
