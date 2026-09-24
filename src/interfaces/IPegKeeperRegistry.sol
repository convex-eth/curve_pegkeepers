// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Governance-owned enumerable PegKeeper discovery list; not an execution gate.
interface IPegKeeperRegistry {
    error NotOwner();
    error NotPendingOwner();
    error OwnershipHandoffPending();
    error InvalidOwnershipTransferNonce();
    error InvalidOwner();
    error InvalidKeeper();
    error DuplicateKeeper();

    event PegKeeperAdded(address indexed pegKeeper);
    event PegKeeperRemoved(address indexed pegKeeper);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownershipTransferNonce() external view returns (uint256);
    function peg_keeper_count() external view returns (uint256);
    function peg_keepers(uint256 index) external view returns (address);
    function is_active(address pegKeeper) external view returns (bool);

    function add_peg_keepers(address[] calldata pegKeepers) external;
    function remove_peg_keepers(address[] calldata pegKeepers) external;
    /// @notice Freezes configuration and increments the acceptance nonce for `newOwner`.
    function transferOwnership(address newOwner) external;
    function acceptOwnership(uint256 expectedNonce) external;
}
