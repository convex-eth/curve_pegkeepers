// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

contract PegKeeperV3PreviewModuleVyperTest is Test {
    function test_previewModuleDeploysFromVyperArtifact() public {
        bytes memory creationCode =
            vm.getCode("out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json");
        assertGt(creationCode.length, 0, "missing Vyper preview module artifact");

        address previewModule;
        assembly ("memory-safe") {
            previewModule := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(previewModule != address(0), "Vyper preview deployment failed");
        assertGt(previewModule.code.length, 0, "Vyper preview runtime missing");
    }
}
