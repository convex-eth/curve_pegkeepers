// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice External-share USDC/frxUSD mint and redemption custodian interface.
interface IFrxUsdMinter {
    function asset() external view returns (address);
    function frxUSD() external view returns (address);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets);
}
