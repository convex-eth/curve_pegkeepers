// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Aggregate direction policy shared by standalone PegKeeperV3 contracts bound to it.
interface IPegKeeperPolicy {
    error NotOwner();
    error NotPendingOwner();
    error OwnershipHandoffPending();
    error InvalidOwnershipTransferNonce();
    error InvalidOwner();

    error InvalidOracle();
    error InvalidThreshold();
    error InvalidKeeper();
    error DuplicateKeeper();

    event AggregateCrvUsdOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event KeeperProfitShareUpdated(
        uint256 oldKeeperProfitShareBps, uint256 newKeeperProfitShareBps
    );
    event PegKeeperAdded(address indexed pegKeeper);
    event PegKeeperRemoved(address indexed pegKeeper);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownershipTransferNonce() external view returns (uint256);

    function aggregateCrvUsdOracle() external view returns (address);
    function keeper_profit_share_bps(address pegKeeper) external view returns (uint256);
    function peg_keeper_count() external view returns (uint256);
    function peg_keepers(uint256 index) external view returns (address);
    function is_active(address pegKeeper) external view returns (bool);

    function expansion_regime() external view returns (bool);
    function can_allocate(address pegKeeper) external view returns (bool);
    function can_expand(address pegKeeper) external view returns (bool);
    function can_contract(address pegKeeper) external view returns (bool);

    function set_aggregate_crvusd_oracle(address newOracle) external;
    function set_keeper_profit_share_bps(uint256 newKeeperProfitShareBps) external;
    function add_peg_keepers(address[] calldata pegKeepers) external;
    function remove_peg_keepers(address[] calldata pegKeepers) external;
    /// @notice Freezes configuration and increments the acceptance nonce for `newOwner`.
    function transferOwnership(address newOwner) external;
    function acceptOwnership(uint256 expectedNonce) external;
}
