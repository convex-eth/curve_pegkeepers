# pragma version 0.3.10
"""
@title PegKeeperV3Factory
@license MIT
@notice Owner-gated deployment registry for non-upgradeable PegKeeperV3 minimal proxies.
@dev Each proxy pins the implementation in its 45-byte EIP-1167 runtime and is initialized atomically.
"""


interface ControllerFactory:
    def stablecoin() -> address: view


interface TwoCoinPool:
    def coins(_index: uint256) -> address: view


interface YieldToken:
    def asset() -> address: view


struct RouteStep:
    kind: uint256
    venue: address
    tokenIn: address
    tokenOut: address
    poolIndexIn: int128
    poolIndexOut: int128
    executionBufferBps: uint256


interface PegKeeperV3:
    def initialize(
        _target_amm: address,
        _target_asset: address,
        _backing_asset: address,
        _yield_token: address,
        _max_deployed_crvusd: uint256,
        _keeper_index: uint256,
        _target_oracle: address,
        _yield_oracle: address,
    ): nonpayable
    def initialized() -> bool: view
    def preview_module() -> address: view
    def setPaths(
        _expansion_steps: DynArray[RouteStep, 16],
        _expansion_max_route_loss_bps: uint256,
        _contraction_steps: DynArray[RouteStep, 16],
    ): nonpayable
    def set_expansion_config(
        _target_amm_execution_buffer_bps: uint256,
        _min_downstream_attempt_gas: uint256,
        _fallback_settlement_gas_reserve: uint256,
    ): nonpayable


struct DeploymentDefaults:
    admin: address
    emergencyAdmin: address
    feeReceiver: address
    maxDeployedCrvUsd: uint256
    targetAmmExecutionBufferBps: uint256
    minDownstreamAttemptGas: uint256
    fallbackSettlementGasReserve: uint256
    expansionMaxRouteLossBps: uint256



event DefaultsUpdated:
    admin: indexed(address)
    emergencyAdmin: indexed(address)
    feeReceiver: indexed(address)
    maxDeployedCrvUsd: uint256
    targetAmmExecutionBufferBps: uint256
    minDownstreamAttemptGas: uint256
    fallbackSettlementGasReserve: uint256
    expansionMaxRouteLossBps: uint256


event PegKeeperDeployed:
    index: indexed(uint256)
    pegKeeper: indexed(address)
    implementation: indexed(address)
    targetAmm: address
    yieldToken: address


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


BPS: constant(uint256) = 10_000
CLONE_DEPLOY_CALLDATA_BYTES: constant(uint256) = 36
CLONE_DEPLOY_SELECTOR: constant(Bytes[4]) = method_id("__deployClone(address)")
INITIALIZE_SELECTOR: constant(Bytes[4]) = method_id(
    "initialize(address,address,address,address,uint256,uint256,address,address)"
)

CONTROLLER_FACTORY: immutable(address)
IMPLEMENTATION: immutable(address)

owner: public(address)
pendingOwner: public(address)
_defaults: DeploymentDefaults

keeperCount: public(uint256)
keeperAt: public(HashMap[uint256, address])
isPegKeeper: public(HashMap[address, bool])
implementationOf: public(HashMap[address, address])


@external
def __init__(
    _initialOwner: address,
    _controllerFactory: address,
    _implementation: address,
    _defaults: DeploymentDefaults,
):
    if _initialOwner == empty(address) or _controllerFactory == empty(address):
        raw_revert(method_id("InvalidOwner()"))

    CONTROLLER_FACTORY = _controllerFactory
    if not self._is_locked_implementation(_implementation):
        raw_revert(method_id("InvalidImplementation()"))
    IMPLEMENTATION = _implementation
    self.owner = _initialOwner
    self._set_defaults(_defaults)

    log OwnershipTransferred(empty(address), _initialOwner)


@external
@pure
def controllerFactory() -> address:
    return CONTROLLER_FACTORY


@external
@pure
def implementation() -> address:
    return IMPLEMENTATION


@external
@view
def defaults() -> DeploymentDefaults:
    return self._defaults


@external
@view
def admin() -> address:
    return self._defaults.admin


@external
@view
def emergency_admin() -> address:
    return self._defaults.emergencyAdmin


@external
@view
def fee_receiver() -> address:
    return self._defaults.feeReceiver


@external
def deployPegKeeper(
    _targetAmm: address,
    _yieldToken: address,
    _targetOracle: address,
    _yieldOracle: address,
    _expansionSteps: DynArray[RouteStep, 16],
    _contractionSteps: DynArray[RouteStep, 16],
) -> address:
    self._check_owner()

    target_asset: address = empty(address)
    backing_asset: address = empty(address)
    target_asset, backing_asset = self._resolve_assets(_targetAmm, _yieldToken)

    index: uint256 = self.keeperCount + 1
    implementation: address = IMPLEMENTATION
    config: DeploymentDefaults = self._defaults
    peg_keeper: address = self._deploy_keeper(
        implementation,
        _targetAmm,
        target_asset,
        backing_asset,
        _yieldToken,
        config.maxDeployedCrvUsd,
        index,
        _targetOracle,
        _yieldOracle,
    )

    PegKeeperV3(peg_keeper).setPaths(
        _expansionSteps,
        config.expansionMaxRouteLossBps,
        _contractionSteps,
    )
    PegKeeperV3(peg_keeper).set_expansion_config(
        config.targetAmmExecutionBufferBps,
        config.minDownstreamAttemptGas,
        config.fallbackSettlementGasReserve,
    )

    self.keeperCount = index
    self.keeperAt[index] = peg_keeper
    self.isPegKeeper[peg_keeper] = True
    self.implementationOf[peg_keeper] = implementation

    log PegKeeperDeployed(index, peg_keeper, implementation, _targetAmm, _yieldToken)
    return peg_keeper


