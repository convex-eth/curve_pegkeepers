# pragma version 0.3.10
"""
@title PegKeeperV3Factory
@license MIT
@notice Deploys and records PegKeeperV3 contracts using settings chosen by the owner.
@dev Each new keeper is fixed to one base contract and starts paused.
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
        _yield_amm: address,
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
    ): nonpayable
    def set_expansion_config(
        _target_amm_execution_buffer_bps: uint256,
        _yield_amm_execution_buffer_bps: uint256,
    ): nonpayable


struct DeploymentDefaults:
    admin: address
    emergencyAdmin: address
    feeReceiver: address
    maxDeployedCrvUsd: uint256
    targetAmmExecutionBufferBps: uint256
    yieldAmmExecutionBufferBps: uint256
    expansionMaxRouteLossBps: uint256



event DefaultsUpdated:
    admin: indexed(address)
    emergencyAdmin: indexed(address)
    feeReceiver: indexed(address)
    maxDeployedCrvUsd: uint256
    targetAmmExecutionBufferBps: uint256
    yieldAmmExecutionBufferBps: uint256
    expansionMaxRouteLossBps: uint256


event PegKeeperDeployed:
    index: indexed(uint256)
    pegKeeper: indexed(address)
    implementation: indexed(address)
    targetAmm: address
    yieldToken: address
    yieldAmm: address


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


event AggregateCrvUsdOracleUpdated:
    oldOracle: indexed(address)
    newOracle: indexed(address)


BPS: constant(uint256) = 10_000
CLONE_DEPLOY_CALLDATA_BYTES: constant(uint256) = 36
CLONE_DEPLOY_SELECTOR: constant(Bytes[4]) = method_id("__deployClone(address)")
INITIALIZE_SELECTOR: constant(Bytes[4]) = method_id(
    "initialize(address,address,address,address,address,uint256,uint256,address,address)"
)

CONTROLLER_FACTORY: immutable(address)
IMPLEMENTATION: immutable(address)

owner: public(address)
pendingOwner: public(address)
aggregateCrvUsdOracle: public(address)
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
    _aggregateCrvUsdOracle: address,
    _defaults: DeploymentDefaults,
):
    """
    @notice Sets the owner, controller factory, base keeper code, aggregate oracle, and defaults.
    """
    if _initialOwner == empty(address) or _controllerFactory == empty(address):
        raw_revert(method_id("InvalidOwner()"))
    if _aggregateCrvUsdOracle == empty(address) or _aggregateCrvUsdOracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))

    CONTROLLER_FACTORY = _controllerFactory
    if not self._is_locked_implementation(_implementation):
        raw_revert(method_id("InvalidImplementation()"))
    IMPLEMENTATION = _implementation
    self.owner = _initialOwner
    self.aggregateCrvUsdOracle = _aggregateCrvUsdOracle
    self._set_defaults(_defaults)

    log OwnershipTransferred(empty(address), _initialOwner)
    log AggregateCrvUsdOracleUpdated(empty(address), _aggregateCrvUsdOracle)


@external
@pure
def controllerFactory() -> address:
    """
    @notice Returns the controller factory used by every keeper.
    """
    return CONTROLLER_FACTORY


@external
@pure
def implementation() -> address:
    """
    @notice Returns the base keeper code used for new keepers.
    """
    return IMPLEMENTATION


@external
@view
def defaults() -> DeploymentDefaults:
    """
    @notice Returns the current settings used when a keeper is created.
    """
    return self._defaults


@external
@view
def admin() -> address:
    """
    @notice Returns the admin shared by the factory's keepers.
    """
    return self._defaults.admin


@external
@view
def emergency_admin() -> address:
    """
    @notice Returns the emergency account shared by the factory's keepers.
    """
    return self._defaults.emergencyAdmin


@external
@view
def fee_receiver() -> address:
    """
    @notice Returns the fee receiver shared by the factory's keepers.
    """
    return self._defaults.feeReceiver


@external
def deployPegKeeper(
    _targetAmm: address,
    _yieldToken: address,
    _yieldAmm: address,
    _yieldTokenIsErc4626: bool,
    _targetOracle: address,
    _yieldOracle: address,
    _expansionSteps: DynArray[RouteStep, 16],
) -> address:
    """
    @notice Lets the owner deploy a paused keeper, set its token paths, and record it.
    """
    self._check_owner()

    target_asset: address = empty(address)
    backing_asset: address = empty(address)
    target_asset, backing_asset = self._resolve_assets(
        _targetAmm,
        _yieldToken,
        _yieldTokenIsErc4626,
    )

    index: uint256 = self.keeperCount + 1
    implementation: address = IMPLEMENTATION
    config: DeploymentDefaults = self._defaults
    peg_keeper: address = self._deploy_keeper(
        implementation,
        _targetAmm,
        target_asset,
        backing_asset,
        _yieldToken,
        _yieldAmm,
        config.maxDeployedCrvUsd,
        index,
        _targetOracle,
        _yieldOracle,
    )

    PegKeeperV3(peg_keeper).setPaths(
        _expansionSteps,
        config.expansionMaxRouteLossBps,
    )
    PegKeeperV3(peg_keeper).set_expansion_config(
        config.targetAmmExecutionBufferBps,
        config.yieldAmmExecutionBufferBps,
    )

    self.keeperCount = index
    self.keeperAt[index] = peg_keeper
    self.isPegKeeper[peg_keeper] = True
    self.implementationOf[peg_keeper] = implementation

    log PegKeeperDeployed(index, peg_keeper, implementation, _targetAmm, _yieldToken, _yieldAmm)
    return peg_keeper


@external
def setDefaults(_newDefaults: DeploymentDefaults):
    """
    @notice Lets the owner change shared roles and defaults used for future keepers.
    """
    self._check_owner()
    self._set_defaults(_newDefaults)


@external
def setAggregateCrvUsdOracle(_newOracle: address):
    """
    @notice Changes the aggregate crvUSD price source used by every keeper.
    """
    self._check_owner()
    if _newOracle == empty(address) or _newOracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))

    old_oracle: address = self.aggregateCrvUsdOracle
    self.aggregateCrvUsdOracle = _newOracle
    log AggregateCrvUsdOracleUpdated(old_oracle, _newOracle)


@external
def transferOwnership(_newOwner: address):
    """
    @notice Names the account that may accept factory ownership.
    """
    self._check_owner()
    if _newOwner == empty(address) or _newOwner == self.owner:
        raw_revert(method_id("InvalidOwner()"))

    self.pendingOwner = _newOwner
    log OwnershipTransferStarted(self.owner, _newOwner)


@external
def acceptOwnership():
    """
    @notice Accepts factory ownership for the pending owner.
    """
    if msg.sender != self.pendingOwner:
        raw_revert(method_id("NotPendingOwner()"))

    old_owner: address = self.owner
    self.owner = msg.sender
    self.pendingOwner = empty(address)
    log OwnershipTransferred(old_owner, msg.sender)


@external
def __default__() -> address:
    """
    @notice Creates a new keeper copy only when called by this factory.
    """
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
def _resolve_assets(
    _targetAmm: address,
    _yieldToken: address,
    _yieldTokenIsErc4626: bool,
) -> (address, address):
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

    backing_asset: address = _yieldToken
    if _yieldTokenIsErc4626:
        backing_asset = YieldToken(_yieldToken).asset()
    return target_asset, backing_asset


@internal
def _deploy_keeper(
    _implementation: address,
    _targetAmm: address,
    _targetAsset: address,
    _backingAsset: address,
    _yieldToken: address,
    _yieldAmm: address,
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
            _yieldAmm,
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
        or _newDefaults.yieldAmmExecutionBufferBps > BPS
        or _newDefaults.expansionMaxRouteLossBps > BPS
    ):
        raw_revert(method_id("InvalidDefaults()"))

    self._defaults = _newDefaults
    log DefaultsUpdated(
        _newDefaults.admin,
        _newDefaults.emergencyAdmin,
        _newDefaults.feeReceiver,
        _newDefaults.maxDeployedCrvUsd,
        _newDefaults.targetAmmExecutionBufferBps,
        _newDefaults.yieldAmmExecutionBufferBps,
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
