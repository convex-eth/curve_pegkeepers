// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";

contract MockToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract MockYieldToken is MockToken {
    address public immutable asset;
    uint256 public assetsPerShare = 1e18;

    constructor(address asset_) MockToken(18) {
        asset = asset_;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares * assetsPerShare / 1e18;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets * 1e18 / assetsPerShare;
    }
}

contract MockIncompleteYieldToken is MockToken {
    address public immutable asset;

    constructor(address asset_) MockToken(18) {
        asset = asset_;
    }
}

contract MockFactory {
    address public immutable stablecoin;
    address public immutable admin;
    mapping(address => uint256) public debt_ceiling;

    constructor(address stablecoin_, address admin_) {
        stablecoin = stablecoin_;
        admin = admin_;
    }
}

contract MockTwoCoinPool {
    address[2] internal _coins;

    constructor(address coin0, address coin1) {
        _coins = [coin0, coin1];
    }

    function coins(uint256 index) external view returns (address) {
        return _coins[index];
    }
}

contract MockCallTarget {
    uint256 public value;
    uint256 public receivedValue;
    uint256 public dataLength;

    function setValue(uint256 value_) external returns (uint256) {
        value = value_;
        return value_ + 1;
    }

    function fail() external pure {
        revert("target failure");
    }

    function setValuePayable(uint256 value_) external payable {
        value = value_;
        receivedValue += msg.value;
    }

    function returnBytes(uint256 length) external pure returns (bytes memory result) {
        result = new bytes(length);
    }

    fallback() external payable {
        receivedValue += msg.value;
        dataLength = msg.data.length;
    }

    receive() external payable {
        receivedValue += msg.value;
    }
}

