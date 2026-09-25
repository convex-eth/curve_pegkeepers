// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Governance-owned enumerable PegKeeper discovery list; not an execution gate.
interface IPegKeeperRegistry {
    error InvalidAdmin();
    error InvalidKeeper();
    error DuplicateKeeper();

    event PegKeeperAdded(address indexed pegKeeper);
    event PegKeeperRemoved(address indexed pegKeeper);
    event CommitNewAdmin(address admin);
    event ApplyNewAdmin(address admin);

    function admin() external view returns (address);
    function future_admin() external view returns (address);
    function new_admin_deadline() external view returns (uint256);
    function peg_keeper_count() external view returns (uint256);
    function peg_keepers(uint256 index) external view returns (address);
    function is_active(address pegKeeper) external view returns (bool);

    function add_peg_keepers(address[] calldata pegKeepers) external;
    function remove_peg_keepers(address[] calldata pegKeepers) external;
    function commit_new_admin(address newAdmin) external;
    function apply_new_admin() external;
}
