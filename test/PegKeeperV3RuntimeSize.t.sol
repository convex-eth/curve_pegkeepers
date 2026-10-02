// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {
    LpYieldAmm,
    LpYieldControllerAndPolicy,
    LpYieldOracle,
    LpYieldToken
} from "./PegKeeperV3LpYield.t.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP_3860_INITCODE_LIMIT = 49_152;
    uint256 internal constant RELEASE_KEEPER_INITCODE_SIZE = 17_582;
    uint256 internal constant RELEASE_KEEPER_CORE_SIZE = 14_831;
    bytes32 internal constant RELEASE_KEEPER_CORE_HASH =
        0x01ffd4d7db52ab8aa13981d39fb4a4b1ac914a0f1a201568ab7d5b7882e8f01a;
    uint256 internal constant RELEASE_KEEPER_RUNTIME_SIZE = 14_863;
    bytes32 internal constant RELEASE_KEEPER_RUNTIME_HASH =
        0xa5406b28497a8b4ec75ad1668165bd38175dfa1e6439b6fb352af71c8e32bf37;

    function test_standaloneKeeperFitsProtocolLimits() public {
        LpYieldToken crvUsd = new LpYieldToken(18);
        LpYieldToken pairedToken = new LpYieldToken(18);
        LpYieldOracle oracle = new LpYieldOracle();
        LpYieldControllerAndPolicy controllerFactory = new LpYieldControllerAndPolicy(
            address(crvUsd), address(this), address(0xBEEF), address(0xFEE), address(oracle)
        );
        LpYieldAmm pool = new LpYieldAmm(address(crvUsd), address(pairedToken));

        bytes memory keeperInitCode = bytes.concat(
            vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"),
            abi.encode(
                address(controllerFactory),
                address(pool),
                false,
                true,
                150_000_000e18,
                1,
                address(oracle)
            ),
            abi.encode(
                10, 150, 3, 3_000, address(this), address(0xBEEF), address(controllerFactory)
            )
        );
        assertEq(keeperInitCode.length, RELEASE_KEEPER_INITCODE_SIZE, "keeper initcode drift");
        assertLe(keeperInitCode.length, EIP_3860_INITCODE_LIMIT, "keeper exceeds EIP-3860");

        address keeperAddress;
        assembly ("memory-safe") {
            keeperAddress := create(0, add(keeperInitCode, 0x20), mload(keeperInitCode))
        }
        assertTrue(keeperAddress != address(0), "keeper deployment failed");
        bytes memory keeperCore = vm.getDeployedCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        assertEq(keeperCore.length, RELEASE_KEEPER_CORE_SIZE, "keeper core size drift");
        assertEq(keccak256(keeperCore), RELEASE_KEEPER_CORE_HASH, "keeper core hash drift");
        assertEq(
            keeperAddress.code,
            bytes.concat(keeperCore, abi.encode(address(crvUsd))),
            "Vyper immutable suffix drift"
        );
        assertEq(keeperAddress.code.length, RELEASE_KEEPER_RUNTIME_SIZE, "keeper runtime drift");
        assertEq(
            keccak256(bytes.concat(keeperCore, abi.encode(CRVUSD))),
            RELEASE_KEEPER_RUNTIME_HASH,
            "mainnet runtime hash drift"
        );
        assertLe(keeperAddress.code.length, EIP_170_RUNTIME_LIMIT, "keeper exceeds EIP-170");
        assertGt(keeperAddress.code.length, 45, "keeper unexpectedly uses a minimal proxy");
        assertEq(IPegKeeperV3(keeperAddress).policy(), address(controllerFactory));

        (bool factoryGetterExists,) = keeperAddress.staticcall(abi.encodeWithSignature("factory()"));
        assertFalse(factoryGetterExists);
        (bool initializedGetterExists,) =
            keeperAddress.staticcall(abi.encodeWithSignature("initialized()"));
        assertFalse(initializedGetterExists);
    }
}
