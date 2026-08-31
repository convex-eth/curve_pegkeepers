// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegKeeperV3PreviewModule {
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

    function previewUndeployedContraction(address keeper, uint256 amount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit);

    function previewKeeperBuyback(address keeper, uint256 amount)
        external
        view
        returns (uint256 expectedCrvUsd, uint256 grossProfit, uint256 keeperReward, bool earlyExit);
}