contract PegKeeperV3FoundationTest is Test {
    uint256 internal constant MAX_DEPLOYED = 25_000_000e18;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");

    MockToken internal crvUsd;
    MockToken internal targetAsset;
    MockToken internal backingAsset;
    MockYieldToken internal yieldToken;
    MockFactory internal factory;
    MockTwoCoinPool internal targetAmm;

    function setUp() public {
        crvUsd = new MockToken(18);
        targetAsset = new MockToken(6);
        backingAsset = new MockToken(18);
        yieldToken = new MockYieldToken(address(backingAsset));
        factory = new MockFactory(address(crvUsd), governance);
        targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));
    }

    function test_constructorPinsEndpointsAndStartsExecutionPaused() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );

        assertEq(pegKeeper.factory(), address(factory));
        assertEq(pegKeeper.crv_usd(), address(crvUsd));
        assertEq(pegKeeper.target_amm(), address(targetAmm));
        assertEq(pegKeeper.target_asset(), address(targetAsset));
        assertEq(pegKeeper.backing_asset(), address(backingAsset));
        assertEq(pegKeeper.yield_token(), address(yieldToken));
        assertEq(pegKeeper.fee_receiver(), feeReceiver);
        assertEq(pegKeeper.admin(), governance);
        assertEq(pegKeeper.emergency_admin(), emergencyAdmin);
        assertEq(pegKeeper.target_amm_crvusd_index(), 1);
        assertEq(pegKeeper.target_amm_target_index(), 0);

        assertEq(pegKeeper.coins(0), address(crvUsd));
        assertEq(pegKeeper.coins(1), address(yieldToken));
        vm.expectRevert();
        pegKeeper.coins(2);

        uint256 entryMinProfitPpm = pegKeeper.entry_min_profit_ppm();
        assertEq(entryMinProfitPpm, 10);
        assertEq(pegKeeper.normal_exit_min_profit_ppm(), 1_000);
        assertEq(pegKeeper.early_exit_min_profit_ppm(), 5_000);
        assertEq(pegKeeper.keeper_profit_share_bps(), 3_000);
        assertEq(pegKeeper.min_deployment_time(), 2 days);
        assertEq(pegKeeper.min_expansion_amount(), 10_000e18);
        assertEq(pegKeeper.max_deployed_crvusd(), MAX_DEPLOYED);

        assertTrue(pegKeeper.expansion_paused());
        assertTrue(pegKeeper.backing_deployment_paused());
        assertTrue(pegKeeper.direct_buyback_paused());
        assertTrue(pegKeeper.undeployed_contraction_paused());
        assertTrue(pegKeeper.yield_contraction_paused());
        assertTrue(pegKeeper.all_execution_paused());
    }

    function test_constructorRejectsPoolWithoutExactCrvUsdTargetPair() public {
        MockTwoCoinPool wrongPool = new MockTwoCoinPool(address(targetAsset), address(backingAsset));
        vm.expectRevert();
        _deploy(
            address(wrongPool), address(targetAsset), address(backingAsset), address(yieldToken)
        );
    }

    function test_constructorDiscoversCrvUsdFirstPoolOrder() public {
        MockTwoCoinPool crvUsdFirstPool = new MockTwoCoinPool(address(crvUsd), address(targetAsset));
        IPegKeeperV3 pegKeeper = _deploy(
            address(crvUsdFirstPool),
            address(targetAsset),
            address(backingAsset),
            address(yieldToken)
        );

        assertEq(pegKeeper.target_amm_crvusd_index(), 0);
        assertEq(pegKeeper.target_amm_target_index(), 1);
    }

    function test_constructorRejectsYieldAssetMismatch() public {
        MockYieldToken wrongYield = new MockYieldToken(address(targetAsset));
        vm.expectRevert();
        _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(wrongYield)
        );
    }

    function test_constructorRejectsYieldTokenWithoutConversionAccounting() public {
        MockIncompleteYieldToken incompleteYield =
            new MockIncompleteYieldToken(address(backingAsset));

        vm.expectRevert();
        _deploy(
            address(targetAmm),
            address(targetAsset),
            address(backingAsset),
            address(incompleteYield)
        );
    }

    function test_constructorRejectsNon18DecimalCrvUsd() public {
        crvUsd = new MockToken(6);
        factory = new MockFactory(address(crvUsd), governance);
        targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));

        vm.expectRevert();
        _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
    }

    function test_constructorRejectsOverlappingAdminRoles() public {
        emergencyAdmin = governance;

        vm.expectRevert();
        _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
    }

    function test_constructorRejectsTargetDecimalsAbove18() public {
        targetAsset = new MockToken(19);
        targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));

        vm.expectRevert();
        _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
    }

    function test_constructorRejectsBackingDecimalsAbove18() public {
        backingAsset = new MockToken(19);
        yieldToken = new MockYieldToken(address(backingAsset));

        vm.expectRevert();
        _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
    }

    function test_unsolicitedBackingTokensDoNotEnterAccounting() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );

        targetAsset.mint(address(pegKeeper), 1_000_000e6);
        yieldToken.mint(address(pegKeeper), 2_000_000e18);

        assertEq(pegKeeper.undeployed_backing(), 0);
        assertEq(pegKeeper.accounted_yield_token_units(), 0);
        assertEq(pegKeeper.deployed_crvusd(), 0);
        assertEq(pegKeeper.trusted_backing_value(), 0);
        assertEq(pegKeeper.protocol_surplus(), 0);
    }

    function test_emergencyAdminCanPauseButCannotUnpause() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.DirectionPaused(2, false);
        vm.prank(governance);
        pegKeeper.set_direction_paused(2, false);
        assertFalse(pegKeeper.direct_buyback_paused());

        vm.expectEmit(true, false, false, true, address(pegKeeper));
        emit IPegKeeperV3.DirectionPaused(2, true);
        vm.prank(emergencyAdmin);
        pegKeeper.set_direction_paused(2, true);
        assertTrue(pegKeeper.direct_buyback_paused());

        vm.prank(emergencyAdmin);
        vm.expectRevert();
        pegKeeper.set_direction_paused(2, false);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert();
        pegKeeper.set_direction_paused(2, true);
    }

    function test_governanceCannotEnableExpansionBeforeGasLimitsAreConfigured() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );

        vm.prank(governance);
        vm.expectRevert();
        pegKeeper.set_direction_paused(0, false);
    }

    function test_ownerExecuteUsesOrdinaryCallAndReturnsData() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();
        bytes memory callData = abi.encodeCall(target.setValue, (41));

        vm.expectEmit(true, true, false, true, address(pegKeeper));
        emit IPegKeeperV3.Executed(
            address(target), 0, MockCallTarget.setValue.selector, keccak256(callData)
        );
        vm.prank(governance);
        bytes memory result = pegKeeper.execute(address(target), 0, callData);

        assertEq(target.value(), 41);
        assertEq(abi.decode(result, (uint256)), 42);

        vm.prank(emergencyAdmin);
        vm.expectRevert();
        pegKeeper.execute(address(target), 0, callData);
    }

    function test_ownerExecuteBubblesTargetRevert() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();

        vm.prank(governance);
        vm.expectRevert("target failure");
        pegKeeper.execute(address(target), 0, abi.encodeCall(target.fail, ()));
    }

    function test_ownerExecuteForwardsContractValue() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();
        vm.deal(address(pegKeeper), 2 ether);

        vm.prank(governance);
        pegKeeper.execute(address(target), 1 ether, abi.encodeCall(target.setValuePayable, (73)));

        assertEq(target.value(), 73);
        assertEq(target.receivedValue(), 1 ether);
        assertEq(address(pegKeeper).balance, 1 ether);
    }

    function test_ownerExecuteAcceptsMaximumPayload() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();
        bytes memory payload = new bytes(65_535);

        vm.prank(governance);
        pegKeeper.execute(address(target), 0, payload);

        assertEq(target.dataLength(), payload.length);
    }

    function test_ownerExecuteRejectsPayloadAboveMaximum() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();
        bytes memory payload = new bytes(65_536);

        vm.prank(governance);
        vm.expectRevert();
        pegKeeper.execute(address(target), 0, payload);
    }

    function test_ownerExecuteReturnsLargePayloadWithinCaptureLimit() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();

        vm.prank(governance);
        bytes memory encodedResult =
            pegKeeper.execute(address(target), 0, abi.encodeCall(target.returnBytes, (65_440)));
        bytes memory result = abi.decode(encodedResult, (bytes));

        assertEq(result.length, 65_440);
    }

    function test_ownerExecuteTruncatesReturnDataAboveCaptureLimit() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );
        MockCallTarget target = new MockCallTarget();

        vm.prank(governance);
        bytes memory encodedResult =
            pegKeeper.execute(address(target), 0, abi.encodeCall(target.returnBytes, (65_472)));

        assertEq(encodedResult.length, 65_535);
    }

    function test_unknownSelectorRevertsButEmptyEtherTransferSucceeds() public {
        IPegKeeperV3 pegKeeper = _deploy(
            address(targetAmm), address(targetAsset), address(backingAsset), address(yieldToken)
        );

        (bool unknownSucceeded,) = address(pegKeeper).call(hex"deadbeef");
        assertFalse(unknownSucceeded);

        vm.deal(address(this), 1 ether);
        (bool transferSucceeded,) = address(pegKeeper).call{value: 1 ether}("");
        assertTrue(transferSucceeded);
        assertEq(address(pegKeeper).balance, 1 ether);
    }

    function _deploy(
        address targetAmm_,
        address targetAsset_,
        address backingAsset_,
        address yieldToken_
    ) internal returns (IPegKeeperV3 pegKeeper) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory constructorArgs = abi.encode(
            address(factory),
            targetAmm_,
            targetAsset_,
            backingAsset_,
            yieldToken_,
            feeReceiver,
            governance,
            emergencyAdmin,
            MAX_DEPLOYED
        );
        bytes memory initCode = bytes.concat(creationCode, constructorArgs);
        address deployed;

        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                let size := returndatasize()
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }
        pegKeeper = IPegKeeperV3(deployed);
    }
}
