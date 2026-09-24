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

contract PegKeeperPolicyTest is Test {
    PolicyPriceOracleMock internal oracle;
    IPegKeeperPolicy internal policy;

    function setUp() public {
        oracle = new PolicyPriceOracleMock();
        policy = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy",
                abi.encode(address(this), address(oracle), makeAddr("feeReceiver"))
            )
        );
    }

    function test_policyOnlyReportsGlobalExecutionRulingsWithoutKeeperInput() public {
        assertTrue(policy.expansion_regime());
        assertTrue(policy.can_expand());
        assertTrue(policy.can_contract());

        _assertStaticCallFails(abi.encodeWithSignature("can_expand(address)", address(this)));
        _assertStaticCallFails(abi.encodeWithSignature("can_contract(address)", address(this)));
        _assertStaticCallFails(abi.encodeWithSignature("can_allocate(address)", address(this)));
        _assertStaticCallFails(abi.encodeWithSignature("can_expand_without_policy()"));
        _assertStaticCallFails(abi.encodeWithSignature("peg_keeper_count()"));
        _assertStaticCallFails(abi.encodeWithSignature("peg_keepers(uint256)", 0));
        _assertStaticCallFails(abi.encodeWithSignature("is_active(address)", address(this)));
        _assertCallFails(abi.encodeWithSignature("add_peg_keepers(address[])", new address[](0)));
        _assertCallFails(abi.encodeWithSignature("remove_peg_keepers(address[])", new address[](0)));
        _assertStaticCallFails(
            abi.encodeWithSignature("keeper_profit_share_bps(address)", address(this))
        );
        _assertCallFails(abi.encodeWithSignature("set_keeper_profit_share_bps(uint256)", 2_000));
    }

    function test_aggregateDirectionBoundaryIsExact() public {
        oracle.setPrice(1e18 - 1);
        assertFalse(policy.expansion_regime());
        assertFalse(policy.can_expand());
        assertTrue(policy.can_contract());

        oracle.setPrice(1e18);
        assertTrue(policy.expansion_regime());
        assertTrue(policy.can_expand());
        assertTrue(policy.can_contract());

        oracle.setPrice(1e18 + 1);
        assertTrue(policy.expansion_regime());
        assertTrue(policy.can_expand());
        assertFalse(policy.can_contract());
    }

    function test_invalidAggregateOracleFailsClosed() public {
        oracle.setShouldRevert(true);
        vm.expectRevert();
        policy.can_expand();
        vm.expectRevert();
        policy.can_contract();
        vm.expectRevert();
        policy.expansion_regime();
    }

    function test_zeroAggregateOracleResponseFailsClosed() public {
        oracle.setPrice(0);
        vm.expectRevert();
        policy.can_expand();
        vm.expectRevert();
        policy.can_contract();
        vm.expectRevert();
        policy.expansion_regime();
    }

    function test_typedAggregateOracleCallUsesDeclaredPriceInterface() public {
        OversizedPolicyPriceOracle oversized = new OversizedPolicyPriceOracle();
        policy.set_aggregate_crvusd_oracle(address(oversized));

        assertTrue(policy.can_expand());
        assertTrue(policy.can_contract());
        assertTrue(policy.expansion_regime());
    }

    function test_onlyOwnerCanSetAggregateOracle() public {
        PolicyPriceOracleMock replacement = new PolicyPriceOracleMock();
        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        policy.set_aggregate_crvusd_oracle(address(replacement));

        policy.set_aggregate_crvusd_oracle(address(replacement));
        assertEq(policy.aggregateCrvUsdOracle(), address(replacement));

        vm.expectRevert(IPegKeeperPolicy.InvalidOracle.selector);
        policy.set_aggregate_crvusd_oracle(address(0));
        vm.expectRevert(IPegKeeperPolicy.InvalidOracle.selector);
        policy.set_aggregate_crvusd_oracle(makeAddr("no code"));
    }

    function test_policyOwnsGlobalFeeReceiver() public {
        address initialFeeReceiver = makeAddr("initialFeeReceiver");
        IPegKeeperPolicy receiverPolicy = IPegKeeperPolicy(
            vm.deployCode(
                "PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), initialFeeReceiver)
            )
        );

        assertEq(receiverPolicy.fee_receiver(), initialFeeReceiver);

        vm.prank(makeAddr("not owner"));
        vm.expectRevert(IPegKeeperPolicy.NotOwner.selector);
        receiverPolicy.set_fee_receiver(makeAddr("unauthorized receiver"));

        address nextFeeReceiver = makeAddr("nextFeeReceiver");
        receiverPolicy.set_fee_receiver(nextFeeReceiver);
        assertEq(receiverPolicy.fee_receiver(), nextFeeReceiver);

        vm.expectRevert(IPegKeeperPolicy.InvalidFeeReceiver.selector);
        receiverPolicy.set_fee_receiver(address(0));
    }

    function test_policyConstructorRejectsZeroFeeReceiver() public {
        vm.expectRevert();
        vm.deployCode("PegKeeperPolicy.vy", abi.encode(address(this), address(oracle), address(0)));
    }

    function test_pendingOwnershipHandoffFreezesOracleConfigurationUntilAcceptance() public {
        address nextOwner = makeAddr("nextOwner");
        address correctedOwner = makeAddr("correctedOwner");
        policy.transferOwnership(nextOwner);
        assertEq(policy.ownershipTransferNonce(), 1);

        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_aggregate_crvusd_oracle(address(oracle));
        vm.expectRevert(IPegKeeperPolicy.OwnershipHandoffPending.selector);
        policy.set_fee_receiver(makeAddr("frozen receiver"));
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
