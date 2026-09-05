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

    struct Config {
        address factory;
        address targetAmm;
        address targetAsset;
        address backingAsset;
        address yieldToken;
        address yieldAmm;
        uint256 maxDeployed;
        uint256 keeperIndex;
        address yieldOracle;
    }

    function deploy(
        address factory,
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        uint256 maxDeployed,
        uint256 keeperIndex
    ) internal returns (IPegKeeperV3 keeper) {
        keeper = _deploy(
            Config({
                factory: factory,
                targetAmm: targetAmm,
                targetAsset: targetAsset,
                backingAsset: backingAsset,
                yieldToken: yieldToken,
                yieldAmm: targetAmm,
                maxDeployed: maxDeployed,
                keeperIndex: keeperIndex,
                yieldOracle: address(new PegKeeperV3TestOracle())
            })
        );
    }

    function deploy(
        address factory,
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        uint256 maxDeployed,
        uint256 keeperIndex,
        address yieldOracle
    ) internal returns (IPegKeeperV3 keeper) {
        keeper = _deploy(
            Config({
                factory: factory,
                targetAmm: targetAmm,
                targetAsset: targetAsset,
                backingAsset: backingAsset,
                yieldToken: yieldToken,
                yieldAmm: targetAmm,
                maxDeployed: maxDeployed,
                keeperIndex: keeperIndex,
                yieldOracle: yieldOracle
            })
        );
    }

    function deploy(
        address factory,
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployed,
        uint256 keeperIndex,
        address yieldOracle
    ) internal returns (IPegKeeperV3 keeper) {
        keeper = _deploy(
            Config({
                factory: factory,
                targetAmm: targetAmm,
                targetAsset: targetAsset,
                backingAsset: backingAsset,
                yieldToken: yieldToken,
                yieldAmm: yieldAmm,
                maxDeployed: maxDeployed,
                keeperIndex: keeperIndex,
                yieldOracle: yieldOracle
            })
        );
    }

    function _deploy(Config memory config) private returns (IPegKeeperV3 keeper) {
        address implementation = _deployImplementation();
        address proxy = _clone(implementation);
        vm.prank(config.factory);
        IPegKeeperV3(proxy)
            .initialize(
                config.targetAmm,
                config.targetAsset,
                config.backingAsset,
                config.yieldToken,
                config.yieldAmm,
                config.maxDeployed,
                config.keeperIndex,
                config.yieldOracle
            );
        keeper = IPegKeeperV3(proxy);
    }

    function _deployImplementation() private returns (address implementation) {
        bytes memory previewCreationCode =
            vm.getCode("out/PegKeeperV3PreviewModule.vy/PegKeeperV3PreviewModule.json");
        address module;
        assembly ("memory-safe") {
            module := create(0, add(previewCreationCode, 0x20), mload(previewCreationCode))
            if iszero(module) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(module));
        assembly ("memory-safe") {
            implementation := create(0, add(initCode, 0x20), mload(initCode))
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
