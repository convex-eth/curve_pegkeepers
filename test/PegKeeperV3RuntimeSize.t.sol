// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET = 22_000;
    uint256 internal constant RELEASE_IMPLEMENTATION_INITCODE_SIZE = 21_435;
    uint256 internal constant RELEASE_IMPLEMENTATION_RUNTIME_SIZE = 21_302;
    uint256 internal constant RELEASE_PREVIEW_INITCODE_SIZE = 5_972;
    uint256 internal constant RELEASE_PREVIEW_RUNTIME_SIZE = 5_936;
    uint256 internal constant MINIMAL_PROXY_INITCODE_SIZE = 55;
    uint256 internal constant MINIMAL_PROXY_RUNTIME_SIZE = 45;

    function test_implementationPreviewModuleAndMinimalProxyFitProtocolLimits() public {
        bytes memory previewCreationCode =
            vm.getCode("out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json");
        assertEq(
            previewCreationCode.length, RELEASE_PREVIEW_INITCODE_SIZE, "preview initcode drift"
        );
        assertLe(
            previewCreationCode.length, EIP_3860_INITCODE_LIMIT, "preview module exceeds EIP-3860"
        );
        address previewModule;
        assembly ("memory-safe") {
            previewModule := create(0, add(previewCreationCode, 0x20), mload(previewCreationCode))
        }
        assertTrue(previewModule != address(0), "preview deployment failed");
        assertEq(previewModule.code.length, RELEASE_PREVIEW_RUNTIME_SIZE, "preview runtime drift");
        assertLe(previewModule.code.length, EIP_170_RUNTIME_LIMIT, "preview module exceeds EIP-170");

        // The Vyper artifact is the semantic template. The immutable preview address adds 32
        // bytes to both the full initcode and the specialized implementation runtime.
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory implementationInitCode = bytes.concat(creationCode, abi.encode(previewModule));
        assertEq(
            implementationInitCode.length,
            RELEASE_IMPLEMENTATION_INITCODE_SIZE,
            "implementation initcode drift"
        );
        assertLe(
            implementationInitCode.length,
            EIP_3860_INITCODE_LIMIT,
            "implementation exceeds EIP-3860"
        );

        address implementation;
        assembly ("memory-safe") {
            implementation := create(
                0,
                add(implementationInitCode, 0x20),
                mload(implementationInitCode)
            )
        }
        assertTrue(implementation != address(0), "implementation deployment failed");
        assertEq(
            implementation.code.length,
            RELEASE_IMPLEMENTATION_RUNTIME_SIZE,
            "implementation runtime drift"
        );
        assertLe(
            implementation.code.length, EIP_170_RUNTIME_LIMIT, "implementation exceeds EIP-170"
        );
        assertLe(
            implementation.code.length,
            REFACTORED_IMPLEMENTATION_RUNTIME_BUDGET,
            "implementation exceeds refactor budget"
        );
        assertTrue(IPegKeeperV3(implementation).initialized(), "implementation is not locked");
        assertEq(IPegKeeperV3(implementation).preview_module(), previewModule);

        bytes memory proxyInitCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(proxyInitCode.length, MINIMAL_PROXY_INITCODE_SIZE);
        address proxy;
        assembly ("memory-safe") {
            proxy := create(0, add(proxyInitCode, 0x20), mload(proxyInitCode))
        }
        assertTrue(proxy != address(0), "minimal proxy deployment failed");
        assertEq(proxy.code.length, MINIMAL_PROXY_RUNTIME_SIZE);
        assertEq(
            proxy.code,
            abi.encodePacked(
                hex"363d3d373d3d3d363d73",
                bytes20(implementation),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
    }
}