@external
def setDefaults(_newDefaults: DeploymentDefaults):
    self._check_owner()
    self._set_defaults(_newDefaults)


@external
def transferOwnership(_newOwner: address):
    self._check_owner()
    if _newOwner == empty(address) or _newOwner == self.owner:
        raw_revert(method_id("InvalidOwner()"))

    self.pendingOwner = _newOwner
    log OwnershipTransferStarted(self.owner, _newOwner)


@external
def acceptOwnership():
    if msg.sender != self.pendingOwner:
        raw_revert(method_id("NotPendingOwner()"))

    old_owner: address = self.owner
    self.owner = msg.sender
    self.pendingOwner = empty(address)
    log OwnershipTransferred(old_owner, msg.sender)


@external
def __default__() -> address:
    # Keep checked proxy creation inside a self-call so any CREATE failure can be
    # translated into the legacy DeploymentFailed() selector.
    if msg.sender != self or len(msg.data) != CLONE_DEPLOY_CALLDATA_BYTES:
        raw_revert(b"")
    if slice(msg.data, 0, 4) != CLONE_DEPLOY_SELECTOR:
        raw_revert(b"")
    implementation: address = _abi_decode(slice(msg.data, 4, 32), address)
    return create_minimal_proxy_to(implementation)


@internal
@view
def _check_owner():
    if msg.sender != self.owner:
        raw_revert(method_id("NotOwner()"))


@internal
@view
def _resolve_assets(_targetAmm: address, _yieldToken: address) -> (address, address):
    crv_usd: address = ControllerFactory(CONTROLLER_FACTORY).stablecoin()
    coin_0: address = TwoCoinPool(_targetAmm).coins(0)
    coin_1: address = TwoCoinPool(_targetAmm).coins(1)
    target_asset: address = empty(address)

    if coin_0 == crv_usd and coin_1 != crv_usd:
        target_asset = coin_1
    elif coin_1 == crv_usd and coin_0 != crv_usd:
        target_asset = coin_0
    else:
        raw_revert(method_id("InvalidTargetAmm()"))

    return target_asset, YieldToken(_yieldToken).asset()


@internal
def _deploy_keeper(
    _implementation: address,
    _targetAmm: address,
    _targetAsset: address,
    _backingAsset: address,
    _yieldToken: address,
    _maxDeployedCrvUsd: uint256,
    _index: uint256,
    _targetOracle: address,
    _yieldOracle: address,
) -> address:
    succeeded: bool = False
    response: Bytes[32] = empty(Bytes[32])
    succeeded, response = raw_call(
        self,
        _abi_encode(_implementation, method_id=CLONE_DEPLOY_SELECTOR),
        max_outsize=32,
        revert_on_failure=False,
    )
    if not succeeded or len(response) != 32:
        raw_revert(method_id("DeploymentFailed()"))

    peg_keeper: address = _abi_decode(response, address)
    initialized: bool = raw_call(
        peg_keeper,
        _abi_encode(
            _targetAmm,
            _targetAsset,
            _backingAsset,
            _yieldToken,
            _maxDeployedCrvUsd,
            _index,
            _targetOracle,
            _yieldOracle,
            method_id=INITIALIZE_SELECTOR,
        ),
        revert_on_failure=False,
    )
    if not initialized:
        raw_revert(method_id("DeploymentFailed()"))
    return peg_keeper


@internal
def _set_defaults(_newDefaults: DeploymentDefaults):
    if (
        _newDefaults.admin == empty(address)
        or _newDefaults.emergencyAdmin == empty(address)
        or _newDefaults.feeReceiver == empty(address)
        or _newDefaults.admin == _newDefaults.emergencyAdmin
        or _newDefaults.admin == self
        or _newDefaults.emergencyAdmin == self
        or _newDefaults.feeReceiver == self
        or _newDefaults.maxDeployedCrvUsd == 0
        or _newDefaults.targetAmmExecutionBufferBps > BPS
        or _newDefaults.expansionMaxRouteLossBps > BPS
        or _newDefaults.fallbackSettlementGasReserve == 0
        or _newDefaults.minDownstreamAttemptGas <= _newDefaults.fallbackSettlementGasReserve
    ):
        raw_revert(method_id("InvalidDefaults()"))

    self._defaults = _newDefaults
    log DefaultsUpdated(
        _newDefaults.admin,
        _newDefaults.emergencyAdmin,
        _newDefaults.feeReceiver,
        _newDefaults.maxDeployedCrvUsd,
        _newDefaults.targetAmmExecutionBufferBps,
        _newDefaults.minDownstreamAttemptGas,
        _newDefaults.fallbackSettlementGasReserve,
        _newDefaults.expansionMaxRouteLossBps,
    )


@internal
@view
def _is_locked_implementation(_candidate: address) -> bool:
    if _candidate.codesize == 0:
        return False
    ok: bool = False
    response: Bytes[32] = empty(Bytes[32])
    ok, response = raw_call(
        _candidate,
        method_id("initialized()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32 or not _abi_decode(response, bool):
        return False
    ok, response = raw_call(
        _candidate,
        method_id("preview_module()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        return False
    module: address = _abi_decode(response, address)
    return module != empty(address) and module.codesize > 0
