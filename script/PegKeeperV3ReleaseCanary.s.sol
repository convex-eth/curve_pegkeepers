// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {PegKeeperV3Factory} from "../src/PegKeeperV3Factory.sol";
import {DeployPegKeeperV3Factory} from "./DeployPegKeeperV3Factory.s.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice Current-state mainnet simulation. This script never broadcasts.
contract PegKeeperV3ReleaseCanary is Script, StdCheats {
    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;
    address internal constant THREE_POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address internal constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address internal constant CANARY_ADMIN = address(0xC0FFEE01);
    address internal constant CANARY_TRADER = address(0xC0FFEE02);
    address internal constant CANARY_KEEPER = address(0xC0FFEE03);
    address internal constant CANARY_FACTORY_OWNER = address(0xC0FFEE04);

    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;
    uint256 internal constant ALLOCATION = 1_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 100_000e18;

    function run() external {
        require(block.chainid == 1, "mainnet fork required");

        IPegKeeperV3.RouteStep[] memory expansionPath = _expansionPath();
        IPegKeeperV3.RouteStep[] memory contractionPath = _contractionPath();

        DeployPegKeeperV3Factory factoryDeployer = new DeployPegKeeperV3Factory();
        DeployPegKeeperV3Factory.Config memory factoryConfig = DeployPegKeeperV3Factory.Config({
            owner: CANARY_FACTORY_OWNER,
            controllerFactory: FACTORY,
            admin: CANARY_ADMIN,
            emergencyAdmin: EMERGENCY_ADMIN,
            feeReceiver: FEE_SPLITTER,
            maxDeployedCrvUsd: ALLOCATION,
            targetAmmExecutionBufferBps: 0,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100
        });
        (, address factoryAddress) = factoryDeployer.deploy(factoryConfig);
        PegKeeperV3Factory deploymentFactory = PegKeeperV3Factory(factoryAddress);
        vm.prank(CANARY_FACTORY_OWNER);
        IPegKeeperV3 pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(USDT_POOL, SUSDS, expansionPath, contractionPath)
        );

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(CANARY_ADMIN);
        pegKeeper.set_direction_paused(5, false);
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
        require(expectedYieldToken > 0, "current route preview returned zero yield");

        (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,,
            bool deployedToYield
        ) = _expandAsKeeper(pegKeeper);
        require(crvUsdSold == EXPANSION_AMOUNT, "unexpected crvUSD spend");
        require(backingRetained == 0, "unexpected fallback backing");
        require(deployedToYield, "live expansion selected fallback");
        require(yieldTokenReceived > 0, "live expansion returned zero yield");
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
        require(IERC20Allowance(DAI).allowance(address(pegKeeper), DAI_USDS) == 0, "DAI allowance");
        require(IERC20Allowance(USDS).allowance(address(pegKeeper), SUSDS) == 0, "USDS allowance");
        require(
            IERC20(SUSDS).balanceOf(address(pegKeeper)) == yieldTokenReceived, "yield accounting"
        );

        uint256 contractionQuoteAmount = yieldTokenReceived / 10;
        (uint256 expectedCrvUsd,,,) = pegKeeper.previewKeeperBuyback(contractionQuoteAmount);
        require(expectedCrvUsd > 0, "current contraction route returned zero crvUSD");

        console2.log("mainnet block", block.number);
        console2.log("simulated PegKeeperV3", address(pegKeeper));
        console2.log("crvUSD sold", crvUsdSold);
        console2.log("sUSDS received", yieldTokenReceived);
        console2.log("contraction quote sUSDS", contractionQuoteAmount);
        console2.log("contraction quote crvUSD", expectedCrvUsd);
        console2.log("expansion path hash");
        console2.logBytes32(keccak256(abi.encode(expansionPath)));
        console2.log("contraction path hash");
        console2.logBytes32(keccak256(abi.encode(contractionPath)));
    }

    function _expandAsKeeper(IPegKeeperV3 pegKeeper)
        internal
        returns (uint256, uint256, uint256, uint256, bool)
    {
        vm.prank(CANARY_KEEPER);
        return pegKeeper.expand(EXPANSION_AMOUNT);
    }

    function _expansionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(THREE_POOL, USDT, DAI, 2, 0, 5);
        path[1] = _converterStep(DAI, USDS);
        path[2] = _vaultStep(ERC4626_DEPOSIT, USDS, SUSDS);
    }

    function _contractionPath() internal pure returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](4);
        path[0] = _vaultStep(ERC4626_REDEEM, SUSDS, USDS);
        path[1] = _converterStep(USDS, DAI);
        path[2] = _curveStep(THREE_POOL, DAI, USDT, 0, 2, 5);
        path[3] = _curveStep(USDT_POOL, USDT, CRVUSD, 0, 1, 5);
    }

    function _converterStep(address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: DAI_USDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
    }

    function _vaultStep(uint256 kind, address tokenIn, address tokenOut)
        internal
        pure
        returns (IPegKeeperV3.RouteStep memory)
    {
        return IPegKeeperV3.RouteStep({
            kind: kind,
            venue: SUSDS,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
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
