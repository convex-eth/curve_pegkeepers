// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {ICurveEDAOAdminProxy} from "../src/interfaces/ICurveEDAOAdminProxy.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";
import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";
import {DeployPegKeeperV3} from "./DeployPegKeeperV3.s.sol";

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
    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant EDAO_PROXY = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
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

        _setDebtCeiling(pegKeeper, ALLOCATION);
        require(!pegKeeper.expansion_paused(), "expansion unexpectedly paused");
        require(!pegKeeper.contraction_paused(), "contraction unexpectedly paused");
        require(!pegKeeper.all_execution_paused(), "execution unexpectedly paused");
        require(
            IERC20(CRVUSD).allowance(address(pegKeeper), FACTORY) == type(uint256).max,
            "ControllerFactory crvUSD allowance"
        );

        // Make the paired token abundant in the direct AMM.
        deal(FRXUSD, CANARY_TRADER, EXPANSION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        require(
            IERC20(FRXUSD).approve(FRXUSD_CRVUSD_POOL, EXPANSION_MARKET_TRADE), "frxUSD approval"
        );
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
            IERC20(CRVUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "AMM crvUSD allowance"
        );
        require(
            IERC20(FRXUSD).allowance(address(pegKeeper), FRXUSD_CRVUSD_POOL) == 0,
            "AMM frxUSD allowance"
        );

        uint256 sweepLp = _sweepDonationAsKeeper(pegKeeper);

        aggregateOracle.setPrice(0.999e18);
        _claimDonationAsKeeper(pegKeeper);
        _setDebtCeiling(pegKeeper, 0);
        require(
            IControllerFactory(FACTORY).debt_ceiling_residual(address(pegKeeper))
                == pegKeeper.deployed_crvusd(),
            "idle allocation burn"
        );
        deal(CRVUSD, CANARY_TRADER, CONTRACTION_MARKET_TRADE);
        vm.startPrank(CANARY_TRADER);
        require(
            IERC20(CRVUSD).approve(FRXUSD_CRVUSD_POOL, CONTRACTION_MARKET_TRADE), "crvUSD approval"
        );
        IStableSwap2Pool(FRXUSD_CRVUSD_POOL).exchange(1, 0, CONTRACTION_MARKET_TRADE, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + pegKeeper.min_intervention_delay());

        // Exercise the production primary profit profile at the pinned fork state.

        (
            uint256 contractionLp,
            uint256 expectedCrvUsd,
            uint256 expectedGross,
            uint256 expectedReward
        ) = _findExecutableContraction(pegKeeper);
        require(expectedCrvUsd > 0, "one-coin quote returned zero crvUSD");
        (uint256 crvUsdReceived, uint256 burnableCrvUsd) =
            _contractAndRugReturnedCrvUsd(pegKeeper, contractionLp);

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
        console2.log("rugged crvUSD", burnableCrvUsd);
    }

    function _setDebtCeiling(IPegKeeperV3 pegKeeper, uint256 ceiling) internal {
        vm.prank(OWNERSHIP_AGENT);
        ICurveEDAOAdminProxy(EDAO_PROXY)
            .execute(
                FACTORY,
                abi.encodeCall(IControllerFactory.set_debt_ceiling, (address(pegKeeper), ceiling))
            );
    }

    function _deployCanary(address aggregateOracle) internal returns (IPegKeeperV3 pegKeeper) {
        DeployPegKeeperV3 deployer = new DeployPegKeeperV3();
        DeployPegKeeperV3.Config memory config = deployer.mainnetConfig(CANARY_FACTORY_OWNER);
        config.owner = CANARY_FACTORY_OWNER;
        config.controllerFactory = FACTORY;
        config.aggregateCrvUsdOracle = aggregateOracle;
        config.admin = CANARY_ADMIN;
        config.emergencyAdmin = EMERGENCY_ADMIN;
        config.feeReceiver = FEE_SPLITTER;
        config.maxDeployedCrvUsd = ALLOCATION;
        config.ammExecutionBufferBps = AMM_EXECUTION_BUFFER_BPS;
        DeployPegKeeperV3.Deployment memory deployment = deployer.deployDependencies(config);

        IPegKeeperPolicy policy = IPegKeeperPolicy(deployment.policy);
        vm.prank(CANARY_FACTORY_OWNER);
        policy.set_factory(deployment.factory);

        IPegKeeperV3Factory deploymentFactory = IPegKeeperV3Factory(deployment.factory);
        vm.prank(CANARY_FACTORY_OWNER);
        deploymentFactory.setDefaults(
            IPegKeeperV3Factory.DeploymentDefaults({
                admin: CANARY_ADMIN,
                emergencyAdmin: EMERGENCY_ADMIN,
                feeReceiver: FEE_SPLITTER,
                maxDeployedCrvUsd: ALLOCATION,
                ammExecutionBufferBps: AMM_EXECUTION_BUFFER_BPS
            })
        );
        address expectedKeeper = _computeCreateAddress(deployment.factory, 1);
        vm.prank(CANARY_FACTORY_OWNER);
        pegKeeper = IPegKeeperV3(
            deploymentFactory.deployPegKeeper(
                FRXUSD_CRVUSD_POOL, false, true, deployment.frxUsdUsdOracle
            )
        );
        vm.prank(CANARY_FACTORY_OWNER);
        policy.set_tier(address(pegKeeper), 1);
        vm.prank(CANARY_ADMIN);
        pegKeeper.set_policy(10, 150, 10_000e18, ALLOCATION);
        require(address(pegKeeper) == expectedKeeper, "unexpected canary keeper");
    }

    function _sweepDonationAsKeeper(IPegKeeperV3 pegKeeper) internal returns (uint256 lpReceived) {
        uint256 debtBefore = pegKeeper.deployed_crvusd();
        deal(FRXUSD, CANARY_TRADER, DONATION_SWEEP_AMOUNT);
        vm.prank(CANARY_TRADER);
        require(
            IERC20(FRXUSD).transfer(address(pegKeeper), DONATION_SWEEP_AMOUNT),
            "frxUSD donation transfer"
        );
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
        deal(FRXUSD, CANARY_TRADER, DONATION_SWEEP_AMOUNT);
        vm.prank(CANARY_TRADER);
        require(
            IERC20(FRXUSD).transfer(address(pegKeeper), DONATION_SWEEP_AMOUNT),
            "frxUSD claim donation transfer"
        );
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

    function _contractAndRugReturnedCrvUsd(IPegKeeperV3 pegKeeper, uint256 lpAmount)
        internal
        returns (uint256 crvUsdReceived, uint256 burnedCrvUsd)
    {
        uint256 debtBefore = pegKeeper.deployed_crvusd();
        uint256 residualBefore =
            IControllerFactory(FACTORY).debt_ceiling_residual(address(pegKeeper));
        require(residualBefore == debtBefore, "pre-contraction residual");

        crvUsdReceived = _contractAsKeeper(pegKeeper, lpAmount);
        burnedCrvUsd = IERC20(CRVUSD).balanceOf(address(pegKeeper));
        require(burnedCrvUsd > 0, "no returned crvUSD to burn");
        require(
            pegKeeper.deployed_crvusd() == debtBefore - burnedCrvUsd, "contraction debt reduction"
        );

        uint256 supplyBefore = IERC20(CRVUSD).totalSupply();
        vm.prank(CANARY_KEEPER);
        IControllerFactory(FACTORY).rug_debt_ceiling(address(pegKeeper));
        require(IERC20(CRVUSD).balanceOf(address(pegKeeper)) == 0, "rugged keeper balance");
        require(IERC20(CRVUSD).totalSupply() == supplyBefore - burnedCrvUsd, "rugged crvUSD supply");
        require(
            IControllerFactory(FACTORY).debt_ceiling_residual(address(pegKeeper))
                == residualBefore - burnedCrvUsd,
            "rugged residual"
        );
        require(
            IControllerFactory(FACTORY).debt_ceiling_residual(address(pegKeeper))
                == pegKeeper.deployed_crvusd(),
            "residual debt reconciliation"
        );
        require(
            IERC20(CRVUSD).allowance(address(pegKeeper), FACTORY) == type(uint256).max,
            "rugged ControllerFactory allowance"
        );
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
