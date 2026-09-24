// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Replaceable global execution policy shared by standalone PegKeeperV3 contracts.
interface IPegKeeperPolicy {
    error NotOwner();
    error NotPendingOwner();
    error OwnershipHandoffPending();
    error InvalidOwnershipTransferNonce();
    error InvalidOwner();
    error InvalidOracle();
    error InvalidFeeReceiver();

    event AggregateCrvUsdOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event FeeReceiverUpdated(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownershipTransferNonce() external view returns (uint256);
    function aggregateCrvUsdOracle() external view returns (address);
    function fee_receiver() external view returns (address);

    function expansion_regime() external view returns (bool);
    function can_expand() external view returns (bool);
    function can_contract() external view returns (bool);

    function set_aggregate_crvusd_oracle(address newOracle) external;
    function set_fee_receiver(address newFeeReceiver) external;
    /// @notice Freezes configuration and increments the acceptance nonce for `newOwner`.
    function transferOwnership(address newOwner) external;
    function acceptOwnership(uint256 expectedNonce) external;
}
