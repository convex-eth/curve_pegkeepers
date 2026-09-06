// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Public ABI for the direct-liquidity PegKeeperV3 factory.
interface IPegKeeperV3Factory {
    struct DeploymentDefaults {
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 maxDeployedCrvUsd;
        uint256 ammExecutionBufferBps;
    }

    error NotOwner();
    error NotPendingOwner();
    error InvalidOwner();
    error InvalidImplementation();
    error InvalidDefaults();
    error InvalidPolicy();
    error InvalidKeeper();
    error InvalidAmm();
    error DeploymentFailed();

    event DefaultsUpdated(
        address indexed admin,
        address indexed emergencyAdmin,
        address indexed feeReceiver,
        uint256 maxDeployedCrvUsd,
        uint256 ammExecutionBufferBps
    );
    event PegKeeperDeployed(
        uint256 indexed index,
        address indexed pegKeeper,
        address indexed implementation,
        address amm,
        address yieldToken
    );
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event PolicyUpdated(address indexed oldPolicy, address indexed newPolicy);
    event ActiveStatusUpdated(address indexed pegKeeper, bool active);

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function controllerFactory() external view returns (address);
    function implementation() external view returns (address);
    function policy() external view returns (address);
    function defaults() external view returns (DeploymentDefaults memory);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function fee_receiver() external view returns (address);
    function activePegKeeperCount() external view returns (uint256);
    function activePegKeeperAt(uint256 index) external view returns (address);
    function is_active(address pegKeeper) external view returns (bool);

    /// @notice Deploys a paused keeper that interacts only with `amm`.
    /// @dev The paired token is the non-crvUSD coin and the backing asset is derived for ERC-4626.
    function deployPegKeeper(address amm, bool yieldTokenIsErc4626, address yieldOracle)
        external
        returns (address pegKeeper);

    function setDefaults(DeploymentDefaults calldata newDefaults) external;
    function setPolicy(address newPolicy) external;
    function set_active(address pegKeeper, bool active) external;
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}
