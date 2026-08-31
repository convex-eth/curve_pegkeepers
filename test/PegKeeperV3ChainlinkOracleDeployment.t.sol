// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployPegKeeperV3ChainlinkOracles} from "../script/DeployPegKeeperV3ChainlinkOracles.s.sol";
import {
    IChainlinkStablecoinOracle,
    MockChainlinkFeedRegistry
} from "./ChainlinkStablecoinOracle.t.sol";

contract PegKeeperV3ChainlinkOracleDeploymentTest is Test {
    address internal frxUsd = makeAddr("frxUSD");
    address internal usds = makeAddr("USDS");
    address internal usd = address(840);

    function test_deploysSeparateFrxUsdAndUsdsAdapters() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        registry.setRound(7, 99_990_000, block.timestamp, 7);

        DeployPegKeeperV3ChainlinkOracles deployer = new DeployPegKeeperV3ChainlinkOracles();
        DeployPegKeeperV3ChainlinkOracles.Config memory config =
            DeployPegKeeperV3ChainlinkOracles.Config({
                registry: address(registry),
                quote: usd,
                frxUsd: frxUsd,
                frxUsdExpectedFeed: address(registry),
                frxUsdMaxDelay: 1 hours,
                usds: usds,
                usdsExpectedFeed: address(registry),
                usdsMaxDelay: 2 hours
            });

        (address frxUsdOracle, address usdsOracle) = deployer.deploy(config);

        _assertAdapter(frxUsdOracle, address(registry), frxUsd, 1 hours);
        _assertAdapter(usdsOracle, address(registry), usds, 2 hours);
        assertNotEq(frxUsdOracle, usdsOracle);
    }

    function _assertAdapter(address adapter, address registry, address base, uint256 maxDelay)
        internal
        view
    {
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        assertGt(adapter.code.length, 0);
        assertEq(oracle.registry(), registry);
        assertEq(oracle.base(), base);
        assertEq(oracle.quote(), usd);
        assertEq(oracle.feed(), registry);
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), maxDelay);
        assertEq(oracle.price(), 999_900_000_000_000_000);
    }
}
