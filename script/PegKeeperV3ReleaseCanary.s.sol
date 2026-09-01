// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {DeployPegKeeperV3} from "./DeployPegKeeperV3.s.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Pinned-block mainnet simulation. This script never broadcasts.
contract PegKeeperV3ReleaseCanary is Script, StdCheats {
    uint256 internal constant PINNED_MAINNET_BLOCK = 25_868_730;
    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant FRXUSD_CUSTODIAN = 0x4F95C5bA0C7c69FB2f9340E190cCeE890B3bd87c;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address internal constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address internal constant CANARY_ADMIN = address(0xC0FFEE01);
    address internal constant CANARY_TRADER = address(0xC0FFEE02);
    address internal constant CANARY_KEEPER = address(0xC0FFEE03);
    address internal constant CANARY_FACTORY_OWNER = address(0xC0FFEE04);

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant FRXUSD_MINT = 4;
    uint256 internal constant FRXUSD_REDEEM = 5;
    uint256 internal constant CURVE_EXECUTION_BUFFER_BPS = 3;
    uint256 internal constant FRXUSD_EXECUTION_BUFFER_BPS = 1;
    uint256 internal constant ALLOCATION = 2_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;
    uint256 internal constant CONTRACTION_MARKET_TRADE = 11_000_000e18;

    function run() external {
        require(block.chainid == 1, "mainnet fork required");
        require(block.number == PINNED_MAINNET_BLOCK, "pinned mainnet block required");

        IPegKeeperV3.RouteStep[] memory expansionPath = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contractionPath = _contractionPath();

        IPegKeeperV3 pegKeeper = _deployCanary(expansionPath, contractionPath);

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(CANARY_ADMIN);
        pegKeeper.set_direction_paused(5, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();

        deal(USDT, CANARY_TRADER, 10_000_000e6);
        vm.startPrank(CANARY_TRADER);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);
        vm.stopPrank();

        (,,,, uint256 expectedYieldToken, bool expectedToDeploy) =
            pegKeeper.previewExpansion(EXPANSION_AMOUNT);
        require(expectedToDeploy, "current route preview selected fallback");
        require(expectedYieldToken > 0, "current route preview returned zero frxUSD");

        (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,,
            bool deployedToYield
        ) = _expandAsKeeper(pegKeeper);
        require(crvUsdSold == EXPANSION_AMOUNT, "unexpected crvUSD spend");
        require(backingRetained == 0, "unexpected fallback backing");
        require(deployedToYield, "live expansion selected fallback");
        require(yieldTokenReceived > 0, "live expansion returned zero frxUSD");
        require(
            pegKeeper.trusted_backing_value() >= pegKeeper.deployed_crvusd(), "principal invariant"
        );
        require(
            IERC20Allowance(CRVUSD).allowance(address(pegKeeper), USDT_POOL) == 0,
            "target allowance"
        );
        require(
            IERC20Allowance(USDT).allowance(address(pegKeeper), THREE_POOL) == 0, "USDT allowance"
        );
        require(
            IERC20Allowance(USDC).allowance(address(pegKeeper), FRXUSD_CUSTODIAN) == 0,
            "USDC allowance"
        );
        require(
            IERC20(FRXUSD).balanceOf(address(pegKeeper)) == yieldTokenReceived, "frxUSD accounting"
        );

        deal(CRVUSD, CANARY_TRADER, CONTRACTION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        IERC20(CRVUSD).approve(USDT_POOL, CONTRACTION_MARKET_TRADE);
        IStableSwap2Pool(USDT_POOL).exchange(1, 0, CONTRACTION_MARKET_TRADE, 0);
        vm.stopPrank();

        uint256 contractionQuoteAmount = yieldTokenReceived / 10;
        (uint256 expectedCrvUsd,,,) = pegKeeper.previewKeeperBuyback(contractionQuoteAmount);
        require(expectedCrvUsd > 0, "current contraction route returned zero crvUSD");

        console2.log("mainnet block", block.number);
        console2.log("simulated PegKeeperV3", address(pegKeeper));
        console2.log("crvUSD sold", crvUsdSold);
        console2.log("frxUSD received", yieldTokenReceived);
        console2.log("contraction quote frxUSD", contractionQuoteAmount);
        console2.log("contraction quote crvUSD", expectedCrvUsd);
        console2.log("expansion path hash");
        console2.logBytes32(keccak256(abi.encode(expansionPath)));
        console2.log("contraction path hash");
        console2.logBytes32(keccak256(abi.encode(contractionPath)));
    }

    function _deployCanary(
        IPegKeeperV3.RouteStep[] memory expansionPath,
        IPegKeeperV3.RouteStep[] memory contractionPath
    ) internal returns (IPegKeeperV3 pegKeeper) {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();
        config.owner = CANARY_FACTORY_OWNER;
        config.controllerFactory = FACTORY;
        config.admin = CANARY_ADMIN;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = ALLOCATION;
        config.targetAmmExecutionBufferBps = CURVE_EXECUTION_BUFFER_BPS;
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);

        IPegKeeperV3Factory deploymentFactory = IPegKeeperV3Factory(deployment.factory);
        vm.prank(CANARY_FACTORY_OWNER);
        pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(
                USDT_POOL,
                FRXUSD,
                false,
                deployment.usdtTargetOracle,
                deployment.frxUsdUsdOracle,
                expansionPath,
                contractionPath
            )
        );
    }

    function _expandAsKeeper(IPegKeeperV3 pegKeeper)
        internal
        returns (uint256, uint256, uint256, uint256, bool)
    {
        vm.prank(CANARY_KEEPER);
        return pegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = _curveStep(THREE_POOL, USDT, USDC, 2, 1, CURVE_EXECUTION_BUFFER_BPS);
        path[1] = _frxUsdStep(FRXUSD_MINT, USDC, FRXUSD);
    }

    function _contractionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _frxUsdStep(FRXUSD_REDEEM, FRXUSD, USDC);
        path[1] = _curveStep(THREE_POOL, USDC, USDT, 1, 2, CURVE_EXECUTION_BUFFER_BPS);
        path[2] = _curveStep(USDT_POOL, USDT, CRVUSD, 0, 1, CURVE_EXECUTION_BUFFER_BPS);
    }

    function _frxUsdStep(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: FRXUSD_CUSTODIAN,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: FRXUSD_EXECUTION_BUFFER_BPS
        });
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 poolIndexIn,
        int128 poolIndexOut,
        uint256 executionBufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: poolIndexIn,
            poolIndexOut: poolIndexOut,
            executionBufferBps: executionBufferBps
        });
    }
}
