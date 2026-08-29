// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";

contract DeployPegKeeperV3 is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    struct Config {
        address factory;
        address targetAmm;
        address targetAsset;
        address backingAsset;
        address yieldToken;
        uint256 maxDeployedCrvUsd;
        uint256 keeperIndex;
    }

    function run() external returns (address deployed) {
        Config memory config = Config({
            factory: vm.envAddress("PKV3_FACTORY"),
            targetAmm: vm.envAddress("PKV3_TARGET_AMM"),
            targetAsset: vm.envAddress("PKV3_TARGET_ASSET"),
            backingAsset: vm.envAddress("PKV3_BACKING_ASSET"),
            yieldToken: vm.envAddress("PKV3_YIELD_TOKEN"),
            maxDeployedCrvUsd: vm.envUint("PKV3_MAX_DEPLOYED_CRVUSD"),
            keeperIndex: vm.envUint("PKV3_KEEPER_INDEX")
        });

        vm.startBroadcast();
        deployed = deploy(config);
        vm.stopBroadcast();
    }

    function deploy(Config memory config) public returns (address deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            config.factory,
            config.targetAmm,
            config.targetAsset,
            config.backingAsset,
            config.yieldToken,
            config.maxDeployedCrvUsd,
            config.keeperIndex
        );
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "PegKeeperV3 deployment failed");
        _verifyDeployment(deployed, config);
    }

    function _verifyDeployment(address deployed, Config memory config) internal view {
        IPegKeeperV3 pegKeeper = IPegKeeperV3(deployed);
        require(deployed.code.length <= EIP_170_RUNTIME_LIMIT, "PegKeeperV3 runtime too large");
        require(pegKeeper.factory() == config.factory, "factory mismatch");
        address controllerFactory = IPegKeeperV3Factory(config.factory).controllerFactory();
        require(pegKeeper.controller_factory() == controllerFactory, "controller factory mismatch");
        require(
            pegKeeper.crv_usd() == IControllerFactory(controllerFactory).stablecoin(),
            "crvUSD mismatch"
        );
        require(pegKeeper.max_deployed_crvusd() == config.maxDeployedCrvUsd, "capacity mismatch");
        require(pegKeeper.keeper_index() == config.keeperIndex, "keeper index mismatch");
        require(pegKeeper.deployed_crvusd() == 0, "initial exposure");
        require(pegKeeper.undeployed_backing() == 0, "initial backing");
        require(pegKeeper.accounted_yield_token_units() == 0, "initial yield");
        require(pegKeeper.expansion_path_length() == 0, "initial expansion path");
        require(pegKeeper.contraction_path_length() == 0, "initial contraction path");
        require(pegKeeper.target_amm() == config.targetAmm, "target AMM mismatch");
        require(pegKeeper.target_asset() == config.targetAsset, "target asset mismatch");
        require(pegKeeper.backing_asset() == config.backingAsset, "backing asset mismatch");
        require(pegKeeper.yield_token() == config.yieldToken, "yield token mismatch");
        require(
            pegKeeper.fee_receiver() == IPegKeeperV3Factory(config.factory).fee_receiver(),
            "fee receiver mismatch"
        );
        require(pegKeeper.admin() == IPegKeeperV3Factory(config.factory).admin(), "admin mismatch");
        require(
            pegKeeper.emergency_admin() == IPegKeeperV3Factory(config.factory).emergency_admin(),
            "emergency mismatch"
        );
        require(pegKeeper.all_execution_paused(), "global execution enabled");
        require(pegKeeper.expansion_paused(), "expansion enabled");
        require(pegKeeper.backing_deployment_paused(), "backing deployment enabled");
        require(pegKeeper.direct_buyback_paused(), "direct buyback enabled");
        require(pegKeeper.undeployed_contraction_paused(), "undeployed contraction enabled");
        require(pegKeeper.yield_contraction_paused(), "yield contraction enabled");
    }
}
