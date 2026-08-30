// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";

contract PegKeeperV3BlueprintDeployer {
    constructor(bytes memory creationCode) {
        bytes memory blueprintCode = bytes.concat(hex"fe7100", creationCode);
        assembly {
            return(add(blueprintCode, 0x20), mload(blueprintCode))
        }
    }
}

contract DeployPegKeeperV3Factory is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant BLUEPRINT_PREAMBLE = 0xfe7100;

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

    function run() external returns (address blueprint, address factory) {
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
        (blueprint, factory) = deploy(config);
        vm.stopBroadcast();
    }

    function deploy(Config memory config) public returns (address blueprint, address factory) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        blueprint = address(new PegKeeperV3BlueprintDeployer(creationCode));

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
        factory = _deployFactory(config.owner, config.controllerFactory, blueprint, defaults_);

        _verifyDeployment(blueprint, IPegKeeperV3Factory(factory), config);
    }

    function _verifyDeployment(address blueprint, IPegKeeperV3Factory factory, Config memory config)
        internal
        view
    {
        require(blueprint.code.length <= EIP_170_RUNTIME_LIMIT, "blueprint runtime too large");
        require(_blueprintPreamble(blueprint) == BLUEPRINT_PREAMBLE, "invalid blueprint preamble");
        require(factory.owner() == config.owner, "owner mismatch");
        require(
            factory.controllerFactory() == config.controllerFactory, "controller factory mismatch"
        );
        require(factory.implementation() == blueprint, "implementation mismatch");
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

    function _blueprintPreamble(address blueprint) internal view returns (uint256 preamble) {
        uint256 firstWord;
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, 0)
            extcodecopy(blueprint, pointer, 0, 3)
            firstWord := mload(pointer)
        }
        preamble = firstWord >> 232;
    }
}
