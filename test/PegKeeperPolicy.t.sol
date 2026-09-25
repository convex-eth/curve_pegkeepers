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
    uint256 internal constant ADMIN_ACTIONS_DELAY = 3 days;

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

    function test_onlyAdminCanSetAggregateOracle() public {
        PolicyPriceOracleMock replacement = new PolicyPriceOracleMock();
        vm.prank(makeAddr("not admin"));
        vm.expectRevert();
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

        vm.prank(makeAddr("not admin"));
        vm.expectRevert();
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

    function test_curveAdminTransferKeepsCurrentAdminActiveDuringDelay() public {
        IPegKeeperPolicy authority = policy;
        address nextAdmin = makeAddr("nextAdmin");
        PolicyPriceOracleMock replacement = new PolicyPriceOracleMock();
        uint256 committedAt = block.timestamp;

        authority.commit_new_admin(nextAdmin);
        assertEq(authority.admin(), address(this));
        assertEq(authority.future_admin(), nextAdmin);
        assertEq(authority.new_admin_deadline(), committedAt + ADMIN_ACTIONS_DELAY);

        policy.set_aggregate_crvusd_oracle(address(replacement));
        assertEq(policy.aggregateCrvUsdOracle(), address(replacement));

        vm.prank(nextAdmin);
        vm.expectRevert();
        authority.apply_new_admin();
        vm.warp(authority.new_admin_deadline());
        vm.prank(makeAddr("wrongAdmin"));
        vm.expectRevert();
        authority.apply_new_admin();
        vm.prank(nextAdmin);
        authority.apply_new_admin();

        assertEq(authority.admin(), nextAdmin);
        assertEq(authority.future_admin(), nextAdmin);
        assertEq(authority.new_admin_deadline(), 0);

        vm.expectRevert();
        policy.set_fee_receiver(makeAddr("oldAdminReceiver"));
        address nextFeeReceiver = makeAddr("nextAdminReceiver");
        vm.prank(nextAdmin);
        policy.set_fee_receiver(nextFeeReceiver);
        assertEq(policy.fee_receiver(), nextFeeReceiver);
    }

    function test_curveAdminCommitCanBeOverwrittenAndLegacyOwnershipSelectorsAreAbsent() public {
        IPegKeeperPolicy authority = policy;
        address firstAdmin = makeAddr("firstAdmin");
        address correctedAdmin = makeAddr("correctedAdmin");

        authority.commit_new_admin(firstAdmin);
        uint256 firstDeadline = authority.new_admin_deadline();
        vm.warp(block.timestamp + 1 days);
        authority.commit_new_admin(correctedAdmin);
        assertEq(authority.future_admin(), correctedAdmin);
        assertGt(authority.new_admin_deadline(), firstDeadline);

        vm.expectRevert();
        authority.commit_new_admin(address(0));

        (bool transferOwnershipExists,) = address(policy)
            .call(abi.encodeWithSignature("transferOwnership(address)", correctedAdmin));
        assertFalse(transferOwnershipExists);
        (bool acceptOwnershipExists,) =
            address(policy).call(abi.encodeWithSignature("acceptOwnership(uint256)", 1));
        assertFalse(acceptOwnershipExists);
        (bool ownerGetterExists,) = address(policy).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerGetterExists);
        (bool pendingOwnerGetterExists,) =
            address(policy).staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertFalse(pendingOwnerGetterExists);
        (bool ownershipNonceGetterExists,) =
            address(policy).staticcall(abi.encodeWithSignature("ownershipTransferNonce()"));
        assertFalse(ownershipNonceGetterExists);
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
