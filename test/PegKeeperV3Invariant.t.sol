// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {PegKeeperV3TestDeployer} from "./utils/PegKeeperV3TestDeployer.sol";
import {
    ExpansionFactory,
    ExpansionOracle,
    ExpansionPool,
    ExpansionToken
} from "./PegKeeperV3Expansion.t.sol";
import {
    ExecutionDaiUsds,
    ExecutionRoutePool,
    ExecutionYieldToken
} from "./PegKeeperV3BackingDeployment.t.sol";

contract PegKeeperV3InvariantHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MIN_EXPANSION = 10_000e18;

    IPegKeeperV3 public immutable keeper;
    ExpansionFactory public immutable factory;
    ExpansionToken public immutable crvUsd;
    ExpansionToken public immutable targetAsset;
    ExpansionToken public immutable yieldToken;

    uint256 public pauseViolations;
    uint256 public actionCalls;
    uint256 public successfulActions;
    mapping(bytes4 selector => uint256 count) public successfulCalls;

    constructor(
        IPegKeeperV3 keeper_,
        ExpansionFactory factory_,
        ExpansionToken crvUsd_,
        ExpansionToken targetAsset_,
        ExpansionToken yieldToken_
    ) {
        keeper = keeper_;
        factory = factory_;
        crvUsd = crvUsd_;
        targetAsset = targetAsset_;
        yieldToken = yieldToken_;
    }

    function expand() external {
        ++actionCalls;
        crvUsd.mint(address(keeper), MIN_EXPANSION);
        bool blocked = keeper.all_execution_paused() || keeper.expansion_paused();
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.expand, (MIN_EXPANSION)));
        _record(this.expand.selector, blocked, success);
    }

    function directBuyback(uint96 seed) external {
        ++actionCalls;
        uint256 deployed = keeper.deployed_crvusd();
        if (deployed == 0) return;
        uint256 amount = _bounded(seed, 1e18, _min(deployed, 10_000e18));
        yieldToken.mint(address(keeper), amount * 2);
        crvUsd.mint(address(this), amount);
        crvUsd.approve(address(keeper), amount);

        bool blocked = keeper.all_execution_paused() || keeper.direct_buyback_paused();
        (bool success,) = address(keeper).call(abi.encodeCall(IPegKeeperV3.buyback, (amount, 0)));
        crvUsd.approve(address(keeper), 0);
        _record(this.directBuyback.selector, blocked, success);
    }

    function contractTarget(uint96 seed) external {
        ++actionCalls;
        uint256 inventory = keeper.undeployed_backing();
        if (inventory == 0) return;
        uint256 amount = _bounded(seed, 1, _min(inventory, 100_000e6));
        bool blocked = keeper.all_execution_paused() || keeper.undeployed_contraction_paused();
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.contractUndeployedBacking, (amount)));
        _record(this.contractTarget.selector, blocked, success);
    }

    function contractYield(uint96 seed) external {
        ++actionCalls;
        uint256 inventory = keeper.accounted_yield_token_units();
        uint256 deployed = keeper.deployed_crvusd();
        uint256 maximum = _min(_min(inventory, deployed), 100_000e18);
        if (maximum == 0) return;
        uint256 amount = _bounded(seed, 1, maximum);
        bool blocked = keeper.all_execution_paused() || keeper.yield_contraction_paused();
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.contractViaAmm, (amount)));
        _record(this.contractYield.selector, blocked, success);
    }

    function deployBacking(uint96 seed) external {
        ++actionCalls;
        uint256 inventory = keeper.undeployed_backing();
        if (inventory == 0) return;
        uint256 amount = _bounded(seed, 1, _min(inventory, 100_000e6));
        bool blocked = keeper.all_execution_paused() || keeper.backing_deployment_paused();
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.deployUndeployedBacking, (amount)));
        _record(this.deployBacking.selector, blocked, success);
    }

    function unwindYield(uint96 seed) external {
        ++actionCalls;
        uint256 inventory = keeper.accounted_yield_token_units();
        if (inventory == 0) return;
        uint256 amount = _bounded(seed, 1, _min(inventory, 100_000e18));
        bool allowed = !keeper.all_execution_paused() && keeper.backing_deployment_paused()
            && !keeper.yield_contraction_paused();
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.unwindYieldToTarget, (amount)));
        _record(this.unwindYield.selector, !allowed, success);
    }

    function claimSurplus(uint96 seed) external {
        ++actionCalls;
        uint256 backingDonation = _bounded(seed, 1e6, 10_000e6);
        targetAsset.mint(address(keeper), backingDonation);
        uint256 crvUsdAmount = backingDonation * 1e12;
        crvUsd.mint(address(keeper), crvUsdAmount);
        bool blocked = keeper.all_execution_paused() || keeper.expansion_paused();
        (bool success,) =
            address(keeper).call(abi.encodeCall(IPegKeeperV3.claimSurplus, (crvUsdAmount)));
        _record(this.claimSurplus.selector, blocked, success);
    }

    function donateTarget(uint96 seed) external {
        ++actionCalls;
        targetAsset.mint(address(keeper), _bounded(seed, 1, 100_000e6));
    }

    function donateYield(uint96 seed) external {
        ++actionCalls;
        yieldToken.mint(address(keeper), _bounded(seed, 1, 100_000e18));
    }

    function setPause(uint8 rawDirection, bool paused) external {
        ++actionCalls;
        keeper.set_direction_paused(uint256(rawDirection) % 6, paused);
    }

    function advanceTime(uint32 elapsed) external {
        ++actionCalls;
        vm.warp(block.timestamp + uint256(elapsed % 7 days));
    }

    function _record(bytes4 selector, bool blocked, bool success) internal {
        if (blocked && success) ++pauseViolations;
        if (success) {
            ++successfulActions;
            ++successfulCalls[selector];
        }
    }

    function _bounded(uint256 seed, uint256 minimum, uint256 maximum)
        internal
        pure
        returns (uint256)
    {
        if (maximum <= minimum) return maximum;
        return minimum + seed % (maximum - minimum + 1);
    }

    function _min(uint256 left, uint256 right) internal pure returns (uint256) {
        return left < right ? left : right;
    }
}

