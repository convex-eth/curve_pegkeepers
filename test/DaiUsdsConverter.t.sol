// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IDaiUsds} from "../src/interfaces/IDaiUsds.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract DaiUsdsConverterTest is Test {
    uint256 internal constant FORK_BLOCK = 25_851_930;
    string internal constant DEFAULT_RPC_URL = "https://mainnet.gateway.tenderly.co";

    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;

    IDaiUsds internal constant converter = IDaiUsds(DAI_USDS);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", DEFAULT_RPC_URL), FORK_BLOCK);
    }

    function test_liveEndpointsAndExactRoundTrip() public {
        assertEq(converter.dai(), DAI);
        assertEq(converter.usds(), USDS);

        uint256 amount = 1_000e18;
        deal(DAI, address(this), amount);

        IERC20(DAI).approve(DAI_USDS, amount);
        uint256 usdsBefore = IERC20(USDS).balanceOf(address(this));
        converter.daiToUsds(address(this), amount);

        assertEq(IERC20(DAI).balanceOf(address(this)), 0);
        assertEq(IERC20(USDS).balanceOf(address(this)) - usdsBefore, amount);

        IERC20(USDS).approve(DAI_USDS, amount);
        uint256 daiBefore = IERC20(DAI).balanceOf(address(this));
        converter.usdsToDai(address(this), amount);

        assertEq(IERC20(USDS).balanceOf(address(this)), usdsBefore);
        assertEq(IERC20(DAI).balanceOf(address(this)) - daiBefore, amount);
    }
}
