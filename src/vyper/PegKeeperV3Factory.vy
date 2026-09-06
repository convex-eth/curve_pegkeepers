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


interface PairedToken:
    def asset() -> address: view


interface PegKeeperPolicy:
    def factory() -> address: view


interface PegKeeperV3:
    def initialize(
        _backing_asset: address,
        _paired_token: address,
        _pool: address,
        _max_deployed_crvusd: uint256,
        _keeper_index: uint256,
        _backing_oracle: address,
    ): nonpayable
    def initialized() -> bool: view
    def set_amm_execution_buffer(_execution_buffer_bps: uint256): nonpayable


struct DeploymentDefaults:
    admin: address
    emergencyAdmin: address
    feeReceiver: address
    maxDeployedCrvUsd: uint256
    ammExecutionBufferBps: uint256



event DefaultsUpdated:
    admin: indexed(address)
    emergencyAdmin: indexed(address)
    feeReceiver: indexed(address)
    maxDeployedCrvUsd: uint256
    ammExecutionBufferBps: uint256


event PegKeeperDeployed:
    index: indexed(uint256)
    pegKeeper: indexed(address)
    implementation: indexed(address)
    amm: address
    pairedToken: address


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


event PolicyUpdated:
    oldPolicy: indexed(address)
    newPolicy: indexed(address)


event ActiveStatusUpdated:
    pegKeeper: indexed(address)
    active: bool


BPS: constant(uint256) = 10_000
CLONE_DEPLOY_CALLDATA_BYTES: constant(uint256) = 36
CLONE_DEPLOY_SELECTOR: constant(Bytes[4]) = method_id("__deployClone(address)")
INITIALIZE_SELECTOR: constant(Bytes[4]) = method_id(
    "initialize(address,address,address,uint256,uint256,address)"
)

CONTROLLER_FACTORY: immutable(address)
IMPLEMENTATION: immutable(address)

owner: public(address)
pendingOwner: public(address)
policy: public(address)
_defaults: DeploymentDefaults

_keeperCount: uint256
activePegKeeperCount: public(uint256)
activePegKeeperAt: public(HashMap[uint256, address])
is_active: public(HashMap[address, bool])
_activeIndexPlusOne: HashMap[address, uint256]
_isDeployed: HashMap[address, bool]


@external
def __init__(
    _initialOwner: address,
    _controllerFactory: address,
    _implementation: address,
    _policy: address,
    _defaults: DeploymentDefaults,
):
    """
    @notice Sets the owner, controller factory, base keeper code, policy, and defaults.
    """
    if _initialOwner == empty(address) or _controllerFactory == empty(address):
        raw_revert(method_id("InvalidOwner()"))
    if _policy == empty(address) or _policy.codesize == 0:
        raw_revert(method_id("InvalidPolicy()"))

    CONTROLLER_FACTORY = _controllerFactory
    if not self._is_locked_implementation(_implementation):
        raw_revert(method_id("InvalidImplementation()"))
    IMPLEMENTATION = _implementation
    self.owner = _initialOwner
    self.policy = _policy
    self._set_defaults(_defaults)

    log OwnershipTransferred(empty(address), _initialOwner)
    log PolicyUpdated(empty(address), _policy)


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
    _amm: address,
    _pairedTokenIsErc4626: bool,
    _backingOracle: address,
) -> address:
    """
    @notice Lets the owner deploy and record a paused direct-liquidity keeper.
    """
    self._check_owner()
    if PegKeeperPolicy(self.policy).factory() != self:
        raw_revert(method_id("InvalidPolicy()"))

    paired_token: address = empty(address)
    backing_asset: address = empty(address)
    paired_token, backing_asset = self._resolve_assets(_amm, _pairedTokenIsErc4626)

    index: uint256 = self._keeperCount + 1
    implementation: address = IMPLEMENTATION
    config: DeploymentDefaults = self._defaults
    peg_keeper: address = self._deploy_keeper(
        implementation,
        backing_asset,
        paired_token,
        _amm,
        config.maxDeployedCrvUsd,
        index,
        _backingOracle,
    )

    PegKeeperV3(peg_keeper).set_amm_execution_buffer(config.ammExecutionBufferBps)

    self._keeperCount = index
    self._isDeployed[peg_keeper] = True
    self._add_active(peg_keeper)

    log PegKeeperDeployed(index, peg_keeper, implementation, _amm, paired_token)
    return peg_keeper


