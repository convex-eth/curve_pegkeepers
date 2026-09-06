// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperPolicy} from "../src/interfaces/IPegKeeperPolicy.sol";

contract PolicyPriceOracleMock {
    uint256 internal currentPrice = 1e18;
    bool public shouldRevert;

    function setPrice(uint256 newPrice) external {
        currentPrice = newPrice;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function price() external view returns (uint256) {
        require(!shouldRevert, "oracle failure");
        return currentPrice;
    }
}

contract OversizedPolicyPriceOracle {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1000000000000000000)
            mstore(0x20, 1)
            return(0, 0x40)
        }
    }
}

contract PolicyControllerFactoryMock {
    mapping(address => uint256) public debt_ceiling;

    function setDebtCeiling(address keeper, uint256 ceiling) external {
        debt_ceiling[keeper] = ceiling;
    }
}

contract PolicyFactoryMock {
    address public owner;
    address public policy;
    mapping(address => bool) public is_active;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    function setPolicy(address newPolicy) external {
        policy = newPolicy;
    }

    function setActive(address keeper, bool active) external {
        is_active[keeper] = active;
    }
}

contract PolicyKeeperMock {
    address public immutable factory;
    address public immutable controller_factory;
    uint256 public max_deployed_crvusd = 100e18;
    uint256 public debt;
    bool public locallyExpandable = true;
    bool public localProbeReverts;

    constructor(address keeperFactory, address controllerFactory) {
        factory = keeperFactory;
        controller_factory = controllerFactory;
    }

    function setMaxDeployedCrvUsd(uint256 maximum) external {
        max_deployed_crvusd = maximum;
    }

    function setDebt(uint256 newDebt) external {
        debt = newDebt;
    }

    function setLocallyExpandable(bool expandable) external {
        locallyExpandable = expandable;
    }

    function setLocalProbeReverts(bool value) external {
        localProbeReverts = value;
    }

    function can_expand_without_policy() external view returns (bool) {
        require(!localProbeReverts, "local probe failure");
        return locallyExpandable;
    }
}

