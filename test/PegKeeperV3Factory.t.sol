// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPegKeeperV3} from "../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../src/interfaces/IPegKeeperV3Factory.sol";
import {
    MockFactory,
    MockToken,
    MockTwoCoinPool,
    MockYieldToken
} from "./PegKeeperV3Foundation.t.sol";

contract FactoryOracle {
    function price() external pure returns (uint256) {
        return 1e18;
    }
}

contract FactoryPreviewModule {
    function previewExpansion(address, uint256)
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256, bool)
    {
        return (11, 12, 13, 14, 15, true);
    }

    function previewUndeployedContraction(address, uint256)
        external
        pure
        returns (uint256, uint256, uint256, bool)
    {
        return (21, 22, 23, true);
    }

    function previewKeeperBuyback(address, uint256)
        external
        pure
        returns (uint256, uint256, uint256, bool)
    {
        return (31, 32, 33, false);
    }
}

contract RevertingKeeperImplementation {
    address public immutable preview_module;
    bool public constant initialized = true;

    constructor(address module) {
        preview_module = module;
    }

    fallback() external {
        revert();
    }
}

contract PegKeeperV3FactoryTest is Test {
    uint256 internal constant CURVE_SWAP = 0;
    uint256 internal constant ERC4626_DEPOSIT = 2;
    uint256 internal constant ERC4626_REDEEM = 3;

    address internal governance = makeAddr("governance");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal nextGovernance = makeAddr("nextGovernance");
    address internal nextEmergencyAdmin = makeAddr("nextEmergencyAdmin");
    address internal nextFeeReceiver = makeAddr("nextFeeReceiver");
    address internal stranger = makeAddr("stranger");

    MockToken internal crvUsd;
    MockToken internal targetAsset;
    MockToken internal backingAsset;
    MockYieldToken internal yieldToken;
    MockFactory internal controllerFactory;
    MockTwoCoinPool internal targetAmm;
    MockTwoCoinPool internal targetToBackingPool;
    MockTwoCoinPool internal backingToCrvUsdPool;

    IPegKeeperV3Factory internal factory;
    address internal implementation;
    FactoryOracle internal targetOracle;
    FactoryOracle internal yieldOracle;
    FactoryPreviewModule internal previewModule;

    function setUp() public {
        crvUsd = new MockToken(18);
        targetAsset = new MockToken(6);
        backingAsset = new MockToken(18);
        yieldToken = new MockYieldToken(address(backingAsset));
        controllerFactory =
            new MockFactory(address(crvUsd), governance, emergencyAdmin, feeReceiver);
        targetAmm = new MockTwoCoinPool(address(targetAsset), address(crvUsd));
        targetToBackingPool = new MockTwoCoinPool(address(targetAsset), address(backingAsset));
        backingToCrvUsdPool = new MockTwoCoinPool(address(backingAsset), address(crvUsd));

        targetOracle = new FactoryOracle();
        yieldOracle = new FactoryOracle();
        previewModule = new FactoryPreviewModule();
        implementation = _deployImplementation(address(previewModule));
        factory = _deployFactory(
            address(this),
            address(controllerFactory),
            implementation,
            _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18)
        );
    }

    function test_ownerDeploysNamedConfiguredAndPausedPegKeeper() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();

        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        IPegKeeperV3 pegKeeper = IPegKeeperV3(deployed);

        assertEq(factory.keeperCount(), 1);
        assertEq(factory.keeperAt(1), deployed);
        assertTrue(factory.isPegKeeper(deployed));
        assertEq(factory.implementationOf(deployed), implementation);
        assertEq(deployed.code.length, 45);
        assertEq(pegKeeper.preview_module(), address(previewModule));
        assertTrue(pegKeeper.initialized());
        assertEq(pegKeeper.target_oracle(), address(targetOracle));
        assertEq(pegKeeper.yield_oracle(), address(yieldOracle));

        assertEq(pegKeeper.name(), "Pegkeeper 1");
        assertEq(pegKeeper.keeper_index(), 1);
        assertEq(pegKeeper.factory(), address(factory));
        assertEq(pegKeeper.controller_factory(), address(controllerFactory));
        assertEq(pegKeeper.target_amm(), address(targetAmm));
        assertEq(pegKeeper.target_asset(), address(targetAsset));
        assertEq(pegKeeper.backing_asset(), address(backingAsset));
        assertEq(pegKeeper.yield_token(), address(yieldToken));

        assertEq(pegKeeper.admin(), governance);
        assertEq(pegKeeper.emergency_admin(), emergencyAdmin);
        assertEq(pegKeeper.fee_receiver(), feeReceiver);
        assertEq(pegKeeper.max_deployed_crvusd(), 25_000_000e18);
        assertEq(pegKeeper.target_amm_execution_buffer_bps(), 5);
        assertEq(pegKeeper.min_downstream_attempt_gas(), 1_500_000);
        assertEq(pegKeeper.fallback_settlement_gas_reserve(), 300_000);
        assertEq(pegKeeper.expansion_max_route_loss_bps(), 100);
        assertEq(pegKeeper.expansion_path_length(), 2);
        assertEq(pegKeeper.contraction_path_length(), 2);

        assertTrue(pegKeeper.expansion_paused());
        assertTrue(pegKeeper.backing_deployment_paused());
        assertTrue(pegKeeper.direct_buyback_paused());
        assertTrue(pegKeeper.undeployed_contraction_paused());
        assertTrue(pegKeeper.yield_contraction_paused());
        assertTrue(pegKeeper.all_execution_paused());
    }

    function test_ownerExplicitlyDeploysPlainErc20IdentityEndpoint() public {
        IPegKeeperV3.RouteStep[] memory empty = new IPegKeeperV3.RouteStep[](0);
        IPegKeeperV3.RouteStep[] memory contraction = new IPegKeeperV3.RouteStep[](1);
        contraction[0] = IPegKeeperV3.RouteStep({
            kind: 0,
            venue: address(targetAmm),
            tokenIn: address(targetAsset),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 3
        });
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(targetAsset),
            false,
            address(targetOracle),
            address(yieldOracle),
            empty,
            contraction
        );
        IPegKeeperV3 pegKeeper = IPegKeeperV3(deployed);

        assertEq(pegKeeper.target_asset(), address(targetAsset));
        assertEq(pegKeeper.backing_asset(), address(targetAsset));
        assertEq(pegKeeper.yield_token(), address(targetAsset));
        assertFalse(pegKeeper.yield_token_is_erc4626());
        assertEq(pegKeeper.expansion_path_length(), 0);
        assertEq(pegKeeper.contraction_path_length(), 1);
    }

    function test_indicesIncreaseAndNamesUseFactoryAssignedIndex() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();

        address first = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        address second = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        assertEq(IPegKeeperV3(first).name(), "Pegkeeper 1");
        assertEq(IPegKeeperV3(second).name(), "Pegkeeper 2");
        assertEq(IPegKeeperV3(first).keeper_index(), 1);
        assertEq(IPegKeeperV3(second).keeper_index(), 2);
        assertEq(factory.keeperAt(1), first);
        assertEq(factory.keeperAt(2), second);
    }

    function test_implementationIsImmutableWhileDefaultsAffectFutureAndSharedRolesUpdateExisting()
        public
    {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        address first = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        bytes32 firstCodeHash = first.codehash;

        address nextImplementation = _deployImplementation(address(previewModule));
        (bool implementationChanged,) = address(factory)
            .call(abi.encodeWithSignature("setImplementation(address)", nextImplementation));
        assertFalse(implementationChanged);
        assertEq(factory.implementation(), implementation);

        factory.setDefaults(
            _defaults(nextGovernance, nextEmergencyAdmin, nextFeeReceiver, 50_000_000e18)
        );
        address second = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        assertEq(factory.implementationOf(first), implementation);
        assertEq(factory.implementationOf(second), implementation);
        assertEq(first.codehash, firstCodeHash);
        assertEq(second.codehash, firstCodeHash);
        assertEq(IPegKeeperV3(first).admin(), nextGovernance);
        assertEq(IPegKeeperV3(first).emergency_admin(), nextEmergencyAdmin);
        assertEq(IPegKeeperV3(first).fee_receiver(), nextFeeReceiver);
        assertEq(IPegKeeperV3(first).max_deployed_crvusd(), 25_000_000e18);
        assertEq(IPegKeeperV3(second).admin(), nextGovernance);
        assertEq(IPegKeeperV3(second).emergency_admin(), nextEmergencyAdmin);
        assertEq(IPegKeeperV3(second).fee_receiver(), nextFeeReceiver);
        assertEq(IPegKeeperV3(second).max_deployed_crvusd(), 50_000_000e18);
    }

    function test_keeperCannotManageFactorySourcedRolesOrFeeReceiver() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        vm.prank(governance);
        (bool rolesUpdated,) = deployed.call(
            abi.encodeWithSignature(
                "set_roles(address,address)", nextGovernance, nextEmergencyAdmin
            )
        );
        assertFalse(rolesUpdated);

        vm.prank(governance);
        (bool feeReceiverUpdated,) =
            deployed.call(abi.encodeWithSignature("set_fee_receiver(address)", nextFeeReceiver));
        assertFalse(feeReceiverUpdated);
    }

    function test_onlyOwnerCanDeployOrChangeFactoryConfiguration() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            _defaults(nextGovernance, nextEmergencyAdmin, nextFeeReceiver, 50_000_000e18);

        vm.startPrank(stranger);
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.setDefaults(defaults_);
        vm.expectRevert(IPegKeeperV3Factory.NotOwner.selector);
        factory.transferOwnership(stranger);
        vm.stopPrank();

        assertEq(factory.keeperCount(), 0);
    }

    function test_invalidRoutesRevertAtomicallyWithoutConsumingIndex() public {
        IPegKeeperV3.RouteStep[] memory empty = new IPegKeeperV3.RouteStep[](0);
        address expectedFirstKeeper = vm.computeCreateAddress(address(factory), 1);

        vm.expectRevert();
        factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            empty,
            empty
        );

        assertEq(factory.keeperCount(), 0);
        assertEq(factory.keeperAt(1), address(0));

        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        assertEq(deployed, expectedFirstKeeper);
    }

    function test_factoryRejectsNonImplementationImplementation() public {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidImplementation.selector);
        _deployFactory(address(this), address(controllerFactory), address(targetAmm), defaults_);

        address shortImplementation = makeAddr("shortImplementation");
        vm.etch(shortImplementation, hex"fe7100");
        vm.expectRevert(IPegKeeperV3Factory.InvalidImplementation.selector);
        _deployFactory(address(this), address(controllerFactory), shortImplementation, defaults_);

        address wrongPreamble = makeAddr("wrongPreamble");
        vm.etch(wrongPreamble, hex"fe71016000");
        vm.expectRevert(IPegKeeperV3Factory.InvalidImplementation.selector);
        _deployFactory(address(this), address(controllerFactory), wrongPreamble, defaults_);
    }

    function test_factoryRejectsInvalidOwnerAndControllerFactory() public {
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_ =
            _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);

        vm.expectRevert(IPegKeeperV3Factory.InvalidOwner.selector);
        _deployFactory(address(0), address(controllerFactory), implementation, defaults_);

        vm.expectRevert(IPegKeeperV3Factory.InvalidOwner.selector);
        _deployFactory(address(this), address(0), implementation, defaults_);

        vm.expectRevert(IPegKeeperV3Factory.InvalidOwner.selector);
        factory.transferOwnership(address(0));

        vm.expectRevert(IPegKeeperV3Factory.InvalidOwner.selector);
        factory.transferOwnership(address(this));
    }

    function test_onlyPendingOwnerCanAcceptOwnership() public {
        factory.transferOwnership(nextGovernance);

        vm.prank(stranger);
        vm.expectRevert(IPegKeeperV3Factory.NotPendingOwner.selector);
        factory.acceptOwnership();
    }

    function test_invalidTargetAmmRevertsWithoutConsumingIndex() public {
        MockTwoCoinPool invalidTargetAmm =
            new MockTwoCoinPool(address(targetAsset), address(backingAsset));
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();

        vm.expectRevert(IPegKeeperV3Factory.InvalidTargetAmm.selector);
        factory.deployPegKeeper(
            address(invalidTargetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        assertEq(factory.keeperCount(), 0);
        assertEq(factory.keeperAt(1), address(0));
    }

    function test_failedImplementationDeploymentUsesCustomErrorAndDoesNotConsumeIndex() public {
        address revertingImplementation =
            address(new RevertingKeeperImplementation(address(previewModule)));
        IPegKeeperV3Factory badFactory = IPegKeeperV3Factory(
            _deployFactory(
                address(this),
                address(controllerFactory),
                revertingImplementation,
                _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18)
            )
        );
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();

        vm.expectRevert(IPegKeeperV3Factory.DeploymentFailed.selector);
        badFactory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        assertEq(badFactory.keeperCount(), 0);
        assertEq(badFactory.keeperAt(1), address(0));
    }

    function test_factoryConstructorRejectsFactoryAsFeeReceiver() public {
        address expectedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        IPegKeeperV3Factory.DeploymentDefaults memory invalid =
            _defaults(governance, emergencyAdmin, expectedFactory, 25_000_000e18);

        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        _deployFactory(address(this), address(controllerFactory), implementation, invalid);
    }

    function test_factoryRejectsInvalidSharedRolesAndFeeReceiver() public {
        IPegKeeperV3Factory.DeploymentDefaults memory invalid =
            _defaults(governance, governance, feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(address(0), emergencyAdmin, feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, address(0), feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, address(0), 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(address(factory), emergencyAdmin, feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, address(factory), feeReceiver, 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, address(factory), 25_000_000e18);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, feeReceiver, 0);
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);
        invalid.targetAmmExecutionBufferBps = 10_001;
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);
        invalid.expansionMaxRouteLossBps = 10_001;
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);
        invalid.fallbackSettlementGasReserve = 0;
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);

        invalid = _defaults(governance, emergencyAdmin, feeReceiver, 25_000_000e18);
        invalid.minDownstreamAttemptGas = invalid.fallbackSettlementGasReserve;
        vm.expectRevert(IPegKeeperV3Factory.InvalidDefaults.selector);
        factory.setDefaults(invalid);
    }

    function test_unknownSelectorReverts() public {
        (bool unknownSelectorSucceeded,) = address(factory).call(hex"deadbeef");
        assertFalse(unknownSelectorSucceeded);
    }

    function test_proxyRuntimePinsImplementationWithoutUpgradeSlot() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );

        bytes memory expectedRuntime = abi.encodePacked(
            hex"363d3d373d3d3d363d73", bytes20(implementation), hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(deployed.code, expectedRuntime);
        assertEq(factory.implementationOf(deployed), implementation);
    }

    function test_implementationAndProxyCannotBeReinitialized() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        address deployed = factory.deployPegKeeper(
            address(targetAmm),
            address(yieldToken),
            true,
            address(targetOracle),
            address(yieldOracle),
            expansion,
            contraction
        );
        bytes memory initialization = abi.encodeCall(
            IPegKeeperV3.initialize,
            (
                address(targetAmm),
                address(targetAsset),
                address(backingAsset),
                address(yieldToken),
                25_000_000e18,
                1,
                address(targetOracle),
                address(yieldOracle)
            )
        );

        (bool implementationInitialized,) = implementation.call(initialization);
        assertFalse(implementationInitialized);
        (bool proxyInitialized,) = deployed.call(initialization);
        assertFalse(proxyInitialized);
    }

    function test_previewSelectorsDelegateToSharedStatelessModule() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        IPegKeeperV3 pegKeeper = IPegKeeperV3(
            factory.deployPegKeeper(
                address(targetAmm),
                address(yieldToken),
                true,
                address(targetOracle),
                address(yieldOracle),
                expansion,
                contraction
            )
        );

        (bool expansionOk, bytes memory expansionResult) =
            address(pegKeeper).staticcall(abi.encodeCall(IPegKeeperV3.previewExpansion, (1)));
        assertTrue(expansionOk);
        assertEq(expansionResult, abi.encode(11, 12, 13, 14, 15, true));
        (bool undeployedOk, bytes memory undeployedResult) = address(pegKeeper)
            .staticcall(abi.encodeCall(IPegKeeperV3.previewUndeployedContraction, (1)));
        assertTrue(undeployedOk);
        assertEq(undeployedResult, abi.encode(21, 22, 23, true));
        (bool buybackOk, bytes memory buybackResult) =
            address(pegKeeper).staticcall(abi.encodeCall(IPegKeeperV3.previewKeeperBuyback, (1)));
        assertTrue(buybackOk);
        assertEq(buybackResult, abi.encode(31, 32, 33, false));
    }

    function test_adminExecuteRecoveryPathRemainsOperational() public {
        (IPegKeeperV3.RouteStep[] memory expansion, IPegKeeperV3.RouteStep[] memory contraction) =
            _paths();
        IPegKeeperV3 pegKeeper = IPegKeeperV3(
            factory.deployPegKeeper(
                address(targetAmm),
                address(yieldToken),
                true,
                address(targetOracle),
                address(yieldOracle),
                expansion,
                contraction
            )
        );

        vm.prank(governance);
        bytes memory result =
            pegKeeper.execute(address(targetAsset), 0, abi.encodeWithSignature("decimals()"));
        assertEq(abi.decode(result, (uint256)), 6);
    }

    function test_twoStepOwnershipTransfer() public {
        factory.transferOwnership(stranger);
        assertEq(factory.owner(), address(this));
        assertEq(factory.pendingOwner(), stranger);

        vm.prank(stranger);
        factory.acceptOwnership();

        assertEq(factory.owner(), stranger);
        assertEq(factory.pendingOwner(), address(0));
    }

    function _deployImplementation(address module) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3.vy/PegKeeperV3.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(module));
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _deployFactory(
        address initialOwner,
        address controllerFactory_,
        address implementation_,
        IPegKeeperV3Factory.DeploymentDefaults memory defaults_
    ) internal returns (IPegKeeperV3Factory deployed) {
        bytes memory creationCode = vm.getCode("out/PegKeeperV3Factory.vy/PegKeeperV3Factory.json");
        bytes memory initCode = bytes.concat(
            creationCode, abi.encode(initialOwner, controllerFactory_, implementation_, defaults_)
        );
        address deployedAddress;
        assembly {
            deployedAddress := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployedAddress) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        deployed = IPegKeeperV3Factory(deployedAddress);
    }

    function _defaults(address admin, address emergency, address receiver, uint256 maxDeployed)
        internal
        pure
        returns (IPegKeeperV3Factory.DeploymentDefaults memory defaults_)
    {
        defaults_ = IPegKeeperV3Factory.DeploymentDefaults({
            admin: admin,
            emergencyAdmin: emergency,
            feeReceiver: receiver,
            maxDeployedCrvUsd: maxDeployed,
            targetAmmExecutionBufferBps: 5,
            minDownstreamAttemptGas: 1_500_000,
            fallbackSettlementGasReserve: 300_000,
            expansionMaxRouteLossBps: 100
        });
    }

    function _paths()
        internal
        view
        returns (
            IPegKeeperV3.RouteStep[] memory expansion,
            IPegKeeperV3.RouteStep[] memory contraction
        )
    {
        expansion = new IPegKeeperV3.RouteStep[](2);
        expansion[0] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(targetToBackingPool),
            tokenIn: address(targetAsset),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
        expansion[1] = IPegKeeperV3.RouteStep({
            kind: ERC4626_DEPOSIT,
            venue: address(yieldToken),
            tokenIn: address(backingAsset),
            tokenOut: address(yieldToken),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });

        contraction = new IPegKeeperV3.RouteStep[](2);
        contraction[0] = IPegKeeperV3.RouteStep({
            kind: ERC4626_REDEEM,
            venue: address(yieldToken),
            tokenIn: address(yieldToken),
            tokenOut: address(backingAsset),
            poolIndexIn: 0,
            poolIndexOut: 0,
            executionBufferBps: 5
        });
        contraction[1] = IPegKeeperV3.RouteStep({
            kind: CURVE_SWAP,
            venue: address(backingToCrvUsdPool),
            tokenIn: address(backingAsset),
            tokenOut: address(crvUsd),
            poolIndexIn: 0,
            poolIndexOut: 1,
            executionBufferBps: 5
        });
    }
}
