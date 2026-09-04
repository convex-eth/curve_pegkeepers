// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Detached preview logic used by PegKeeperV3 proxies.
interface IPegKeeperV3PreviewModule {
    /// @notice Estimates an all-or-nothing expansion into the fixed yield AMM.
    /// @dev Must be called by `keeper` because the module treats msg.sender as the keeper.
    function previewExpansion(address keeper, uint256 crvUsdAmount)
        external
        view
        returns (
            uint256 expectedTargetOut,
            uint256 expectedCrvUsdMatched,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperRewardLp,
            uint256 expectedLpTokensOut,
            bool directDeposit
        );
}