@external
def setDefaults(_newDefaults: DeploymentDefaults):
    """
    @notice Lets the owner change shared roles and defaults used for future keepers.
    """
    self._check_owner()
    self._set_defaults(_newDefaults)


@external
def setPolicy(_newPolicy: address):
    """
    @notice Replaces the expansion and direction policy used by every keeper.
    """
    self._check_owner()
    if _newPolicy == empty(address) or _newPolicy.codesize == 0:
        raw_revert(method_id("InvalidPolicy()"))
    if PegKeeperPolicy(_newPolicy).factory() != self:
        raw_revert(method_id("InvalidPolicy()"))

    old_policy: address = self.policy
    self.policy = _newPolicy
    log PolicyUpdated(old_policy, _newPolicy)


@external
def set_active(_peg_keeper: address, _active: bool):
    """
    @notice Adds or removes a factory-deployed keeper from the active policy set.
    """
    self._check_owner()
    if not self._isDeployed[_peg_keeper]:
        raw_revert(method_id("InvalidKeeper()"))
    if self.is_active[_peg_keeper] == _active:
        return

    if _active:
        self._add_active(_peg_keeper)
    else:
        self._remove_active(_peg_keeper)


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
    _amm: address,
    _pairedTokenIsErc4626: bool,
) -> (address, address):
    crv_usd: address = ControllerFactory(CONTROLLER_FACTORY).stablecoin()
    coin_0: address = TwoCoinPool(_amm).coins(0)
    coin_1: address = TwoCoinPool(_amm).coins(1)
    paired_token: address = empty(address)

    if coin_0 == crv_usd and coin_1 != crv_usd:
        paired_token = coin_1
    elif coin_1 == crv_usd and coin_0 != crv_usd:
        paired_token = coin_0
    else:
        raw_revert(method_id("InvalidAmm()"))

    backing_asset: address = paired_token
    if _pairedTokenIsErc4626:
        backing_asset = PairedToken(paired_token).asset()
    return paired_token, backing_asset


@internal
def _deploy_keeper(
    _implementation: address,
    _backingAsset: address,
    _pairedToken: address,
    _pool: address,
    _maxDeployedCrvUsd: uint256,
    _index: uint256,
    _backingOracle: address,
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
            _backingAsset,
            _pairedToken,
            _pool,
            _maxDeployedCrvUsd,
            _index,
            _backingOracle,
            method_id=INITIALIZE_SELECTOR,
        ),
        revert_on_failure=False,
    )
    if not initialized:
        raw_revert(method_id("DeploymentFailed()"))
    return peg_keeper


@internal
def _add_active(_peg_keeper: address):
    index: uint256 = self.activePegKeeperCount
    self.activePegKeeperAt[index] = _peg_keeper
    self._activeIndexPlusOne[_peg_keeper] = index + 1
    self.activePegKeeperCount = index + 1
    self.is_active[_peg_keeper] = True
    log ActiveStatusUpdated(_peg_keeper, True)


@internal
def _remove_active(_peg_keeper: address):
    index_plus_one: uint256 = self._activeIndexPlusOne[_peg_keeper]
    assert index_plus_one != 0
    index: uint256 = index_plus_one - 1
    last_index: uint256 = self.activePegKeeperCount - 1
    if index != last_index:
        moved: address = self.activePegKeeperAt[last_index]
        self.activePegKeeperAt[index] = moved
        self._activeIndexPlusOne[moved] = index + 1

    self.activePegKeeperAt[last_index] = empty(address)
    self._activeIndexPlusOne[_peg_keeper] = 0
    self.activePegKeeperCount = last_index
    self.is_active[_peg_keeper] = False
    log ActiveStatusUpdated(_peg_keeper, False)


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
        or _newDefaults.ammExecutionBufferBps > BPS
    ):
        raw_revert(method_id("InvalidDefaults()"))

    self._defaults = _newDefaults
    log DefaultsUpdated(
        _newDefaults.admin,
        _newDefaults.emergencyAdmin,
        _newDefaults.feeReceiver,
        _newDefaults.maxDeployedCrvUsd,
        _newDefaults.ammExecutionBufferBps,
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
    if not ok or len(response) != 32:
        return False
    return _abi_decode(response, bool)
