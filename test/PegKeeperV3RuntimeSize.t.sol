// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant DIRECT_IMPLEMENTATION_RUNTIME_BUDGET = 18_000;
    uint256 internal constant RELEASE_IMPLEMENTATION_INITCODE_SIZE = 18_114;
    uint256 internal constant RELEASE_IMPLEMENTATION_RUNTIME_SIZE = 17_997;
    bytes32 internal constant RELEASE_IMPLEMENTATION_RUNTIME_HASH =
        0xbeff6ee5eb8ffc4852b320b742051b57369af0cec19850501231fc3c3b2b6acf;
    uint256 internal constant MINIMAL_PROXY_INITCODE_SIZE = 55;
    uint256 internal constant MINIMAL_PROXY_RUNTIME_SIZE = 45;

    function test_directImplementationAndMinimalProxyFitProtocolLimits() public {
        bytes memory implementationInitCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
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
        assertEq(implementation.codehash, RELEASE_IMPLEMENTATION_RUNTIME_HASH, "runtime hash drift");
        assertLe(
            implementation.code.length, EIP_170_RUNTIME_LIMIT, "implementation exceeds EIP-170"
        );
        assertLe(
            implementation.code.length,
            DIRECT_IMPLEMENTATION_RUNTIME_BUDGET,
            "implementation exceeds direct-core budget"
        );
        assertTrue(IPegKeeperV3(implementation).initialized(), "implementation is not locked");

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
