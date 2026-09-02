// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Lists the estimate functions used by PegKeeperV3 contracts.
interface IPegKeeperV3PreviewModule {
    /// @notice Estimates an expansion for the calling keeper; actual results may differ.
    function previewExpansion(address keeper, uint256 amount)
        external
        view
        returns (
            uint256 targetOut,
            uint256 backingAssetOut,
            uint256 grossProfit,
            uint256 keeperReward,
            uint256 yieldTokenOut,
            bool deployToYield
        );

    /// @notice Estimates selling the calling keeper's target tokens from current data; actual results may differ.
    function previewUndeployedContraction(address keeper, uint256 amount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit);

    /// @notice Estimates selling the calling keeper's final tokens from current data; actual results may differ.
    function previewKeeperBuyback(address keeper, uint256 amount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit);
}
