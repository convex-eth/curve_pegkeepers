// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IPegKeeperV3} from "../../src/interfaces/IPegKeeperV3.sol";

interface IKeeperTestConfigProvider {
    function stablecoin() external view returns (address);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function policy() external view returns (address);
}

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
        address controllerFactory,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDebt,
        uint256 keeperIndex
    ) internal returns (IPegKeeperV3 keeper) {
        return deploy(
            controllerFactory,
            backingAsset,
            yieldToken,
            yieldAmm,
            maxDebt,
            keeperIndex,
            address(new PegKeeperV3TestOracle())
        );
    }

    function deploy(
        address controllerFactory,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDebt,
        uint256 keeperIndex,
        address yieldOracle
    ) internal returns (IPegKeeperV3 keeper) {
        IKeeperTestConfigProvider config = IKeeperTestConfigProvider(controllerFactory);
        bytes memory creationCode = bytes.concat(
            vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json"),
            abi.encode(
                controllerFactory,
                yieldAmm,
                backingAsset != yieldToken,
                true,
                maxDebt,
                keeperIndex,
                yieldOracle
            ),
            abi.encode(10, 500, 0, 3_000, config.admin(), config.emergency_admin(), config.policy())
        );
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        keeper = IPegKeeperV3(deployed);
        require(keeper.backing_asset() == backingAsset, "backing asset mismatch");
    }
}
