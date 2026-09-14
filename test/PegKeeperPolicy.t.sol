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

contract PolicyFactoryMock {
    address public policy;
    mapping(address => bool) public is_active;

    function setPolicy(address newPolicy) external {
        policy = newPolicy;
    }

    function setActive(address keeper, bool active) external {
        is_active[keeper] = active;
    }
}

contract PolicyKeeperMock {
    address public immutable factory;
    bool public locallyExpandable = true;
    bool public localProbeReverts;

    constructor(address keeperFactory) {
        factory = keeperFactory;
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
    PolicyPriceOracleMock internal oracle;
    PolicyFactoryMock internal factory;
    IPegKeeperPolicy internal policy;
    PolicyKeeperMock internal preferredKeeper;
    PolicyKeeperMock internal alternativeKeeper;

    function setUp() public {
        oracle = new PolicyPriceOracleMock();
        factory = new PolicyFactoryMock();
        policy = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );
        factory.setPolicy(address(policy));
        policy.set_factory(address(factory));

        preferredKeeper = _newKeeper();
        alternativeKeeper = _newKeeper();
    }

    function test_activeKeepersHaveNoStructuralPriorityOrdering() public view {
        assertTrue(policy.can_allocate(address(preferredKeeper)));
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertTrue(policy.can_expand(address(preferredKeeper)));
        assertTrue(policy.can_expand(address(alternativeKeeper)));
    }

    function test_keeperProfitShareIsOneBoundedGlobalPolicyRule() public {
        assertEq(policy.keeper_profit_share_bps(address(preferredKeeper)), 3_000);
        assertEq(policy.keeper_profit_share_bps(address(alternativeKeeper)), 3_000);

        policy.set_keeper_profit_share_bps(1_250);
        assertEq(policy.keeper_profit_share_bps(address(preferredKeeper)), 1_250);
        assertEq(policy.keeper_profit_share_bps(address(alternativeKeeper)), 1_250);

        policy.set_keeper_profit_share_bps(0);
        assertEq(policy.keeper_profit_share_bps(address(preferredKeeper)), 0);

        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.set_keeper_profit_share_bps(2_000);

        vm.expectRevert(IPegKeeperPolicy.InvalidThreshold.selector);
        policy.set_keeper_profit_share_bps(10_001);
    }

    function test_allocationRequiresMembershipButNotCandidateLocalExpansion() public {
        alternativeKeeper.setLocallyExpandable(false);
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));

        alternativeKeeper.setLocalProbeReverts(true);
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));

        factory.setActive(address(alternativeKeeper), false);
        assertFalse(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));
    }

    function test_inactiveFactoryBoundKeeperCanContractForWindDown() public {
        factory.setActive(address(alternativeKeeper), false);
        assertFalse(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));
        assertTrue(policy.can_contract(address(alternativeKeeper)));
    }

    function test_keeperFromAnotherFactoryIsRejected() public {
        PolicyFactoryMock otherFactory = new PolicyFactoryMock();
        PolicyKeeperMock outsider = new PolicyKeeperMock(address(otherFactory));
        factory.setActive(address(outsider), true);

        assertFalse(policy.can_allocate(address(outsider)));
        assertFalse(policy.can_expand(address(outsider)));
        assertFalse(policy.can_contract(address(outsider)));
    }

    function test_aggregateDirectionGateAppliesToEveryKeeperAndContraction() public {
        oracle.setPrice(1e18 - 1);
        assertFalse(policy.can_expand(address(preferredKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));
        assertTrue(policy.can_contract(address(preferredKeeper)));

        oracle.setPrice(1e18 + 1);
        assertTrue(policy.can_expand(address(preferredKeeper)));
        assertTrue(policy.can_expand(address(alternativeKeeper)));
        assertFalse(policy.can_contract(address(preferredKeeper)));
    }

    function test_invalidAggregateOracleFailsClosed() public {
        oracle.setShouldRevert(true);
        vm.expectRevert();
        policy.can_expand(address(preferredKeeper));
        vm.expectRevert();
        policy.can_contract(address(preferredKeeper));
        vm.expectRevert();
        policy.expansion_regime();
    }

    function test_zeroAndOversizedAggregateOracleResponsesFailClosed() public {
        oracle.setPrice(0);
        vm.expectRevert();
        policy.can_expand(address(preferredKeeper));
        vm.expectRevert();
        policy.can_contract(address(preferredKeeper));
        vm.expectRevert();
        policy.expansion_regime();

        OversizedPolicyPriceOracle oversized = new OversizedPolicyPriceOracle();
        policy.set_aggregate_crvusd_oracle(address(oversized));
        vm.expectRevert();
        policy.can_expand(address(preferredKeeper));
        vm.expectRevert();
        policy.can_contract(address(preferredKeeper));
        vm.expectRevert();
        policy.expansion_regime();
    }

    function test_policyCanBindBeforeFactoryInstallsIt() public {
        PolicyFactoryMock otherFactory = new PolicyFactoryMock();
        IPegKeeperPolicy replacement = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );

        replacement.set_factory(address(otherFactory));
        assertEq(replacement.factory(), address(otherFactory));
        assertEq(otherFactory.policy(), address(0));
    }

    function test_unboundPolicyRejectsAdmission() public {
        IPegKeeperPolicy unbound = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );

        assertFalse(unbound.can_allocate(address(preferredKeeper)));
        assertFalse(unbound.can_expand(address(preferredKeeper)));
        assertFalse(unbound.can_contract(address(preferredKeeper)));
    }

    function test_onlyOwnerCanConfigurePolicy() public {
        vm.startPrank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.set_aggregate_crvusd_oracle(address(oracle));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.set_keeper_profit_share_bps(2_000);
        vm.stopPrank();
    }

    function test_pendingOwnershipHandoffFreezesPolicyUntilAcceptance() public {
        address nextOwner = makeAddr("nextOwner");
        address correctedOwner = makeAddr("correctedOwner");
        policy.transferOwnership(nextOwner);
        assertEq(policy.ownershipTransferNonce(), 1);

        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_aggregate_crvusd_oracle(address(oracle));
        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_keeper_profit_share_bps(2_000);
        policy.transferOwnership(correctedOwner);
        assertEq(policy.ownershipTransferNonce(), 2);

        vm.prank(nextOwner);
        vm.expectRevert(IPegKeeperPolicy.NotPendingOwner.selector);
        policy.acceptOwnership(1);
        vm.prank(correctedOwner);
        vm.expectRevert(IPegKeeperPolicy.InvalidOwnershipTransferNonce.selector);
        policy.acceptOwnership(1);
        vm.prank(correctedOwner);
        policy.acceptOwnership(2);
        assertEq(policy.owner(), correctedOwner);
        assertEq(policy.pendingOwner(), address(0));

        vm.prank(correctedOwner);
        policy.set_keeper_profit_share_bps(2_000);
        assertEq(policy.keeper_profit_share_bps(address(preferredKeeper)), 2_000);
    }

    function test_priorityConfigurationAndObservabilitySelectorsAreAbsent() public {
        _assertStaticCallFails(abi.encodeWithSignature("priorityUtilizationBps()"));
        _assertStaticCallFails(abi.encodeWithSignature("primary()"));
        _assertStaticCallFails(abi.encodeWithSignature("tier(address)", address(preferredKeeper)));
        _assertStaticCallFails(abi.encodeWithSignature("secondaryCount()"));
        _assertStaticCallFails(abi.encodeWithSignature("secondaryAt(uint256)", 0));
        _assertStaticCallFails(abi.encodeWithSignature("tertiaryCount()"));
        _assertStaticCallFails(abi.encodeWithSignature("tertiaryAt(uint256)", 0));
        _assertCallFails(abi.encodeWithSignature("set_priority_utilization_bps(uint256)", 8_000));
        _assertCallFails(
            abi.encodeWithSignature("set_tier(address,uint256)", address(preferredKeeper), 1)
        );
    }

    function _newKeeper() internal returns (PolicyKeeperMock keeper) {
        keeper = new PolicyKeeperMock(address(factory));
        factory.setActive(address(keeper), true);
    }

    function _assertStaticCallFails(bytes memory data) internal view {
        (bool success,) = address(policy).staticcall(data);
        assertFalse(success);
    }

    function _assertCallFails(bytes memory data) internal {
        (bool success,) = address(policy).call(data);
        assertFalse(success);
    }
}
