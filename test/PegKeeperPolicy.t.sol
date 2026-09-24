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

contract PolicyKeeperMock {
    address public policy;
    bool public locallyExpandable = true;
    bool public localProbeReverts;

    constructor(address keeperPolicy) {
        policy = keeperPolicy;
    }

    function setPolicy(address newPolicy) external {
        policy = newPolicy;
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
    IPegKeeperPolicy internal policy;
    PolicyKeeperMock internal preferredKeeper;
    PolicyKeeperMock internal alternativeKeeper;

    function setUp() public {
        oracle = new PolicyPriceOracleMock();
        policy = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );

        preferredKeeper = _newKeeper(address(policy));
        alternativeKeeper = _newKeeper(address(policy));
        address[] memory keepers = new address[](2);
        keepers[0] = address(preferredKeeper);
        keepers[1] = address(alternativeKeeper);
        policy.add_peg_keepers(keepers);
    }

    function test_boundKeepersHaveNoStructuralPriorityOrdering() public view {
        assertTrue(policy.can_allocate(address(preferredKeeper)));
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertTrue(policy.can_expand(address(preferredKeeper)));
        assertTrue(policy.can_expand(address(alternativeKeeper)));
    }

    function test_policyUsesKeeperBindingWithoutFactoryRegistry() public view {
        (bool factoryGetterExists,) =
            address(policy).staticcall(abi.encodeWithSignature("factory()"));
        assertFalse(factoryGetterExists);
        assertTrue(policy.can_allocate(address(preferredKeeper)));
        assertTrue(policy.can_expand(address(preferredKeeper)));
    }

    function test_policyActiveListUsesPopAndSwapAndSupportsReadding() public {
        IPegKeeperPolicy freshPolicy = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );
        PolicyKeeperMock first = _newKeeper(address(freshPolicy));
        PolicyKeeperMock second = _newKeeper(address(freshPolicy));
        assertEq(freshPolicy.peg_keeper_count(), 0);

        address[] memory keepers = new address[](2);
        keepers[0] = address(first);
        keepers[1] = address(second);
        freshPolicy.add_peg_keepers(keepers);

        assertEq(freshPolicy.peg_keeper_count(), 2);
        assertEq(freshPolicy.peg_keepers(0), address(first));
        assertEq(freshPolicy.peg_keepers(1), address(second));
        assertTrue(freshPolicy.is_active(address(first)));
        assertTrue(freshPolicy.is_active(address(second)));

        address[] memory removed = new address[](1);
        removed[0] = address(first);
        freshPolicy.remove_peg_keepers(removed);

        assertEq(freshPolicy.peg_keeper_count(), 1);
        assertEq(freshPolicy.peg_keepers(0), address(second));
        assertFalse(freshPolicy.is_active(address(first)));
        assertTrue(freshPolicy.is_active(address(second)));
        assertFalse(freshPolicy.can_allocate(address(first)));
        assertFalse(freshPolicy.can_expand(address(first)));
        assertTrue(freshPolicy.can_contract(address(first)));

        freshPolicy.add_peg_keepers(removed);
        assertEq(freshPolicy.peg_keeper_count(), 2);
        assertEq(freshPolicy.peg_keepers(1), address(first));
        assertTrue(freshPolicy.is_active(address(first)));
    }

    function test_policyListRejectsDuplicateMissingAndWrongBinding() public {
        address[] memory oneKeeper = new address[](1);
        oneKeeper[0] = address(preferredKeeper);
        vm.expectRevert(IPegKeeperPolicy.DuplicateKeeper.selector);
        policy.add_peg_keepers(oneKeeper);

        PolicyKeeperMock missing = _newKeeper(address(policy));
        oneKeeper[0] = address(missing);
        vm.expectRevert(IPegKeeperPolicy.InvalidKeeper.selector);
        policy.remove_peg_keepers(oneKeeper);

        PolicyKeeperMock wrongBinding = _newKeeper(makeAddr("another policy"));
        oneKeeper[0] = address(wrongBinding);
        vm.expectRevert(IPegKeeperPolicy.InvalidKeeper.selector);
        policy.add_peg_keepers(oneKeeper);
    }

    function test_onlyOwnerCanAddAndRemovePolicyKeepers() public {
        PolicyKeeperMock candidate = _newKeeper(address(policy));
        address[] memory oneKeeper = new address[](1);
        oneKeeper[0] = address(candidate);

        vm.startPrank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.add_peg_keepers(oneKeeper);
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.remove_peg_keepers(oneKeeper);
        vm.stopPrank();
    }

    function test_policyListIsBoundedToEightAndNinthAdditionRollsBack() public {
        IPegKeeperPolicy freshPolicy = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );
        address[] memory keepers = new address[](8);
        for (uint256 i; i < keepers.length; ++i) {
            keepers[i] = address(_newKeeper(address(freshPolicy)));
        }
        freshPolicy.add_peg_keepers(keepers);
        assertEq(freshPolicy.peg_keeper_count(), 8);

        address ninth = address(_newKeeper(address(freshPolicy)));
        address[] memory oneKeeper = new address[](1);
        oneKeeper[0] = ninth;
        vm.expectRevert();
        freshPolicy.add_peg_keepers(oneKeeper);

        assertEq(freshPolicy.peg_keeper_count(), 8);
        assertFalse(freshPolicy.is_active(ninth));
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

    function test_allocationRequiresBindingButNotCandidateLocalExpansion() public {
        alternativeKeeper.setLocallyExpandable(false);
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));

        alternativeKeeper.setLocalProbeReverts(true);
        assertTrue(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));

        alternativeKeeper.setPolicy(makeAddr("other policy"));
        assertFalse(policy.can_allocate(address(alternativeKeeper)));
        assertFalse(policy.can_expand(address(alternativeKeeper)));
        assertFalse(policy.can_contract(address(alternativeKeeper)));
    }

    function test_keeperBoundToAnotherPolicyIsRejected() public {
        IPegKeeperPolicy otherPolicy = IPegKeeperPolicy(
            vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), 3_000))
        );
        PolicyKeeperMock outsider = _newKeeper(address(otherPolicy));

        assertFalse(policy.can_allocate(address(outsider)));
        assertFalse(policy.can_expand(address(outsider)));
        assertFalse(policy.can_contract(address(outsider)));
    }

    function test_nonContractAndMalformedKeepersAreRejected() public {
        assertFalse(policy.can_allocate(address(0)));
        assertFalse(policy.can_allocate(makeAddr("no code")));
        assertFalse(policy.can_allocate(address(oracle)));
        assertFalse(policy.can_expand(address(oracle)));
        assertFalse(policy.can_contract(address(oracle)));
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

    function test_factoryAndPrioritySelectorsAreAbsent() public {
        _assertStaticCallFails(abi.encodeWithSignature("factory()"));
        _assertStaticCallFails(abi.encodeWithSignature("activePegKeeperCount()"));
        _assertStaticCallFails(abi.encodeWithSignature("activePegKeeperAt(uint256)", 0));
        _assertCallFails(abi.encodeWithSignature("set_factory(address)", makeAddr("factory")));
        _assertCallFails(
            abi.encodeWithSignature("set_active(address,bool)", address(preferredKeeper), true)
        );
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

    function _newKeeper(address keeperPolicy) internal returns (PolicyKeeperMock keeper) {
        keeper = new PolicyKeeperMock(keeperPolicy);
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
