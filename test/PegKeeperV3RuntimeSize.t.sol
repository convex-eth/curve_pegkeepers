// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant RELEASE_IMPLEMENTATION_INITCODE_SIZE = 20_295;
    uint256 internal constant RELEASE_IMPLEMENTATION_RUNTIME_SIZE = 20_137;
    bytes32 internal constant RELEASE_IMPLEMENTATION_RUNTIME_HASH =
        0x4d89d48316e687ac73b19920031ff9c2ad3debd90f11b410d22a1f8770dab647;
    uint256 internal constant MINIMAL_PROXY_INITCODE_SIZE = 55;
    uint256 internal constant MINIMAL_PROXY_RUNTIME_SIZE = 45;

    function test_directImplementationAndMinimalProxyFitProtocolLimits() public {
        bytes memory implementationInitCode =
            bytes.concat(vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"), abi.encode(CRVUSD));
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
