// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {DeployPegKeeperV3} from "./DeployPegKeeperV3.s.sol";

interface IERC20Allowance {
    function allowance(address owner, address spender) external view returns (uint256);
}

contract CanaryAggregateCrvUsdOracle {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

/// @notice Pinned-block direct-liquidity mainnet simulation. This script never broadcasts.
contract PegKeeperV3ReleaseCanary is Script, StdCheats {
    uint256 internal constant PINNED_MAINNET_BLOCK = 25_868_730;
    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address internal constant FRXUSD_CRVUSD_POOL = 0x13e12BB0E6A2f1A3d6901a59a9d585e89A6243e1;

    address internal constant FEE_SPLITTER = 0x2dFd89449faff8a532790667baB21cF733C064f2;
    address internal constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;
    address internal constant CANARY_ADMIN = address(0xC0FFEE01);
    address internal constant CANARY_TRADER = address(0xC0FFEE02);
    address internal constant CANARY_KEEPER = address(0xC0FFEE03);
    address internal constant CANARY_FACTORY_OWNER = address(0xC0FFEE04);

    uint256 internal constant AMM_EXECUTION_BUFFER_BPS = 3;
    uint256 internal constant ALLOCATION = 2_000_000e18;
    uint256 internal constant EXPANSION_AMOUNT = 40_000e18;
    uint256 internal constant DONATION_SWEEP_AMOUNT = 10_000e18;
    uint256 internal constant EXPANSION_MARKET_TRADE = 2_000_000e18;
    uint256 internal constant CONTRACTION_MARKET_TRADE = 6_000_000e18;

    function run() external {
        require(block.chainid == 1, "mainnet fork required");
        require(block.number == PINNED_MAINNET_BLOCK, "pinned mainnet block required");

        CanaryAggregateCrvUsdOracle aggregateOracle = new CanaryAggregateCrvUsdOracle(1.001e18);
        IPegKeeperV3 pegKeeper = _deployCanary(address(aggregateOracle));

        vm.prank(FACTORY_ADMIN);
        IControllerFactory(FACTORY).set_debt_ceiling(address(pegKeeper), ALLOCATION);
        vm.startPrank(CANARY_ADMIN);
        pegKeeper.set_direction_paused(2, false);
        pegKeeper.set_direction_paused(1, false);
        pegKeeper.set_direction_paused(0, false);
        vm.stopPrank();

        // Make the paired token abundant in the direct AMM.
        deal(FRXUSD, CANARY_TRADER, EXPANSION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        IERC20(FRXUSD).approve(FRXUSD_CRVUSD_POOL, EXPANSION_MARKET_TRADE);
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(0, 1, EXPANSION_MARKET_TRADE, 0);
        vm.stopPrank();

        (uint256 expectedDebt,,, uint256 expectedLp) = pegKeeper.preview_expansion(EXPANSION_AMOUNT);
        require(expectedDebt == EXPANSION_AMOUNT, "unexpected preview debt");
        require(expectedLp > 0, "LP preview returned zero");

        vm.prank(CANARY_KEEPER);
        (uint256 crvUsdDeployed, uint256 lpReceived,) = pegKeeper.expand_supply(EXPANSION_AMOUNT);
        require(crvUsdDeployed == EXPANSION_AMOUNT, "unexpected crvUSD deployment");
        require(lpReceived > 0, "no LP received");
        // forge-lint: disable-next-line(block-timestamp)
        require(pegKeeper.last_intervention_at() == block.timestamp, "expansion timestamp");
        require(pegKeeper.accounted_lp_tokens() > 0, "LP accounting missing");
        require(IERC20(FRXUSD).balanceOf(address(pegKeeper)) == 0, "loose frxUSD");
        require(
            pegKeeper.trusted_backing_value() >= pegKeeper.deployed_crvusd(), "principal invariant"
        );
        require(
            IERC20Allowance(CRVUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "AMM crvUSD allowance"
        );
        require(
            IERC20Allowance(FRXUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "AMM frxUSD allowance"
        );

        uint256 sweepLp = _sweepDonationAsKeeper(pegKeeper);

        aggregateOracle.setPrice(0.999e18);
        _claimDonationAsKeeper(pegKeeper);
        deal(CRVUSD, CANARY_TRADER, CONTRACTION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        IERC20(CRVUSD).approve(FRXUSD_CRVUSD_POOL, CONTRACTION_MARKET_TRADE);
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(1, 0, CONTRACTION_MARKET_TRADE, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + pegKeeper.min_intervention_delay());

        // Fork-only structural canary: this pinned pool state has no executable 5 bp exit.
        // Unit tests pin the production 500 ppm boundary; zero here permits a real one-coin
        // withdrawal without pretending the historical market offered that edge.
        vm.prank(CANARY_ADMIN);
        pegKeeper.set_policy(10, 0, 3_000, 10_000e18, ALLOCATION);

        (
            uint256 contractionLp,
            uint256 expectedCrvUsd,
            uint256 expectedGross,
            uint256 expectedReward
        ) = _findExecutableContraction(pegKeeper);
        require(expectedCrvUsd > 0, "one-coin quote returned zero crvUSD");
        uint256 crvUsdReceived = _contractAsKeeper(pegKeeper, contractionLp);

        console2.log("mainnet block", block.number);
        console2.log("simulated PegKeeperV3", address(pegKeeper));
        console2.log("crvUSD deployed", crvUsdDeployed);
        console2.log("LP received", lpReceived);
        console2.log("donation LP received", sweepLp);
        console2.log("contraction LP", contractionLp);
        console2.log("contraction quote crvUSD", expectedCrvUsd);
        console2.log("contraction gross", expectedGross);
        console2.log("contraction reward", expectedReward);
        console2.log("contraction received crvUSD", crvUsdReceived);
    }

    function _deployCanary(address aggregateOracle) internal returns (IPegKeeperV3 pegKeeper) {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig();
        config.owner = CANARY_FACTORY_OWNER;
        config.controllerFactory = FACTORY;
        config.aggregateCrvUsdOracle = aggregateOracle;
        config.admin = CANARY_ADMIN;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = ALLOCATION;
        config.ammExecutionBufferBps = AMM_EXECUTION_BUFFER_BPS;
        DeployPegKeeperV3.Deployment memory deployment = deployer.deploy(config);

        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        vm.prank(CANARY_FACTORY_OWNER);
        policy.set_factory(deployment.factory);

        IPegKeeperV3Factory deploymentFactory = IPegKeeperV3Factory(deployment.factory);
        address expectedKeeper = _computeCreateAddress(deployment.factory, 1);
        vm.prank(CANARY_FACTORY_OWNER);
        pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(FRXUSD_CRVUSD_POOL, false, deployment.frxUsdUsdOracle)
        );
        vm.prank(CANARY_FACTORY_OWNER);
        policy.set_tier(address(pegKeeper), 1);
        require(address(pegKeeper) == expectedKeeper, "unexpected canary keeper");
    }

    function _sweepDonationAsKeeper(IPegKeeperV3 pegKeeper) internal returns (uint256 lpReceived) {
        uint256 debtBefore = pegKeeper.deployed_crvusd();
        deal(FRXUSD, address(pegKeeper), DONATION_SWEEP_AMOUNT);
        vm.prank(CANARY_KEEPER);
        (uint256 swept, uint256 matched, uint256 sweepLp,) =
            pegKeeper.sweep_donated_paired_token(DONATION_SWEEP_AMOUNT);
        require(swept == DONATION_SWEEP_AMOUNT, "donation sweep amount");
        require(matched == DONATION_SWEEP_AMOUNT, "donation match amount");
        require(sweepLp > 0, "donation sweep LP");
        require(pegKeeper.deployed_crvusd() == debtBefore + matched, "donation debt");
        require(IERC20(FRXUSD).balanceOf(address(pegKeeper)) == 0, "donation residue");
        return sweepLp;
    }

    function _claimDonationAsKeeper(IPegKeeperV3 pegKeeper) internal returns (uint256 claimed) {
        uint256 receiverBalanceBefore = IERC20(CRVUSD).balanceOf(FEE_SPLITTER);
        deal(FRXUSD, address(pegKeeper), DONATION_SWEEP_AMOUNT);
        vm.prank(CANARY_KEEPER);
        claimed = pegKeeper.withdraw_profit(DONATION_SWEEP_AMOUNT);
        require(claimed > 0, "contraction-regime claim");
        require(
            IERC20(CRVUSD).balanceOf(FEE_SPLITTER) - receiverBalanceBefore == claimed,
            "claim receiver delta"
        );
        require(IERC20(FRXUSD).balanceOf(address(pegKeeper)) == 0, "claim donation residue");
    }

    function _contractAsKeeper(IPegKeeperV3 pegKeeper, uint256 lpAmount)
        internal
        returns (uint256 crvUsdReceived)
    {
        vm.prank(CANARY_KEEPER);
        (uint256 lpBurned, uint256 received, uint256 keeperReward) =
            pegKeeper.contract_supply(lpAmount);
        require(lpBurned == lpAmount, "unexpected LP burn");
        require(received > 0, "one-coin withdrawal returned no crvUSD");
        require(keeperReward > 0, "contraction keeper reward missing");
        return received;
    }

    function _findExecutableContraction(IPegKeeperV3 pegKeeper)
        internal
        view
        returns (uint256 lpAmount, uint256 crvUsdOut, uint256 grossProfit, uint256 reward)
    {
        uint256 held = pegKeeper.accounted_lp_tokens();
        for (uint256 i = 1; i <= 100; ++i) {
            uint256 candidate = held * i / 100;
            (bool success, bytes memory result) = address(pegKeeper)
                .staticcall(abi.encodeCall(IPegKeeperV3.preview_contraction, (candidate)));
            if (!success || result.length != 96) continue;
            (crvUsdOut, grossProfit, reward) = abi.decode(result, (uint256, uint256, uint256));
            return (candidate, crvUsdOut, grossProfit, reward);
        }
        revert("no executable contraction");
    }

    function _computeCreateAddress(address creator, uint256 nonce) internal pure returns (address) {
        require(nonce > 0 && nonce <= 0x7f, "unsupported nonce");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes1 encodedNonce = bytes1(uint8(nonce));
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, encodedNonce)))));
    }
}
