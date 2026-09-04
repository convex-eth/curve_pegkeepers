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
    address internal constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;
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

    uint256 internal constant CURVE_EXECUTION_BUFFER_BPS = 3;
    uint256 internal constant FRXUSD_MINT_EXECUTION_BUFFER_BPS = 1;

    uint256 internal constant ALLOCATION = 2_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 40_000e18;
    uint256 internal constant CONTRACTION_MARKET_TRADE = 6_000_000e18;

    function run() external {
        require(block.chainid == 1, "mainnet fork required");
        require(block.number == PINNED_MAINNET_BLOCK, "pinned mainnet block required");

        IPegKeeperV3 pegKeeper = _deployCanary();
        IPegKeeperV3.RouteStep[] memory expansionPath = _expansionPath();

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(CANARY_ADMIN);
        pegKeeper.set_direction_paused(2, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(0, false);
        pegKeeper.set_policy(
            pegKeeper.entry_min_profit_ppm(),
            pegKeeper.normal_exit_min_profit_ppm(),
            pegKeeper.early_exit_min_profit_ppm(),
            pegKeeper.keeper_profit_share_bps(),
            0,
            pegKeeper.min_expansion_amount(),
            pegKeeper.max_deployed_crvusd()
        );
        vm.stopPrank();

        // Put the USDT target pool into an expansion state.
        deal(USDT, CANARY_TRADER, 10_000_000e6);
        vm.startPrank(CANARY_TRADER);
        IUSDT(USDT).approve(USDT_POOL, 10_000_000e6);
        IStableSwap2Pool(USDT_POOL).exchange(0, 1, 10_000_000e6, 0);
        vm.stopPrank();

        (,,,, uint256 expectedLp, bool directPreview) = pegKeeper.previewExpansion(EXPANSION_AMOUNT);
        require(!directPreview, "unexpected direct expansion");
        require(expectedLp > 0, "LP preview returned zero");

        (uint256 crvUsdSold, uint256 crvUsdMatched, uint256 lpReceived,, bool directDeposit) =
            _expandAsKeeper(pegKeeper);
        require(crvUsdSold == EXPANSION_AMOUNT, "unexpected crvUSD spend");
        require(crvUsdMatched > 0, "missing matched crvUSD");
        require(lpReceived > 0, "no LP received");
        require(!directDeposit, "unexpected direct deposit");
        require(pegKeeper.accounted_lp_tokens() > 0, "LP accounting missing");
        require(IERC20(FRXUSD).balanceOf(address(pegKeeper)) == 0, "loose frxUSD");
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
            IERC20Allowance(CRVUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "yield AMM crvUSD allowance"
        );
        require(
            IERC20Allowance(FRXUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "yield AMM frxUSD allowance"
        );

        // Make crvUSD abundant in the held-LP pool, then exercise fixed one-coin withdrawal.
        deal(CRVUSD, CANARY_TRADER, CONTRACTION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        IERC20(CRVUSD).approve(FRXUSD_CRVUSD_POOL, CONTRACTION_MARKET_TRADE);
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(1, 0, CONTRACTION_MARKET_TRADE, 0);
        vm.stopPrank();

        uint256 contractionLp = pegKeeper.accounted_lp_tokens() / 10;
        (uint256 expectedCrvUsd, uint256 expectedGross, uint256 expectedReward,) =
            pegKeeper.previewKeeperBuyback(contractionLp);
        require(expectedCrvUsd > 0, "one-coin quote returned zero crvUSD");
        console2.log("pre-contraction debt", pegKeeper.deployed_crvusd());
        console2.log("pre-contraction backing", pegKeeper.trusted_backing_value());
        console2.log("preview crvUSD", expectedCrvUsd);
        console2.log("preview gross", expectedGross);
        console2.log("preview reward", expectedReward);
        uint256 crvUsdReceived = _contractAsKeeper(pegKeeper, contractionLp);

        console2.log("mainnet block", block.number);
        console2.log("simulated PegKeeperV3", address(pegKeeper));
        console2.log("crvUSD sold", crvUsdSold);
        console2.log("crvUSD matched", crvUsdMatched);
        console2.log("LP received", lpReceived);
        console2.log("contraction LP", contractionLp);
        console2.log("contraction quote crvUSD", expectedCrvUsd);
        console2.log("contraction received crvUSD", crvUsdReceived);
        console2.log("expansion path hash");
        console2.logBytes32(keccak256(abi.encode(expansionPath)));
    }

    function _deployCanary() internal returns (IPegKeeperV3 pegKeeper) {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();
        config.owner = CANARY_FACTORY_OWNER;
        config.controllerFactory = FACTORY;
        config.admin = CANARY_ADMIN;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = ALLOCATION;
        config.targetAmmExecutionBufferBps = CURVE_EXECUTION_BUFFER_BPS;
        config.yieldAmmExecutionBufferBps = CURVE_EXECUTION_BUFFER_BPS;
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);
        IPegKeeperV3Factory deploymentFactory = IPegKeeperV3Factory(deployment.factory);
        address expectedKeeper = _computeCreateAddress(deployment.factory, 1);
        vm.prank(CANARY_FACTORY_OWNER);
        pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(
                USDT_POOL,
                FRXUSD,
                FRXUSD_CRVUSD_POOL,
                false,
                deployment.usdtTargetOracle,
                deployment.frxUsdUsdOracle,
                _expansionPath()
            )
        );
        require(address(pegKeeper) == expectedKeeper, "unexpected canary keeper");
    }

    function _expandAsKeeper(IPegKeeperV3 pegKeeper)
        internal
        returns (uint256, uint256, uint256, uint256, bool)
    {
        vm.prank(CANARY_KEEPER);
        return pegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _contractAsKeeper(IPegKeeperV3 pegKeeper, uint256 lpAmount)
        internal
        returns (uint256 crvUsdReceived)
    {
        vm.prank(CANARY_KEEPER);
        (uint256 lpBurned, uint256 received, uint256 keeperReward) =
            pegKeeper.contractViaAmm(lpAmount);
        require(lpBurned == lpAmount, "unexpected LP burn");
        require(received > 0, "one-coin withdrawal returned no crvUSD");
        require(keeperReward > 0, "contraction keeper reward missing");
        return received;
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](2);
        path[0] = _curveStep(THREE_POOL, USDT, USDC, 2, 1, CURVE_EXECUTION_BUFFER_BPS);
        path[1] = _frxUsdStep(FRXUSD_MINT, USDC, FRXUSD);
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
            executionBufferBps: FRXUSD_MINT_EXECUTION_BUFFER_BPS
        });
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
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
