// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    MockFactory,
    MockToken,
    MockTwoCoinPool,
    MockYieldToken
} from "./PegKeeperV3Foundation.t.sol";
import {
    ExpansionFactory,
    ExpansionOracle,
    ExpansionPool,
    ExpansionToken
} from "./PegKeeperV3Expansion.t.sol";

contract PegKeeperV3EndpointModesTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 10_000e18;

    address internal governance = address(this);
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal buyer = makeAddr("buyer");

    function test_plainErc20EndpointInitializesAndCountsSharedTargetBalanceOnce() public {
        (
            IPegKeeperV3 keeper,
            ExpansionToken finalToken,
            ExpansionToken ignoredCrvUsd,
            ExpansionFactory ignoredFactory
        ) = _deployPlainEndpoint();
        ignoredCrvUsd;
        ignoredFactory;

        finalToken.mint(address(keeper), 123e6);

        assertEq(keeper.backing_asset(), address(finalToken));
        assertEq(keeper.yield_token(), address(finalToken));
        assertFalse(_isErc4626(keeper));
        assertEq(_yieldTokenAssets(keeper, 17e6), 17e6);
        assertEq(keeper.trusted_backing_value(), 123e18);
    }

    function test_plainSharedEndpointAcceptsEmptyRoutesAndSupportsExpansionAndDirectBuyback()
        public
    {
        (
            IPegKeeperV3 keeper,
            ExpansionToken finalToken,
            ExpansionToken crvUsd,
            ExpansionFactory factory
        ) = _deployPlainEndpoint();
        IPegKeeperV3.RouteStep[] memory empty = new IPegKeeperV3.RouteStep[](0);
        IPegKeeperV3.RouteStep[] memory contraction = new IPegKeeperV3.RouteStep[](1);
        contraction[0] = IPegKeeperV3.RouteStep({
            kind: 0,
            venue: keeper.target_amm(),
            tokenIn: address(finalToken),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 3
        });
        keeper.setPaths(empty, 5, contraction);

        factory.setDebtCeiling(address(keeper), MAX_DEPLOYED);
        keeper.set_expansion_config(5, 1_500_000, 300_000);
        keeper.set_direction_paused(5, false);
        keeper.set_direction_paused(0, false);
        keeper.set_direction_paused(2, false);

        crvUsd.mint(address(keeper), EXPANSION_AMOUNT);
        (
            uint256 sold,
            uint256 retained,
            uint256 finalReceived,
            uint256 expansionReward,
            bool deployedToYield
        ) = keeper.expand(EXPANSION_AMOUNT);

        assertEq(sold, EXPANSION_AMOUNT);
        assertEq(retained, 0);
        assertGt(finalReceived, 0);
        assertGt(expansionReward, 0);
        assertTrue(deployedToYield);
        assertEq(keeper.trusted_backing_value(), finalToken.balanceOf(address(keeper)) * 1e12);

        uint256 buybackAmount = 1_000e18;
        crvUsd.mint(buyer, buybackAmount);
        vm.prank(buyer);
        crvUsd.approve(address(keeper), buybackAmount);
        (uint256 expectedOut,,) = keeper.previewBuyback(buybackAmount);

        vm.prank(buyer);
        uint256 actualOut = keeper.buyback(buybackAmount, expectedOut);

        assertEq(actualOut, expectedOut);
        assertEq(finalToken.balanceOf(buyer), expectedOut);
        assertEq(keeper.deployed_crvusd(), EXPANSION_AMOUNT - buybackAmount);
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function test_plainSharedEndpointOracleBackingCountsInventoryOnce() public {
        (
            IPegKeeperV3 keeper,
            ExpansionToken finalToken,
            ExpansionToken crvUsd,
            ExpansionFactory factory
        ) = _deployPlainEndpoint();
        factory.setDebtCeiling(address(keeper), MAX_DEPLOYED);
        keeper.set_expansion_config(5, 1_500_000, 300_000);
        keeper.set_direction_paused(5, false);
        keeper.set_direction_paused(0, false);

        ExpansionOracle(keeper.yield_oracle()).setPrice(0.9997e18);
        finalToken.mint(address(keeper), 100e6);
        crvUsd.mint(address(keeper), 100e18);

        uint256 claimed = keeper.claimSurplus(type(uint256).max);

        assertEq(claimed, 99.97e18);
        assertEq(crvUsd.balanceOf(feeReceiver), claimed);
        assertEq(keeper.deployed_crvusd(), claimed);
    }

    function test_erc4626EndpointRetainsShareConversionValuation() public {
        MockToken crvUsd = new MockToken(18);
        MockToken targetAsset = new MockToken(6);
        MockToken backingAsset = new MockToken(18);
        MockYieldToken yieldToken = new MockYieldToken(address(backingAsset));
        MockFactory factory =
            new MockFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        MockTwoCoinPool targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));
        IPegKeeperV3 keeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetAmm),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            MAX_DEPLOYED,
            1
        );

        targetAsset.mint(address(keeper), 10e6);
        yieldToken.mint(address(keeper), 20e18);

        assertTrue(_isErc4626(keeper));
        assertEq(_yieldTokenAssets(keeper, 7e18), 7e18);
        assertEq(keeper.trusted_backing_value(), 30e18);
    }

    function _deployPlainEndpoint()
        internal
        returns (
            IPegKeeperV3 keeper,
            ExpansionToken finalToken,
            ExpansionToken crvUsd,
            ExpansionFactory factory
        )
    {
        crvUsd = new ExpansionToken(18);
        finalToken = new ExpansionToken(6);
        factory = new ExpansionFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        ExpansionPool targetAmm = new ExpansionPool(crvUsd, finalToken);
        keeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetAmm),
            address(finalToken),
            address(finalToken),
            address(finalToken),
            MAX_DEPLOYED,
            1
        );
    }

    function _isErc4626(IPegKeeperV3 keeper) internal view returns (bool value) {
        (bool success, bytes memory response) =
            address(keeper).staticcall(abi.encodeWithSignature("yield_token_is_erc4626()"));
        require(success && response.length == 32, "endpoint mode getter");
        value = abi.decode(response, (bool));
    }

    function _yieldTokenAssets(IPegKeeperV3 keeper, uint256 units)
        internal
        view
        returns (uint256 assets)
    {
        (bool success, bytes memory response) = address(keeper)
            .staticcall(abi.encodeWithSignature("yield_token_assets(uint256)", units));
        require(success && response.length == 32, "endpoint value getter");
        assets = abi.decode(response, (uint256));
    }
}
