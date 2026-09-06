// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Expansion admission policy shared by PegKeeperV3 instances from one factory.
interface IPegKeeperPolicy {
    error NotOwner();
    error NotPendingOwner();
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
    event TierUpdated(address indexed pegKeeper, uint256 oldTier, uint256 newTier);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function factory() external view returns (address);
    function aggregateCrvUsdOracle() external view returns (address);
    function primaryUtilizationBps() external view returns (uint256);
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
    function set_tier(address pegKeeper, uint256 newTier) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
