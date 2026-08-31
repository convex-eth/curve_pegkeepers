// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {ICurveStablecoinOracle} from "../src/interfaces/ICurveStablecoinOracle.sol";

contract DeployPegKeeperV3Oracles is Script {
    struct Config {
        address usdcUsdtPool;
        address frxUsdSusdsPool;
        address sfrxUsdFrxUsdPool;
        address frxUsd;
        address sfrxUsd;
        address susds;
        address usdc;
        address usdt;
    }

    function run()
        external
        returns (
            address frxUsdOracle,
            address frxUsdBackingOracle,
            address usdcOracle,
            address usdtOracle,
            address susdsBackingOracle
        )
    {
        Config memory config = Config({
            usdcUsdtPool: vm.envAddress("PKV3_USDC_USDT_ORACLE_POOL"),
            frxUsdSusdsPool: vm.envAddress("PKV3_FRXUSD_SUSDS_ORACLE_POOL"),
            sfrxUsdFrxUsdPool: vm.envAddress("PKV3_SFRXUSD_FRXUSD_ORACLE_POOL"),
            frxUsd: vm.envAddress("PKV3_FRXUSD"),
            sfrxUsd: vm.envAddress("PKV3_SFRXUSD"),
            susds: vm.envAddress("PKV3_SUSDS"),
            usdc: vm.envAddress("PKV3_USDC"),
            usdt: vm.envAddress("PKV3_USDT")
        });
        vm.startBroadcast();
        (frxUsdOracle, frxUsdBackingOracle, usdcOracle, usdtOracle, susdsBackingOracle) =
            deploy(config);
        vm.stopBroadcast();
    }

    function deploy(Config memory config)
        public
        returns (
            address frxUsdOracle,
            address frxUsdBackingOracle,
            address usdcOracle,
            address usdtOracle,
            address susdsBackingOracle
        )
    {
        frxUsdOracle = _deployAdapter(config.frxUsdSusdsPool, config.frxUsd, config.susds);
        frxUsdBackingOracle =
            _deployAdapter(config.sfrxUsdFrxUsdPool, config.sfrxUsd, config.frxUsd);
        usdcOracle = _deployAdapter(config.usdcUsdtPool, config.usdc, config.usdt);
        usdtOracle = _deployAdapter(config.usdcUsdtPool, config.usdt, config.usdc);
        susdsBackingOracle = _deployAdapter(config.frxUsdSusdsPool, config.susds, config.frxUsd);

        _verify(frxUsdOracle, config.frxUsdSusdsPool, config.frxUsd, config.susds, true);
        _verify(frxUsdBackingOracle, config.sfrxUsdFrxUsdPool, config.sfrxUsd, config.frxUsd, true);
        _verify(usdcOracle, config.usdcUsdtPool, config.usdc, config.usdt, true);
        _verify(usdtOracle, config.usdcUsdtPool, config.usdt, config.usdc, false);
        _verify(susdsBackingOracle, config.frxUsdSusdsPool, config.susds, config.frxUsd, false);
    }

    function _deployAdapter(address pool, address asset, address referenceAsset)
        internal
        returns (address deployed)
    {
        bytes memory creationCode =
            vm.getCode("out/CurveStablecoinOracle.vy/CurveStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(pool, asset, referenceAsset));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _verify(
        address adapter,
        address pool,
        address asset,
        address referenceAsset,
        bool inverted
    ) internal view {
        require(adapter.code.length > 0, "oracle code missing");
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(adapter);
        require(oracle.pool() == pool, "oracle pool mismatch");
        require(oracle.asset() == asset, "oracle asset mismatch");
        require(oracle.reference_asset() == referenceAsset, "oracle reference mismatch");
        require(oracle.inverted() == inverted, "oracle orientation mismatch");
        require(oracle.price() > 0, "oracle price invalid");
    }
}
