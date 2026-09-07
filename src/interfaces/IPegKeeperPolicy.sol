// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Expansion admission policy shared by PegKeeperV3 instances from one factory.
interface IPegKeeperPolicy {
    error NotOwner();
    error NotPendingOwner();
    error OwnershipHandoffPending();
    error InvalidOwnershipTransferNonce();
    error InvalidOwner();
    error InvalidFactory();
    error InvalidOracle();
    error InvalidThreshold();
    error InvalidKeeper();
    error InvalidTier();
    error TooManySecondaries();

    event FactorySet(address indexed factory);
    event AggregateCrvUsdOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event PrimaryUtilizationUpdated(uint256 oldUtilizationBps, uint256 newUtilizationBps);
    event KeeperProfitShareUpdated(
        uint256 oldKeeperProfitShareBps, uint256 newKeeperProfitShareBps
    );
    event TierUpdated(address indexed pegKeeper, uint256 oldTier, uint256 newTier);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function ownershipTransferNonce() external view returns (uint256);
    function factory() external view returns (address);
    function aggregateCrvUsdOracle() external view returns (address);
    function primaryUtilizationBps() external view returns (uint256);
    function keeper_profit_share_bps(address pegKeeper) external view returns (uint256);
    function primary() external view returns (address);
    function tier(address pegKeeper) external view returns (uint256);
    function secondaryCount() external view returns (uint256);
    function secondaryAt(uint256 index) external view returns (address);
    function tertiaryCount() external view returns (uint256);
    function tertiaryAt(uint256 index) external view returns (address);

    function expansion_regime() external view returns (bool);
    function can_allocate(address pegKeeper) external view returns (bool);
    function can_expand(address pegKeeper) external view returns (bool);
    function can_contract(address pegKeeper) external view returns (bool);

    function set_factory(address factory_) external;
    function set_aggregate_crvusd_oracle(address newOracle) external;
    function set_primary_utilization_bps(uint256 newUtilizationBps) external;
    function set_keeper_profit_share_bps(uint256 newKeeperProfitShareBps) external;
    function set_tier(address pegKeeper, uint256 newTier) external;
    /// @notice Freezes configuration and increments the acceptance nonce for `newOwner`.
    function transferOwnership(address newOwner) external;
    function acceptOwnership(uint256 expectedNonce) external;
}
