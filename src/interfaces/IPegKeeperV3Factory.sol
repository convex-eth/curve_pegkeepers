// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPegKeeperV3} from "./IPegKeeperV3.sol";

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

    event ImplementationUpdated(
        address indexed oldImplementation, address indexed newImplementation
    );
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

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function controllerFactory() external view returns (address);
    function implementation() external view returns (address);
    function defaults() external view returns (DeploymentDefaults memory);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function fee_receiver() external view returns (address);
    function keeperCount() external view returns (uint256);
    function keeperAt(uint256 index) external view returns (address);
    function isPegKeeper(address candidate) external view returns (bool);
    function implementationOf(address pegKeeper) external view returns (address);

    function deployPegKeeper(
        address targetAmm,
        address yieldToken,
        IPegKeeperV3.RouteStep[] calldata expansionSteps,
        IPegKeeperV3.RouteStep[] calldata contractionSteps
    ) external returns (address pegKeeper);

    function setImplementation(address newImplementation) external;
    function setDefaults(DeploymentDefaults calldata newDefaults) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
