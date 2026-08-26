// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IControllerFactory} from "../src/interfaces/IControllerFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUSDT} from "../src/interfaces/IUSDT.sol";
import {IPegKeeperOffboarding} from "../src/interfaces/IPegKeeperOffboarding.sol";
import {IPegKeeperRegulator} from "../src/interfaces/IPegKeeperRegulator.sol";
import {IPegKeeperV2} from "../src/interfaces/IPegKeeperV2.sol";
import {IStableSwap2Pool} from "../src/interfaces/IStableSwap2Pool.sol";

contract FixedPriceAggregator {
    uint256 public immutable price;

    constructor(uint256 price_) {
        price = price_;
    }

    function price_w() external view returns (uint256) {
        return price;
    }
}

contract PegKeeperLifecycleTest is Test {
    uint256 internal constant FORK_BLOCK = 25_837_866;
    string internal constant DEFAULT_RPC_URL = "https://mainnet.gateway.tenderly.co";

    address internal constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDT_POOL = 0x390f3595bCa2Df7d23783dFd126427CCeb997BF4;

    address internal constant FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant FACTORY_ADMIN = 0xb7400D2EA0f6DC1d7b153aA430B9E572F28afB79;
    address internal constant REGULATOR = 0x36a04CAffc681fa179558B2Aaba30395CDdd855f;
    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant EMERGENCY_ADMIN = 0x467947EE34aF926cF1DCac093870f613C96B1E0c;

    address internal constant USDC_PEG_KEEPER = 0x9201da0D97CaAAff53f01B2fB56767C7072dE340;
    address internal constant USDT_PEG_KEEPER = 0xFb726F57d251aB5C731E5C64eD4F5F94351eF9F3;
    address internal constant PYUSD_PEG_KEEPER = 0x3fA20eAa107DE08B38a8734063D605d5842fe09C;
    address internal constant FRXUSD_PEG_KEEPER = 0x338Cb2D827112d989A861cDe87CD9FfD913A1f9D;
    address internal constant GHO_PEG_KEEPER = 0x53876B157DeCf04389eEd66c7C29d73863f8C50b;

    uint256 internal constant REPLACEMENT_DEBT_CEILING = 40_000_000e18;
    uint256 internal constant CALLER_SHARE = 20_000; // 20%, with 1e5 precision.

    IControllerFactory internal constant factory = IControllerFactory(FACTORY);
    IPegKeeperRegulator internal constant regulator = IPegKeeperRegulator(REGULATOR);
    IStableSwap2Pool internal constant usdtPool = IStableSwap2Pool(USDT_POOL);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", DEFAULT_RPC_URL), FORK_BLOCK);

        assertEq(factory.admin(), FACTORY_ADMIN, "unexpected Factory admin");
        assertEq(regulator.admin(), OWNERSHIP_AGENT, "unexpected Regulator admin");
        assertEq(usdtPool.coins(0), USDT, "USDT must be coin 0");
        assertEq(usdtPool.coins(1), CRVUSD, "crvUSD must be coin 1");
    }

    function test_retireAllCurrentPegKeepers() public {
        IPegKeeperOffboarding offboarding = _retireCurrentPegKeepers();
        address[] memory pegKeepers = _currentPegKeepers();

        for (uint256 i; i < pegKeepers.length; ++i) {
            address pegKeeper = pegKeepers[i];

            assertEq(IPegKeeperV2(pegKeeper).regulator(), address(offboarding));
            assertEq(factory.debt_ceiling(pegKeeper), 0);
            assertEq(
                factory.debt_ceiling_residual(pegKeeper),
                IPegKeeperV2(pegKeeper).debt(),
                "residual allocation should equal debt still deployed in the pool"
            );
            assertEq(IERC20(CRVUSD).balanceOf(pegKeeper), 0, "idle crvUSD should be burned");
            assertEq(offboarding.provide_allowed(pegKeeper), 0);
            assertEq(offboarding.withdraw_allowed(pegKeeper), type(uint256).max);
        }

        assertGt(
            factory.debt_ceiling_residual(USDT_PEG_KEEPER),
            0,
            "USDT PegKeeper should retain residual debt to unwind"
        );
    }

    function test_deployReplacementUsdtPegKeeperAndAdjustAfterCrvUsdPurchase() public {
        _retireCurrentPegKeepers();

        // Keep the old USDT PegKeeper in the live regulator as a read-only debt/price reference while
        // it winds down under the offboarding regulator. It can no longer provide, but its residual
        // pool debt prevents the replacement from being artificially constrained to the 25% bootstrap
        // ratio. Curve's regulator permits the replacement to be registered alongside it.
        IPegKeeperV2 replacement = IPegKeeperV2(
            _deployVyper(
                "out/PegKeeperV2.vy/PegKeeperV2.json",
                abi.encode(USDT_POOL, CALLER_SHARE, FACTORY, REGULATOR, OWNERSHIP_AGENT)
            )
        );

        address[] memory onePegKeeper = new address[](1);
        onePegKeeper[0] = address(replacement);
        vm.prank(OWNERSHIP_AGENT);
        regulator.add_peg_keepers(onePegKeeper);

        vm.prank(FACTORY_ADMIN);
        factory.set_debt_ceiling(address(replacement), REPLACEMENT_DEBT_CEILING);

        assertEq(replacement.pool(), USDT_POOL);
        assertEq(replacement.pegged(), CRVUSD);
        assertEq(replacement.factory(), FACTORY);
        assertEq(replacement.regulator(), REGULATOR);
        assertEq(replacement.caller_share(), CALLER_SHARE);
        assertEq(IERC20(CRVUSD).balanceOf(address(replacement)), REPLACEMENT_DEBT_CEILING);

        // Keep the real regulator and pool. Only make the system-wide price gate deterministic
        // and relax same-block EMA protections so this test isolates PegKeeper mechanics.
        FixedPriceAggregator fixedAggregator = new FixedPriceAggregator(1.001e18);
        vm.startPrank(OWNERSHIP_AGENT);
        regulator.set_aggregator(address(fixedAggregator));
        regulator.set_price_deviation(1e20);
        regulator.set_worst_price_threshold(1e16);
        vm.stopPrank();

        uint256 purchaseAmount = 10_000_000e6;
        deal(USDT, address(this), purchaseAmount);
        IUSDT(USDT).approve(USDT_POOL, purchaseAmount);

        uint256 crvUsdBefore = IERC20(CRVUSD).balanceOf(address(this));
        uint256 crvUsdBought = usdtPool.exchange(0, 1, purchaseAmount, 0);
        assertGt(crvUsdBought, 0);
        assertEq(IERC20(CRVUSD).balanceOf(address(this)) - crvUsdBefore, crvUsdBought);

        uint256 imbalance = _provideImbalance();
        assertGt(imbalance, 0, "purchase should make crvUSD scarce in the pool");

        uint256 debt;
        uint256 totalReward;
        for (uint256 i; i < 3; ++i) {
            vm.prank(address(replacement));
            uint256 allowed = regulator.provide_allowed();
            assertGt(allowed, 0, "live regulator should permit the simulated provision");
            assertGt(
                replacement.estimate_caller_profit(),
                0,
                "simulated adjustment should be profitable before update"
            );

            uint256 reward = replacement.update(address(this));
            totalReward += reward;

            assertGt(replacement.debt(), debt, "each adjustment should provide more crvUSD");
            assertLt(_provideImbalance(), imbalance, "each adjustment should reduce imbalance");
            assertGt(reward, 0, "keeper should earn incremental LP profit");

            debt = replacement.debt();
            imbalance = _provideImbalance();
            vm.warp(block.timestamp + replacement.action_delay() + 1);
            vm.roll(block.number + 1);
        }

        assertGt(debt, 0);
        assertGt(totalReward, 0);
        assertGt(usdtPool.balanceOf(address(this)), 0, "caller reward is paid in pool LP tokens");
        assertLt(IERC20(CRVUSD).balanceOf(address(replacement)), REPLACEMENT_DEBT_CEILING);
    }

    function _retireCurrentPegKeepers() internal returns (IPegKeeperOffboarding offboarding) {
        offboarding = IPegKeeperOffboarding(
            _deployVyper(
                "out/PegKeeperOffboarding.vy/PegKeeperOffboarding.json",
                abi.encode(regulator.fee_receiver(), OWNERSHIP_AGENT, EMERGENCY_ADMIN)
            )
        );

        address[] memory pegKeepers = _currentPegKeepers();
        vm.prank(OWNERSHIP_AGENT);
        offboarding.add_peg_keepers(pegKeepers);

        vm.startPrank(OWNERSHIP_AGENT);
        for (uint256 i; i < pegKeepers.length; ++i) {
            IPegKeeperV2(pegKeepers[i]).set_new_regulator(address(offboarding));
        }
        vm.stopPrank();

        vm.startPrank(FACTORY_ADMIN);
        for (uint256 i; i < pegKeepers.length; ++i) {
            factory.set_debt_ceiling(pegKeepers[i], 0);
        }
        vm.stopPrank();
    }

    function _provideImbalance() internal view returns (uint256) {
        uint256 normalizedUsdt = usdtPool.balances(0) * 1e12;
        uint256 crvUsdBalance = usdtPool.balances(1);
        return normalizedUsdt > crvUsdBalance ? normalizedUsdt - crvUsdBalance : 0;
    }

    function _deployVyper(string memory artifact, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        bytes memory creationCode = vm.getCode(artifact);
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);

        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "Vyper deployment failed");
    }

    function _currentPegKeepers() internal pure returns (address[] memory pegKeepers) {
        pegKeepers = new address[](5);
        pegKeepers[0] = USDC_PEG_KEEPER;
        pegKeepers[1] = USDT_PEG_KEEPER;
        pegKeepers[2] = PYUSD_PEG_KEEPER;
        pegKeepers[3] = FRXUSD_PEG_KEEPER;
        pegKeepers[4] = GHO_PEG_KEEPER;
    }
}
