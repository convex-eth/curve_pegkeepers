// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IPegKeeperV3} from "../../src/interfaces/IPegKeeperV3.sol";

contract PegKeeperV3TestOracle {
    uint256 internal _price = 1e18;
    bool public shouldRevert;

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function price() external view returns (uint256) {
        require(!shouldRevert, "oracle failure");
        return _price;
    }
}

library PegKeeperV3TestDeployer {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(
        address factory,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployed,
        uint256 keeperIndex
    ) internal returns (IPegKeeperV3 keeper) {
        return deploy(
            factory,
            backingAsset,
            yieldToken,
            yieldAmm,
            maxDeployed,
            keeperIndex,
            address(new PegKeeperV3TestOracle())
        );
    }

    function deploy(
        address factory,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployed,
        uint256 keeperIndex,
        address yieldOracle
    ) internal returns (IPegKeeperV3 keeper) {
        address implementation = _deployImplementation();
        address proxy = _clone(implementation);
        vm.prank(factory);
        IPegKeeperV3(proxy)
            .initialize(
                backingAsset, yieldToken, yieldAmm, true, maxDeployed, keeperIndex, yieldOracle
            );
        return IPegKeeperV3(proxy);
    }

    function _deployImplementation() private returns (address implementation) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        assembly ("memory-safe") {
            implementation := create(0, add(creationCode, 0x20), mload(creationCode))
            if iszero(implementation) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _clone(address implementation) private returns (address proxy) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            bytes20(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly ("memory-safe") {
            proxy := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(proxy) { revert(0, 0) }
        }
    }
}
