// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {PegKeeperV3PreviewModule} from "../src/PegKeeperV3PreviewModule.sol";

contract DeployPegKeeperV3Factory is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    struct Config {
        address owner;
        address controllerFactory;
        address admin;
        address emergencyAdmin;
        address feeReceiver;
        uint256 maxDeployedCrvUsd;
        uint256 targetAmmExecutionBufferBps;
        uint256 minDownstreamAttemptGas;
        uint256 fallbackSettlementGasReserve;
        uint256 expansionMaxRouteLossBps;
    }

    function run() external returns (address implementation, address factory) {
        Config memory config = Config({
            owner: vm.envAddress("PKV3_DEPLOYMENT_FACTORY_OWNER"),
            controllerFactory: vm.envAddress("PKV3_CONTROLLER_FACTORY"),
            admin: vm.envAddress("PKV3_ADMIN"),
            emergencyAdmin: vm.envAddress("PKV3_EMERGENCY_ADMIN"),
            feeReceiver: vm.envAddress("PKV3_FEE_RECEIVER"),
            maxDeployedCrvUsd: vm.envUint("PKV3_MAX_DEPLOYED_CRVUSD"),
            targetAmmExecutionBufferBps: vm.envUint("PKV3_TARGET_AMM_BUFFER_BPS"),
            minDownstreamAttemptGas: vm.envUint("PKV3_MIN_DOWNSTREAM_ATTEMPT_GAS"),
            fallbackSettlementGasReserve: vm.envUint("PKV3_FALLBACK_GAS_RESERVE"),
            expansionMaxRouteLossBps: vm.envUint("PKV3_EXPANSION_MAX_ROUTE_LOSS_BPS")
        });

        vm.startBroadcast();
        (implementation, factory) = deploy(config);
        vm.stopBroadcast();
    }

    function deploy(Config memory config) public returns (address implementation, address factory) {
        address previewModule = address(new PegKeeperV3PreviewModule());
        implementation = _deployImplementation(previewModule);

        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: config.admin,
                emergencyAdmin: config.emergencyAdmin,
                feeReceiver: config.feeReceiver,
                maxDeployedCrvUsd: config.maxDeployedCrvUsd,
                targetAmmExecutionBufferBps: config.targetAmmExecutionBufferBps,
                minDownstreamAttemptGas: config.minDownstreamAttemptGas,
                fallbackSettlementGasReserve: config.fallbackSettlementGasReserve,
                expansionMaxRouteLossBps: config.expansionMaxRouteLossBps
            });
        factory = _deployFactory(config.owner, config.controllerFactory, implementation, defaults_);
        _verifyDeployment(implementation, previewModule, IPegKeeperV3Factory(factory), config);
    }

    function _verifyDeployment(
        address implementation,
        address previewModule,
        IPegKeeperV3Factory factory,
        Config memory config
    ) internal view {
        require(implementation.code.length <= EIP_170_RUNTIME_LIMIT, "implementation too large");
        require(previewModule.code.length > 0, "preview module missing");
        require(IPegKeeperV3(implementation).initialized(), "implementation not locked");
        require(
            IPegKeeperV3(implementation).preview_module() == previewModule,
            "preview module mismatch"
        );
        require(factory.owner() == config.owner, "owner mismatch");
        require(
            factory.controllerFactory() == config.controllerFactory, "controller factory mismatch"
        );
        require(factory.implementation() == implementation, "implementation mismatch");
        require(factory.keeperCount() == 0, "initial keeper count");

        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ = factory.defaults();
        require(factory.admin() == config.admin, "admin getter mismatch");
        require(factory.emergency_admin() == config.emergencyAdmin, "emergency getter mismatch");
        require(factory.fee_receiver() == config.feeReceiver, "fee receiver getter mismatch");
        require(defaults_.admin == config.admin, "admin mismatch");
        require(defaults_.emergencyAdmin == config.emergencyAdmin, "emergency mismatch");
        require(defaults_.feeReceiver == config.feeReceiver, "fee receiver mismatch");
        require(defaults_.maxDeployedCrvUsd == config.maxDeployedCrvUsd, "capacity mismatch");
        require(
            defaults_.targetAmmExecutionBufferBps == config.targetAmmExecutionBufferBps,
            "target buffer mismatch"
        );
        require(
            defaults_.minDownstreamAttemptGas == config.minDownstreamAttemptGas,
            "attempt gas mismatch"
        );
        require(
            defaults_.fallbackSettlementGasReserve == config.fallbackSettlementGasReserve,
            "fallback gas mismatch"
        );
        require(
            defaults_.expansionMaxRouteLossBps == config.expansionMaxRouteLossBps,
            "route loss mismatch"
        );
    }

    function _deployImplementation(address previewModule) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(previewModule));
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployFactory(
        address initialOwner,
        address controllerFactory,
        address implementation,
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_
    ) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json");
        bytes memory initCode = bytes.concat(
            creationCode, abi.encode(initialOwner, controllerFactory, implementation, defaults_)
        );
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
