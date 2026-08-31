// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3PreviewModule} from "../src/PegKeeperV3PreviewModule.sol";

/// @notice Low-level release helper for the locked implementation and stateless preview module.
/// @dev Keeper proxies must be created and initialized atomically by PegKeeperV3Factory.
contract DeployPegKeeperV3 is Script {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    function run() external returns (address implementation, address previewModule) {
        vm.startBroadcast();
        (implementation, previewModule) = deploy();
        vm.stopBroadcast();
    }

    function deploy() public returns (address implementation, address previewModule) {
        previewModule = address(new PegKeeperV3PreviewModule());
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(previewModule));
        assembly ("memory-safe") {
            implementation := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(implementation) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        _verifyDeployment(implementation, previewModule);
    }

    function _verifyDeployment(address implementation, address previewModule) internal view {
        require(implementation.code.length <= EIP_170_RUNTIME_LIMIT, "implementation too large");
        require(previewModule.code.length > 0, "preview module missing");
        IPegKeeperV3 pegKeeper = IPegKeeperV3(implementation);
        require(pegKeeper.initialized(), "implementation not locked");
        require(pegKeeper.preview_module() == previewModule, "preview module mismatch");
        require(pegKeeper.factory() == address(0), "implementation factory initialized");
        require(pegKeeper.deployed_crvusd() == 0, "implementation exposure");
        require(pegKeeper.all_execution_paused(), "implementation execution enabled");
    }
}