contract PegKeeperV3InvariantTest is StdInvariant, Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant DAI_USDS_CONVERTER = 1;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;

    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    ExpansionToken internal crvUsd;
    ExpansionToken internal targetAsset;
    ExpansionToken internal backingAsset;
    ExpansionToken internal dai;
    ExecutionYieldToken internal yieldToken;
    ExpansionFactory internal factory;
    ExpansionPool internal targetPool;
    ExecutionRoutePool internal targetToDaiPool;
    ExecutionRoutePool internal backingToTargetPool;
    ExecutionDaiUsds internal daiUsds;
    ExpansionOracle internal targetOracle;
    ExpansionOracle internal yieldOracle;
    IPegKeeperV3 internal keeper;
    PegKeeperV3InvariantHandler internal handler;

    function setUp() public {
        crvUsd = new ExpansionToken(18);
        targetAsset = new ExpansionToken(6);
        backingAsset = new ExpansionToken(18);
        dai = new ExpansionToken(18);
        yieldToken = new ExecutionYieldToken(backingAsset);
        factory = new ExpansionFactory(address(crvUsd), address(this), emergencyAdmin, feeReceiver);
        targetPool = new ExpansionPool(crvUsd, targetAsset);
        targetToDaiPool = new ExecutionRoutePool(targetAsset, dai);
        backingToTargetPool = new ExecutionRoutePool(backingAsset, targetAsset);
        daiUsds = new ExecutionDaiUsds(dai, backingAsset);
        targetOracle = new ExpansionOracle();
        yieldOracle = new ExpansionOracle();

        keeper = PegKeeperV3TestDeployer.deploy(
            address(factory),
            address(targetPool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken),
            MAX_DEPLOYED,
            1,
            address(targetOracle),
            address(yieldOracle)
        );
        factory.setDebtCeiling(address(keeper), MAX_DEPLOYED);
        targetPool.setReversePrices(1_010_000, 1_010_000);
        keeper.setPaths(_expansionPath(), 5, _contractionPath());
        keeper.set_expansion_config(0, 1_000_000, 250_000);
        for (uint256 direction; direction < 6; ++direction) {
            keeper.set_direction_paused(direction, false);
        }

        handler = new PegKeeperV3InvariantHandler(
            keeper, factory, crvUsd, targetAsset, ExpansionToken(address(yieldToken))
        );
        factory.setGovernance(address(handler), emergencyAdmin, feeReceiver);

        _primeSuccessfulActions();

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = PegKeeperV3InvariantHandler.expand.selector;
        selectors[1] = PegKeeperV3InvariantHandler.directBuyback.selector;
        selectors[2] = PegKeeperV3InvariantHandler.contractTarget.selector;
        selectors[3] = PegKeeperV3InvariantHandler.contractYield.selector;
        selectors[4] = PegKeeperV3InvariantHandler.deployBacking.selector;
        selectors[5] = PegKeeperV3InvariantHandler.unwindYield.selector;
        selectors[6] = PegKeeperV3InvariantHandler.claimSurplus.selector;
        selectors[7] = PegKeeperV3InvariantHandler.donateTarget.selector;
        selectors[8] = PegKeeperV3InvariantHandler.donateYield.selector;
        selectors[9] = PegKeeperV3InvariantHandler.setPause.selector;
        selectors[10] = PegKeeperV3InvariantHandler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_trustedBackingAlwaysCoversDeployedExposure() public view {
        assertGe(keeper.trusted_backing_value(), keeper.deployed_crvusd());
    }

    function invariant_exposureNeverExceedsConfiguredOrFactoryCapacity() public view {
        assertLe(keeper.deployed_crvusd(), keeper.max_deployed_crvusd());
        assertLe(keeper.deployed_crvusd(), factory.debt_ceiling(address(keeper)));
    }

    function invariant_pauseGatesCannotBeBypassed() public view {
        assertEq(handler.pauseViolations(), 0);
    }

    function invariant_eachEconomicHandlerActionHasAReachableSuccessPath() public view {
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.expand.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.directBuyback.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.contractTarget.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.contractYield.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.deployBacking.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.unwindYield.selector), 0);
        assertGt(handler.successfulCalls(PegKeeperV3InvariantHandler.claimSurplus.selector), 0);
    }

    function invariant_configuredInventoryIsLiveBalanceAccounting() public view {
        assertEq(keeper.undeployed_backing(), targetAsset.balanceOf(address(keeper)));
        assertEq(keeper.accounted_yield_token_units(), yieldToken.balanceOf(address(keeper)));
    }

    function invariant_allTemporaryAllowancesReturnToZero() public view {
        address pegKeeper = address(keeper);
        assertEq(crvUsd.allowance(pegKeeper, address(targetPool)), 0);
        assertEq(targetAsset.allowance(pegKeeper, address(targetPool)), 0);
        assertEq(targetAsset.allowance(pegKeeper, address(targetToDaiPool)), 0);
        assertEq(dai.allowance(pegKeeper, address(targetToDaiPool)), 0);
        assertEq(dai.allowance(pegKeeper, address(daiUsds)), 0);
        assertEq(backingAsset.allowance(pegKeeper, address(daiUsds)), 0);
        assertEq(backingAsset.allowance(pegKeeper, address(yieldToken)), 0);
        assertEq(backingAsset.allowance(pegKeeper, address(backingToTargetPool)), 0);
        assertEq(yieldToken.allowance(pegKeeper, address(yieldToken)), 0);
    }

    function _expansionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = _curveStep(address(targetToDaiPool), address(targetAsset), address(dai), 0, 1, 3);
        path[1] = IPegKeeperV3.RouteStep({
            kind: DAI_USDS_CONVERTER,
            venue: address(daiUsds),
            tokenIn: address(dai),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 0
        });
        path[2] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 1
        });
    }

    function _contractionPath() internal view returns (IPegKeeperV3.RouteStep[] memory path) {
        path = new IPegKeeperV3.RouteStep[](3);
        path[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: address(yieldToken),
            tokenIn: address(yieldToken),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 1
        });
        path[1] = _curveStep(
            address(backingToTargetPool), address(backingAsset), address(targetAsset), 0, 1, 3
        );
        path[2] = _curveStep(address(targetPool), address(targetAsset), address(crvUsd), 0, 1, 3);
    }

    function _primeSuccessfulActions() internal {
        handler.expand();
        handler.directBuyback(1_000e18);
        handler.donateTarget(10_000e6);
        handler.contractTarget(1_000e6);
        handler.contractYield(1_000e18);
        handler.donateTarget(10_000e6);
        handler.deployBacking(1_000e6);
        handler.setPause(1, true);
        handler.unwindYield(1_000e18);
        handler.setPause(1, false);
        handler.claimSurplus(1_000e6);
    }

    function _curveStep(
        address venue,
        address tokenIn,
        address tokenOut,
        int128 indexIn,
        int128 indexOut,
        uint256 bufferBps
    ) internal pure returns (IPegKeeperV3.RouteStep memory) {
        return IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: venue,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolIndexIn: indexIn,
            poolIndexOut: indexOut,
            executionBufferBps: bufferBps
        });
    }
}
