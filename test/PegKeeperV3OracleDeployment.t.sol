// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3Oracles} from "../script/DeployPegKeeperV3Oracles.s.sol";
import {ICurveStablecoinOracle} from "../src/interfaces/ICurveStablecoinOracle.sol";
import {MockCurveOraclePool} from "./CurveStablecoinOracle.t.sol";

contract PegKeeperV3OracleDeploymentTest is Test {
    address internal frxUsd = makeAddr("frxUSD");
    address internal sfrxUsd = makeAddr("sfrxUSD");
    address internal susds = makeAddr("sUSDS");
    address internal usdc = makeAddr("USDC");
    address internal usdt = makeAddr("USDT");

    function test_deploysFiveVerifiedCurvePoolOrientations() public {
        MockCurveOraclePool frxUsdSusdsPool = new MockCurveOraclePool(frxUsd, susds);
        MockCurveOraclePool sfrxUsdFrxUsdPool = new MockCurveOraclePool(sfrxUsd, frxUsd);
        MockCurveOraclePool usdcUsdtPool = new MockCurveOraclePool(usdc, usdt);
        DeployPegKeeperV3Oracles deployer = new DeployPegKeeperV3Oracles();
        DeployPegKeeperV3Oracles.Config memory config = DeployPegKeeperV3Oracles.Config({
            usdcUsdtPool: address(usdcUsdtPool),
            frxUsdSusdsPool: address(frxUsdSusdsPool),
            sfrxUsdFrxUsdPool: address(sfrxUsdFrxUsdPool),
            frxUsd: frxUsd,
            sfrxUsd: sfrxUsd,
            susds: susds,
            usdc: usdc,
            usdt: usdt
        });

        (
            address frxUsdOracle,
            address sfrxUsdOracle,
            address usdcOracle,
            address usdtOracle,
            address susdsOracle
        ) = deployer.deploy(config);

        _assertOracle(frxUsdOracle, address(frxUsdSusdsPool), frxUsd, susds, true);
        _assertOracle(sfrxUsdOracle, address(sfrxUsdFrxUsdPool), sfrxUsd, frxUsd, true);
        _assertOracle(usdcOracle, address(usdcUsdtPool), usdc, usdt, true);
        _assertOracle(usdtOracle, address(usdcUsdtPool), usdt, usdc, false);
        _assertOracle(susdsOracle, address(frxUsdSusdsPool), susds, frxUsd, false);
    }

    function _assertOracle(
        address oracleAddress,
        address pool,
        address asset,
        address referenceAsset,
        bool inverted
    ) internal view {
        ICurveStablecoinOracle oracle = ICurveStablecoinOracle(oracleAddress);
        assertGt(oracleAddress.code.length, 0);
        assertEq(oracle.pool(), pool);
        assertEq(oracle.asset(), asset);
        assertEq(oracle.reference_asset(), referenceAsset);
        assertEq(oracle.inverted(), inverted);
        assertEq(oracle.price(), 1e18);
    }
}
