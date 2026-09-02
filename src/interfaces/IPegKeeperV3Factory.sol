// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPegKeeperV3} from "./IPegKeeperV3.sol";

/// @notice Lists the public functions available on the PegKeeperV3 factory.
interface IPegKeeperV3Factory {
    struct DeploymentDefaults {
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 maxDeployedCrvUsd;
        uint256 targetAmmExecutionBufferBps;
        uint256 minDownstreamAttemptGas;
        uint256 fallbackSettlementGasReserve;
        uint256 expansionMaxRouteLossBps;
    }

    error NotOwner();
    error NotPendingOwner();
    error InvalidOwner();
    error InvalidImplementation();
    error InvalidDefaults();
    error InvalidTargetAmm();
    error DeploymentFailed();

    event DefaultsUpdated(
        address indexed admin,
        address indexed emergencyAdmin,
        address indexed feeReceiver,
        uint256 maxDeployedCrvUsd,
        uint256 targetAmmExecutionBufferBps,
        uint256 minDownstreamAttemptGas,
        uint256 fallbackSettlementGasReserve,
        uint256 expansionMaxRouteLossBps
    );
    event PegKeeperDeployed(
        uint256 indexed index,
        address indexed pegKeeper,
        address indexed implementation,
        address targetAmm,
        address yieldToken
    );
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    /// @notice Returns the account that owns the factory.
    function owner() external view returns (address);
    /// @notice Returns the account that may accept factory ownership.
    function pendingOwner() external view returns (address);
    /// @notice Returns the controller factory used by every keeper.
    function controllerFactory() external view returns (address);
    /// @notice Returns the base keeper code used for new keepers.
    function implementation() external view returns (address);
    /// @notice Returns the current settings used when a keeper is created.
    function defaults() external view returns (DeploymentDefaults memory);
    /// @notice Returns the admin shared by the factory's keepers.
    function admin() external view returns (address);
    /// @notice Returns the emergency account shared by the factory's keepers.
    function emergency_admin() external view returns (address);
    /// @notice Returns the fee receiver shared by the factory's keepers.
    function fee_receiver() external view returns (address);
    /// @notice Returns the number of keepers deployed by this factory.
    function keeperCount() external view returns (uint256);
    /// @notice Returns the keeper recorded at a factory index.
    function keeperAt(uint256 index) external view returns (address);
    /// @notice Returns whether an address is a keeper deployed by this factory.
    function isPegKeeper(address candidate) external view returns (bool);
    /// @notice Returns the base keeper code fixed to a deployed keeper.
    function implementationOf(address pegKeeper) external view returns (address);

    /// @notice Lets the owner deploy a paused keeper, set its token paths, and record it.
    function deployPegKeeper(
        address targetAmm,
        address yieldToken,
        bool yieldTokenIsErc4626,
        address targetOracle,
        address yieldOracle,
        IPegKeeperV3.RouteStep[] calldata expansionSteps,
        IPegKeeperV3.RouteStep[] calldata contractionSteps
    ) external returns (address pegKeeper);

    /// @notice Lets the owner change shared roles and defaults used for future keepers.
    function setDefaults(DeploymentDefaults calldata newDefaults) external;
    /// @notice Names the account that may accept factory ownership.
    function transferOwnership(address newOwner) external;
    /// @notice Accepts factory ownership for the pending owner.
    function acceptOwnership() external;
}
