// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface IControllerFactoryRegistrationProbe {
    function controllers(uint256 index) external view returns (address);
    function n_collaterals() external view returns (uint256);
}

interface IControllerPolicyProbe {
    function monetary_policy() external view returns (address);
}

interface IAggMonetaryPolicyCurrentProbe {
    function peg_keepers(uint256 index) external view returns (address);
    function add_peg_keeper(address keeper) external;
    function remove_peg_keeper(address keeper) external;
}

interface IAggMonetaryPolicyLegacyProbe {
    function peg_keepers(uint256 index) external view returns (address);
    function add_peg_keeper(address keeper) external;
    function remove_peg_keeper(address keeper) external;
    function rate() external view returns (uint256);
    function rate_write() external returns (uint256);
}

interface IAggregateStablePriceProbe {
    function price_pairs(uint256 index) external view returns (address pool, bool isInverse);
    function remove_price_pair(uint256 index) external;
}

interface IDebtReporter {
    function debt() external view returns (uint256);
}

contract ZeroDebtReporter {
    function debt() external pure returns (uint256) {
        return 0;
    }
}

contract CurvePegKeeperRegistrationSafetyTest is Test {
    uint256 internal constant FORK_BLOCK = 25_922_189;
    string internal constant DEFAULT_RPC_URL = "https://mainnet.gateway.tenderly.co";

    address internal constant OWNERSHIP_AGENT = 0x40907540d8a6C65c637785e8f8B742ae6b0b9968;
    address internal constant CONTROLLER_FACTORY = 0xC9332fdCB1C491Dcc683bAe86Fe3cb70360738BC;
    address internal constant MONETARY_POLICY = 0x07491D124ddB3Ef59a8938fCB3EE50F9FA0b9251;
    address internal constant LEGACY_MONETARY_POLICY = 0xc684432FD6322c6D58b6bC5d28B18569aA0AD0A1;
    address internal constant AGGREGATE_ORACLE = 0x18672b1b0c623a30089A280Ed9256379fb0E4E62;

    address internal constant OLD_USDC_KEEPER = 0x9201da0D97CaAAff53f01B2fB56767C7072dE340;
    address internal constant OLD_USDT_KEEPER = 0xFb726F57d251aB5C731E5C64eD4F5F94351eF9F3;
    address internal constant OLD_PYUSD_KEEPER = 0x3fA20eAa107DE08B38a8734063D605d5842fe09C;
    address internal constant OLD_FRXUSD_KEEPER = 0x338Cb2D827112d989A861cDe87CD9FfD913A1f9D;
    address internal constant OLD_GHO_KEEPER = 0x53876B157DeCf04389eEd66c7C29d73863f8C50b;
    address internal constant OLD_PYUSD_ORACLE_POOL = 0x095340538cF380A3C30B5B547d1992c6B24EE2e0;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", DEFAULT_RPC_URL), FORK_BLOCK);
    }

    function test_liveControllersRequireBothAggregatePolicyRegistrations() public view {
        IControllerFactoryRegistrationProbe controllerFactory =
            IControllerFactoryRegistrationProbe(CONTROLLER_FACTORY);
        uint256 controllerCount = controllerFactory.n_collaterals();
        assertGt(controllerCount, 1);

        assertEq(
            IControllerPolicyProbe(controllerFactory.controllers(0)).monetary_policy(),
            LEGACY_MONETARY_POLICY
        );
        for (uint256 i = 1; i < controllerCount; ++i) {
            assertEq(
                IControllerPolicyProbe(controllerFactory.controllers(i)).monetary_policy(),
                MONETARY_POLICY
            );
        }
    }

    function test_zeroDebtRegistrationAppendsToBothAndPreservesLegacyRate() public {
        IControllerFactoryRegistrationProbe controllerFactory =
            IControllerFactoryRegistrationProbe(CONTROLLER_FACTORY);
        address legacyController = controllerFactory.controllers(0);

        IAggMonetaryPolicyCurrentProbe currentPolicy =
            IAggMonetaryPolicyCurrentProbe(MONETARY_POLICY);
        IAggMonetaryPolicyLegacyProbe legacyPolicy =
            IAggMonetaryPolicyLegacyProbe(LEGACY_MONETARY_POLICY);

        vm.prank(legacyController);
        uint256 legacyRateBefore = legacyPolicy.rate();

        ZeroDebtReporter keeper = new ZeroDebtReporter();
        vm.startPrank(OWNERSHIP_AGENT);
        currentPolicy.add_peg_keeper(address(keeper));
        legacyPolicy.add_peg_keeper(address(keeper));
        vm.stopPrank();

        assertEq(currentPolicy.peg_keepers(5), address(keeper));
        assertEq(legacyPolicy.peg_keepers(4), address(keeper));
        assertEq(keeper.debt(), 0);
        vm.prank(legacyController);
        assertEq(legacyPolicy.rate(), legacyRateBefore);
        vm.prank(legacyController);
        assertGt(legacyPolicy.rate_write(), 0);
    }

    function test_removingIndebtedKeeperChangesLegacyRateAccounting() public {
        address legacyController =
            IControllerFactoryRegistrationProbe(CONTROLLER_FACTORY).controllers(0);
        IAggMonetaryPolicyLegacyProbe legacyPolicy =
            IAggMonetaryPolicyLegacyProbe(LEGACY_MONETARY_POLICY);
        assertGt(IDebtReporter(OLD_USDC_KEEPER).debt(), 0);

        vm.prank(legacyController);
        uint256 rateBefore = legacyPolicy.rate();
        vm.prank(OWNERSHIP_AGENT);
        legacyPolicy.remove_peg_keeper(OLD_USDC_KEEPER);
        vm.prank(legacyController);
        uint256 rateAfter = legacyPolicy.rate();

        assertGt(rateAfter, rateBefore);
    }

    function test_monetaryPolicyRemovalByAddressKeepsListContiguous() public {
        IAggMonetaryPolicyCurrentProbe policy = IAggMonetaryPolicyCurrentProbe(MONETARY_POLICY);

        vm.startPrank(OWNERSHIP_AGENT);
        policy.remove_peg_keeper(OLD_USDC_KEEPER);
        policy.remove_peg_keeper(OLD_USDT_KEEPER);
        vm.stopPrank();

        assertEq(policy.peg_keepers(0), OLD_GHO_KEEPER);
        assertEq(policy.peg_keepers(1), OLD_FRXUSD_KEEPER);
        assertEq(policy.peg_keepers(2), OLD_PYUSD_KEEPER);
        assertEq(policy.peg_keepers(3), address(0));
    }

    function test_aggregateOracleAscendingSnapshotIndicesRevert() public {
        IAggregateStablePriceProbe oracle = IAggregateStablePriceProbe(AGGREGATE_ORACLE);

        vm.startPrank(OWNERSHIP_AGENT);
        oracle.remove_price_pair(2);
        vm.expectRevert();
        oracle.remove_price_pair(3);
        vm.stopPrank();
    }

    function test_aggregateOracleDescendingSnapshotIndicesSucceedButGetterRemainsStale() public {
        IAggregateStablePriceProbe oracle = IAggregateStablePriceProbe(AGGREGATE_ORACLE);

        vm.startPrank(OWNERSHIP_AGENT);
        oracle.remove_price_pair(3);
        oracle.remove_price_pair(2);
        vm.expectRevert();
        oracle.remove_price_pair(2);
        vm.stopPrank();

        (address stalePool,) = oracle.price_pairs(2);
        assertEq(stalePool, OLD_PYUSD_ORACLE_POOL);
    }
}
