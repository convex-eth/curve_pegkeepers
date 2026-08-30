// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    MockFactory,
    MockToken,
    MockTwoCoinPool,
    MockYieldToken
} from "./PegKeeperV3Foundation.t.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant RELEASE_INITCODE_SIZE = 24_370;
    uint256 internal constant RELEASE_RUNTIME_SIZE = 22_862;

    function test_runtimeAndInitcodeFitProtocolLimits() public {
        MockToken crvUsd = new MockToken(18);
        MockToken targetAsset = new MockToken(6);
        MockToken backingAsset = new MockToken(18);
        MockYieldToken yieldToken = new MockYieldToken(address(backingAsset));
        MockFactory factory =
            new MockFactory(address(crvUsd), address(0xA11CE), address(0xBEEF), address(0xFEE));
        MockTwoCoinPool targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));

        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory),
            address(targetAmm),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            25_000_000e18,
            1
        );
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        assertEq(initCode.length, RELEASE_INITCODE_SIZE, "PegKeeperV3 initcode drift");
        assertLe(initCode.length, EIP_3860_INITCODE_LIMIT, "PegKeeperV3 exceeds EIP-3860");

        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertTrue(deployed != address(0), "PegKeeperV3 deployment failed");
        assertEq(deployed.code.length, RELEASE_RUNTIME_SIZE, "PegKeeperV3 runtime drift");
        assertLe(deployed.code.length, EIP_170_RUNTIME_LIMIT, "PegKeeperV3 exceeds EIP-170");
    }
}