contract PegKeeperPolicyTest is Test {
    uint256 internal constant NONE = 0;
    uint256 internal constant PRIMARY = 1;
    uint256 internal constant SECONDARY = 2;
    uint256 internal constant TERTIARY = 3;
    uint256 internal constant EIGHTY_PERCENT = 8_000;

    PolicyPriceOracleMock internal oracle;
    PolicyControllerFactoryMock internal controllerFactory;
    PolicyFactoryMock internal factory;
    IPegKeeperPolicy internal policy;
    PolicyKeeperMock internal primary;
    PolicyKeeperMock internal secondaryOne;
    PolicyKeeperMock internal secondaryTwo;
    PolicyKeeperMock internal tertiary;

    function setUp() public {
        oracle = new PolicyPriceOracleMock();
        controllerFactory = new PolicyControllerFactoryMock();
        factory = new PolicyFactoryMock(address(this));
        policy = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), EIGHTY_PERCENT)
            )
        );
        factory.setPolicy(address(policy));
        policy.set_factory(address(factory));

        primary = _newKeeper();
        secondaryOne = _newKeeper();
        secondaryTwo = _newKeeper();
        tertiary = _newKeeper();

        policy.set_tier(address(primary), PRIMARY);
        policy.set_tier(address(secondaryOne), SECONDARY);
        policy.set_tier(address(secondaryTwo), SECONDARY);
        policy.set_tier(address(tertiary), TERTIARY);
    }

    function test_primaryCanExpandWheneverItsLocalProbePasses() public view {
        assertTrue(policy.can_expand(address(primary)));
    }

    function test_secondaryIsBlockedUntilPrimaryReachesExactEightyPercent() public {
        primary.setDebt(80e18 - 1);
        assertFalse(policy.can_expand(address(secondaryOne)));

        primary.setDebt(80e18);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_secondaryUsesTighterLocalMaximumAsUtilizationDenominator() public {
        primary.setMaxDeployedCrvUsd(50e18);
        primary.setDebt(40e18 - 1);
        assertFalse(policy.can_expand(address(secondaryOne)));

        primary.setDebt(40e18);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_secondaryUsesTighterControllerCeilingAsUtilizationDenominator() public {
        primary.setMaxDeployedCrvUsd(200e18);
        controllerFactory.setDebtCeiling(address(primary), 50e18);
        primary.setDebt(40e18 - 1);
        assertFalse(policy.can_expand(address(secondaryOne)));

        primary.setDebt(40e18);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_secondaryCanExpandWhenPrimaryIsLocallyBlocked() public {
        primary.setDebt(0);
        primary.setLocallyExpandable(false);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_allocationDoesNotRequireCandidateLocalExpansion() public {
        primary.setDebt(80e18);
        secondaryOne.setLocallyExpandable(false);

        assertTrue(policy.can_allocate(address(secondaryOne)));
        assertFalse(policy.can_expand(address(secondaryOne)));
    }

    function test_allocationStillEnforcesPriorityAndActiveMembership() public {
        primary.setDebt(80e18 - 1);
        assertFalse(policy.can_allocate(address(secondaryOne)));

        primary.setLocallyExpandable(false);
        assertTrue(policy.can_allocate(address(secondaryOne)));

        factory.setActive(address(secondaryOne), false);
        assertFalse(policy.can_allocate(address(secondaryOne)));
    }

    function test_secondaryCanExpandWhenPrimaryProbeReverts() public {
        primary.setDebt(0);
        primary.setLocalProbeReverts(true);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_secondaryCanExpandWhenPrimaryIsInactive() public {
        primary.setDebt(0);
        factory.setActive(address(primary), false);
        assertTrue(policy.can_expand(address(secondaryOne)));
    }

    function test_tertiaryRequiresPrimaryAndEveryActiveSecondaryToBeBlocked() public {
        primary.setDebt(100e18);
        assertFalse(policy.can_expand(address(tertiary)));

        primary.setLocallyExpandable(false);
        assertFalse(policy.can_expand(address(tertiary)));

        secondaryOne.setLocallyExpandable(false);
        assertFalse(policy.can_expand(address(tertiary)));

        secondaryTwo.setLocallyExpandable(false);
        assertTrue(policy.can_expand(address(tertiary)));
    }

    function test_inactiveSecondaryDoesNotBlockTertiary() public {
        primary.setLocallyExpandable(false);
        secondaryOne.setLocallyExpandable(false);
        factory.setActive(address(secondaryTwo), false);
        assertTrue(policy.can_expand(address(tertiary)));
    }

    function test_inactiveCandidateCannotExpandButCanContractForWindDown() public {
        factory.setActive(address(secondaryOne), false);
        assertFalse(policy.can_expand(address(secondaryOne)));
        assertTrue(policy.can_contract(address(secondaryOne)));
    }

    function test_aggregateDirectionGateAppliesToEveryTierAndContraction() public {
        oracle.setPrice(1e18 - 1);
        assertFalse(policy.can_expand(address(primary)));
        assertFalse(policy.can_expand(address(secondaryOne)));
        assertFalse(policy.can_expand(address(tertiary)));
        assertTrue(policy.can_contract(address(primary)));

        oracle.setPrice(1e18 + 1);
        assertFalse(policy.can_contract(address(primary)));
    }

    function test_invalidAggregateOracleFailsClosed() public {
        oracle.setShouldRevert(true);
        vm.expectRevert();
        policy.can_expand(address(primary));
        vm.expectRevert();
        policy.can_contract(address(primary));
    }

    function test_zeroAndOversizedAggregateOracleResponsesFailClosed() public {
        oracle.setPrice(0);
        vm.expectRevert();
        policy.can_expand(address(primary));
        vm.expectRevert();
        policy.can_contract(address(primary));
        vm.expectRevert();
        policy.expansion_regime();

        OversizedPolicyPriceOracle oversized = new OversizedPolicyPriceOracle();
        policy.set_aggregate_crvusd_oracle(address(oversized));
        vm.expectRevert();
        policy.can_expand(address(primary));
        vm.expectRevert();
        policy.can_contract(address(primary));
    }

    function test_secondaryCountCannotExceedTertiaryIterationBound() public {
        policy.set_tier(address(secondaryOne), NONE);
        policy.set_tier(address(secondaryTwo), NONE);

        for (uint256 i; i < 256; ++i) {
            // Safe: 0x1000 + i is at most 0x10ff.
            // forge-lint: disable-next-line(unsafe-typecast)
            address keeper = address(uint160(0x1000 + i));
            vm.etch(keeper, hex"00");
            vm.mockCall(keeper, abi.encodeWithSignature("factory()"), abi.encode(address(factory)));
            factory.setActive(keeper, true);
            policy.set_tier(keeper, SECONDARY);
        }
        assertEq(policy.secondaryCount(), 256);

        address overflowKeeper = address(0x2000);
        vm.etch(overflowKeeper, hex"00");
        vm.mockCall(
            overflowKeeper, abi.encodeWithSignature("factory()"), abi.encode(address(factory))
        );
        factory.setActive(overflowKeeper, true);
        vm.expectRevert(bytes4(keccak256("TooManySecondaries()")));
        policy.set_tier(overflowKeeper, SECONDARY);
    }

    function test_tierListsUsePopAndSwapWithoutLeavingStaleMembership() public {
        assertEq(policy.secondaryCount(), 2);
        policy.set_tier(address(secondaryOne), TERTIARY);

        assertEq(policy.tier(address(secondaryOne)), TERTIARY);
        assertEq(policy.secondaryCount(), 1);
        assertEq(policy.secondaryAt(0), address(secondaryTwo));
        assertEq(policy.tertiaryCount(), 2);
        assertTrue(
            policy.tertiaryAt(0) == address(tertiary) || policy.tertiaryAt(1) == address(tertiary)
        );
        assertTrue(
            policy.tertiaryAt(0) == address(secondaryOne)
                || policy.tertiaryAt(1) == address(secondaryOne)
        );

        policy.set_tier(address(secondaryOne), NONE);
        assertEq(policy.tier(address(secondaryOne)), NONE);
        assertEq(policy.tertiaryCount(), 1);
        assertEq(policy.tertiaryAt(0), address(tertiary));
    }

    function test_replacingPrimaryClearsOldPrimaryTier() public {
        policy.set_tier(address(secondaryOne), PRIMARY);

        assertEq(policy.primary(), address(secondaryOne));
        assertEq(policy.tier(address(secondaryOne)), PRIMARY);
        assertEq(policy.tier(address(primary)), NONE);
        assertEq(policy.secondaryCount(), 1);
        assertEq(policy.secondaryAt(0), address(secondaryTwo));
    }

    function test_policyCanBindBeforeFactoryInstallsIt() public {
        PolicyFactoryMock otherFactory = new PolicyFactoryMock(address(this));
        IPegKeeperPolicy replacement = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), EIGHTY_PERCENT)
            )
        );

        replacement.set_factory(address(otherFactory));
        assertEq(replacement.factory(), address(otherFactory));
        assertEq(otherFactory.policy(), address(0));
    }

    function test_onlyOwnerCanConfigurePolicy() public {
        vm.startPrank(makeAddr("not owner"));
        vm.expectRevert();
        policy.set_tier(address(primary), NONE);
        vm.expectRevert();
        policy.set_primary_utilization_bps(7_500);
        vm.expectRevert();
        policy.set_aggregate_crvusd_oracle(address(oracle));
        vm.stopPrank();
    }

    function _newKeeper() internal returns (PolicyKeeperMock keeper) {
        keeper = new PolicyKeeperMock(address(factory), address(controllerFactory));
        factory.setActive(address(keeper), true);
        controllerFactory.setDebtCeiling(address(keeper), 100e18);
    }
}
