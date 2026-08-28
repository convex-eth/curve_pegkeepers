// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

contract PegKeeperV3RuntimeSizeTest is Test {
    uint256 internal constant EIP_170_RUNTIME_LIMIT = 24_576;

    function test_runtimeFitsEip170() public view {
        bytes memory runtime = vm.getDeployedCode("PegKeeperV3.vy");
        assertLe(runtime.length, EIP_170_RUNTIME_LIMIT, "PegKeeperV3 exceeds EIP-170");
    }
}
