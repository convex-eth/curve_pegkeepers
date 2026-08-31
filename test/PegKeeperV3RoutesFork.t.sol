// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {MockPegKeeperFactory} from "./PegKeeperV3Foundation.t.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {RoutePool} from "./PegKeeperV3Routes.t.sol";

contract PegKeeperV3RoutesForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_851_930;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant MAX_DEPLOYED = 1_000_000e18;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");

    function setUp() public {
        string memory rpcUrl =
            vm.envOr("ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
    }

    function test_liveSusdsExpansionPathValidation() public {
        IPegKeeperV3 pegKeeper = _deploy();
        RoutePool localUsdsCrvUsdPool = new RoutePool(USDS, CRVUSD);
        IPegKeeperV3.RouteStep[] memory expansion = new IPegKeeperV3.RouteStep[](3);
        expansion[0] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: THREE_POOL,
            tokenIn: USDT,
            tokenOut: DAI,
            poolIndexIn: 2,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        expansion[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: DAI_USDS,
            tokenIn: DAI,
            tokenOut: USDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        expansion[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: SUSDS,
            tokenIn: USDS,
            tokenOut: SUSDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });

        IPegKeeperV3.RouteStep[] memory contraction = new IPegKeeperV3.RouteStep[](2);
        contraction[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: SUSDS,
            tokenIn: SUSDS,
            tokenOut: USDS,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        contraction[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(localUsdsCrvUsdPool),
            tokenIn: USDS,
            tokenOut: CRVUSD,
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });

        vm.prank(governance);
        pegKeeper.setPaths(expansion, 25, contraction);

        assertEq(pegKeeper.expansion_path_length(), 3);
        assertEq(pegKeeper.contraction_path_length(), 2);
        assertEq(pegKeeper.expansion_path_step(0).venue, THREE_POOL);
        assertEq(pegKeeper.expansion_path_step(2).venue, SUSDS);
        assertEq(pegKeeper.expansion_max_route_loss_bps(), 25);
    }

    function _deploy() internal returns (IPegKeeperV3 deployedPegKeeper) {
        MockPegKeeperFactory pegKeeperFactory =
            new MockPegKeeperFactory(FACTORY, governance, emergencyAdmin, FEE_SPLITTER);
        deployedPegKeeper = PegKeeperV3TestDeployer.deploy(
            address(pegKeeperFactory), USDT_POOL, USDT, USDS, SUSDS, MAX_DEPLOYED, 1
        );
    }
}
