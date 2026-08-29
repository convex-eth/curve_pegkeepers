// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPegKeeperV3} from "./interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "./interfaces/IPegKeeperV3Factory.sol";

interface IControllerFactoryView {
    function stablecoin() external view returns (address);
}

interface ITwoCoinPoolView {
    function coins(uint256 index) external view returns (address);
}

interface IYieldTokenView {
    function asset() external view returns (address);
}

/// @notice Owner-gated deployment registry for immutable PegKeeperV3 instances.
/// @dev The implementation is an EIP-5202 creation-code blueprint used only by future deployments.
contract PegKeeperV3Factory is IPegKeeperV3Factory {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BLUEPRINT_PREAMBLE = 0xfe7100;
    uint256 internal constant BLUEPRINT_CODE_OFFSET = 3;

    error NotOwner();
    error NotPendingOwner();
    error InvalidOwner();
    error InvalidImplementation();
    error InvalidDefaults();
    error InvalidTargetAmm();
    error DeploymentFailed();

    address public override owner;
    address public override pendingOwner;
    address public immutable override controllerFactory;
    address public override implementation;

    DeploymentDefaults private _defaults;

    uint256 public override keeperCount;
    mapping(uint256 => address) public override keeperAt;
    mapping(address => bool) public override isPegKeeper;
    mapping(address => address) public override implementationOf;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        address initialOwner,
        address controllerFactory_,
        address implementation_,
        DeploymentDefaults memory defaults_
    ) {
        if (initialOwner == address(0) || controllerFactory_ == address(0)) revert InvalidOwner();

        owner = initialOwner;
        controllerFactory = controllerFactory_;
        _setImplementation(implementation_);
        _setDefaults(defaults_);

        emit OwnershipTransferred(address(0), initialOwner);
    }

    function defaults() external view override returns (DeploymentDefaults memory) {
        return _defaults;
    }

    function deployPegKeeper(
        address targetAmm,
        address yieldToken,
        IPegKeeperV3.RouteStep[] calldata expansionSteps,
        IPegKeeperV3.RouteStep[] calldata contractionSteps
    ) external override onlyOwner returns (address pegKeeper) {
        (address targetAsset, address backingAsset) = _resolveAssets(targetAmm, yieldToken);
        uint256 index = keeperCount + 1;
        address blueprint = implementation;

        pegKeeper =
            _deployKeeper(blueprint, targetAmm, targetAsset, backingAsset, yieldToken, index);
        _configureKeeper(pegKeeper, expansionSteps, contractionSteps);
        _recordKeeper(index, pegKeeper, blueprint, targetAmm, yieldToken);
    }

    function _resolveAssets(address targetAmm, address yieldToken)
        internal
        view
        returns (address targetAsset, address backingAsset)
    {
        address crvUsd = IControllerFactoryView(controllerFactory).stablecoin();
        address coin0 = ITwoCoinPoolView(targetAmm).coins(0);
        address coin1 = ITwoCoinPoolView(targetAmm).coins(1);
        if (coin0 == crvUsd && coin1 != crvUsd) {
            targetAsset = coin1;
        } else if (coin1 == crvUsd && coin0 != crvUsd) {
            targetAsset = coin0;
        } else {
            revert InvalidTargetAmm();
        }

        backingAsset = IYieldTokenView(yieldToken).asset();
    }

    function _deployKeeper(
        address blueprint,
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        uint256 index
    ) internal returns (address pegKeeper) {
        DeploymentDefaults memory config = _defaults;
        bytes memory constructorArgs = bytes.concat(
            abi.encode(controllerFactory, targetAmm, targetAsset, backingAsset, yieldToken),
            abi.encode(
                config.feeReceiver,
                address(this),
                config.emergencyAdmin,
                config.maxDeployedCrvUsd,
                index
            )
        );
        pegKeeper = _createFromBlueprint(blueprint, constructorArgs);
    }

    function _configureKeeper(
        address pegKeeper,
        IPegKeeperV3.RouteStep[] calldata expansionSteps,
        IPegKeeperV3.RouteStep[] calldata contractionSteps
    ) internal {
        DeploymentDefaults memory config = _defaults;
        IPegKeeperV3(pegKeeper)
            .setPaths(expansionSteps, config.expansionMaxRouteLossBps, contractionSteps);
        IPegKeeperV3(pegKeeper)
            .set_expansion_config(
                config.targetAmmExecutionBufferBps,
                config.minDownstreamAttemptGas,
                config.fallbackSettlementGasReserve
            );
        IPegKeeperV3(pegKeeper).set_roles(config.admin, config.emergencyAdmin);
    }

    function _recordKeeper(
        uint256 index,
        address pegKeeper,
        address blueprint,
        address targetAmm,
        address yieldToken
    ) internal {
        keeperCount = index;
        keeperAt[index] = pegKeeper;
        isPegKeeper[pegKeeper] = true;
        implementationOf[pegKeeper] = blueprint;

        emit PegKeeperDeployed(index, pegKeeper, blueprint, targetAmm, yieldToken);
    }

    function setImplementation(address newImplementation) external override onlyOwner {
        _setImplementation(newImplementation);
    }

    function setDefaults(DeploymentDefaults calldata newDefaults) external override onlyOwner {
        _setDefaults(newDefaults);
    }

    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0) || newOwner == owner) revert InvalidOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external override {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function _setImplementation(address newImplementation) internal {
        if (!_isBlueprint(newImplementation)) revert InvalidImplementation();
        address oldImplementation = implementation;
        implementation = newImplementation;
        emit ImplementationUpdated(oldImplementation, newImplementation);
    }

    function _setDefaults(DeploymentDefaults memory newDefaults) internal {
        if (
            newDefaults.admin == address(0) || newDefaults.emergencyAdmin == address(0)
                || newDefaults.feeReceiver == address(0)
                || newDefaults.admin == newDefaults.emergencyAdmin
                || newDefaults.admin == address(this) || newDefaults.emergencyAdmin == address(this)
                || newDefaults.maxDeployedCrvUsd == 0
                || newDefaults.targetAmmExecutionBufferBps > BPS
                || newDefaults.expansionMaxRouteLossBps > BPS
                || newDefaults.fallbackSettlementGasReserve == 0
                || newDefaults.minDownstreamAttemptGas <= newDefaults.fallbackSettlementGasReserve
        ) revert InvalidDefaults();

        _defaults = newDefaults;
        emit DefaultsUpdated(
            newDefaults.admin,
            newDefaults.emergencyAdmin,
            newDefaults.feeReceiver,
            newDefaults.maxDeployedCrvUsd,
            newDefaults.targetAmmExecutionBufferBps,
            newDefaults.minDownstreamAttemptGas,
            newDefaults.fallbackSettlementGasReserve,
            newDefaults.expansionMaxRouteLossBps
        );
    }

    function _isBlueprint(address candidate) internal view returns (bool) {
        if (candidate.code.length <= BLUEPRINT_CODE_OFFSET) return false;
        uint256 firstWord;
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, 0)
            extcodecopy(candidate, pointer, 0, 3)
            firstWord := mload(pointer)
        }
        return firstWord >> 232 == BLUEPRINT_PREAMBLE;
    }

    function _createFromBlueprint(address blueprint, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        uint256 blueprintSize = blueprint.code.length;
        uint256 creationCodeSize = blueprintSize - BLUEPRINT_CODE_OFFSET;
        uint256 constructorArgsSize = constructorArgs.length;
        bytes memory initCode = new bytes(creationCodeSize + constructorArgsSize);

        assembly {
            extcodecopy(blueprint, add(initCode, 0x20), 3, creationCodeSize)

            let source := add(constructorArgs, 0x20)
            let destination := add(add(initCode, 0x20), creationCodeSize)
            for { let offset := 0 } lt(offset, constructorArgsSize) { offset := add(offset, 0x20) }
            {
                mstore(add(destination, offset), mload(add(source, offset)))
            }

            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }
}
