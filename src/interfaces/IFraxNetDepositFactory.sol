// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Factory for deterministic FraxNet deposit and redemption accounts.
interface IFraxNetDepositFactory {
    /// @notice Creates the account for a destination and recipient.
    function createFraxNetDeposit(
        uint32 targetEid,
        bytes32 targetAddress,
        bytes32 targetUsdcAtaAddress
    ) external returns (address newContract);

    /// @notice Returns the deterministic account address for a destination and recipient.
    function getDeploymentAddress(
        uint32 targetEid,
        bytes32 targetAddress,
        bytes32 targetUsdcAtaAddress
    ) external view returns (address);

    /// @notice Returns whether an address was created by this factory.
    function isFraxNetDeposit(address account) external view returns (bool);

    /// @notice Returns the direct frxUSD-to-USDC custodian.
    function frxUSDCustodian() external view returns (address);

    /// @notice Returns the currently configured RWA redemption route.
    function rwaRedeemer() external view returns (address);

    /// @notice Returns whether account processing is paused.
    function isPaused() external view returns (bool);
}
