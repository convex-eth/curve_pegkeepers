# pragma version 0.4.3
"""
@title PegKeeperPolicy
@license MIT
@notice Applies aggregate direction to standalone PegKeeperV3 contracts bound to this policy.
"""


interface PriceOracle:
    def price() -> uint256: view


interface PegKeeper:
    def policy() -> address: view
    def can_expand_without_policy() -> bool: view


event AggregateCrvUsdOracleUpdated:
    oldOracle: indexed(address)
    newOracle: indexed(address)


event KeeperProfitShareUpdated:
    oldKeeperProfitShareBps: uint256
    newKeeperProfitShareBps: uint256


event PegKeeperAdded:
    pegKeeper: indexed(address)


event PegKeeperRemoved:
    pegKeeper: indexed(address)


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


BPS: constant(uint256) = 10_000
PRECISION: constant(uint256) = 10 ** 18
MAX_KEEPERS: constant(uint256) = 8
POLICY_SELECTOR: constant(Bytes[4]) = method_id("policy()")
LOCAL_EXPANDABLE_SELECTOR: constant(Bytes[4]) = method_id("can_expand_without_policy()")

owner: public(address)
pendingOwner: public(address)
ownershipTransferNonce: public(uint256)
aggregateCrvUsdOracle: public(address)
_keeperProfitShareBps: uint256
peg_keepers: public(DynArray[address, MAX_KEEPERS])
_pegKeeperIndexPlusOne: HashMap[address, uint256]


@deploy
def __init__(
    _initial_owner: address,
    _aggregate_crvusd_oracle: address,
    _keeper_profit_share_bps: uint256,
):
    if _initial_owner == empty(address):
        raw_revert(method_id("InvalidOwner()"))
    if _aggregate_crvusd_oracle == empty(address) or _aggregate_crvusd_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))
    if _keeper_profit_share_bps > BPS:
        raw_revert(method_id("InvalidThreshold()"))

    self.owner = _initial_owner
    self.aggregateCrvUsdOracle = _aggregate_crvusd_oracle
    self._keeperProfitShareBps = _keeper_profit_share_bps
    log OwnershipTransferred(oldOwner=empty(address), newOwner=_initial_owner)
    log AggregateCrvUsdOracleUpdated(
        oldOracle=empty(address), newOracle=_aggregate_crvusd_oracle
    )
    log KeeperProfitShareUpdated(
        oldKeeperProfitShareBps=0,
        newKeeperProfitShareBps=_keeper_profit_share_bps,
    )


@external
def set_aggregate_crvusd_oracle(_new_oracle: address):
    self._check_owner()
    if _new_oracle == empty(address) or _new_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))

    old_oracle: address = self.aggregateCrvUsdOracle
    self.aggregateCrvUsdOracle = _new_oracle
    log AggregateCrvUsdOracleUpdated(oldOracle=old_oracle, newOracle=_new_oracle)


@external
def set_keeper_profit_share_bps(_new_keeper_profit_share_bps: uint256):
    self._check_owner()
    if _new_keeper_profit_share_bps > BPS:
        raw_revert(method_id("InvalidThreshold()"))

    old_keeper_profit_share_bps: uint256 = self._keeperProfitShareBps
    self._keeperProfitShareBps = _new_keeper_profit_share_bps
    log KeeperProfitShareUpdated(
        oldKeeperProfitShareBps=old_keeper_profit_share_bps,
        newKeeperProfitShareBps=_new_keeper_profit_share_bps,
    )


@external
@view
def keeper_profit_share_bps(_keeper: address) -> uint256:
    return self._keeperProfitShareBps


@external
@view
def peg_keeper_count() -> uint256:
    return len(self.peg_keepers)


@external
@view
def is_active(_keeper: address) -> bool:
    return self._pegKeeperIndexPlusOne[_keeper] != 0


@external
def add_peg_keepers(_peg_keepers: DynArray[address, MAX_KEEPERS]):
    self._check_owner()
    for keeper: address in _peg_keepers:
        if not self._is_bound_keeper(keeper):
            raw_revert(method_id("InvalidKeeper()"))
        if self._pegKeeperIndexPlusOne[keeper] != 0:
            raw_revert(method_id("DuplicateKeeper()"))

        self.peg_keepers.append(keeper)
        self._pegKeeperIndexPlusOne[keeper] = len(self.peg_keepers)
        log PegKeeperAdded(pegKeeper=keeper)


@external
def remove_peg_keepers(_peg_keepers: DynArray[address, MAX_KEEPERS]):
    self._check_owner()
    for keeper: address in _peg_keepers:
        index_plus_one: uint256 = self._pegKeeperIndexPlusOne[keeper]
        if index_plus_one == 0:
            raw_revert(method_id("InvalidKeeper()"))

        index: uint256 = index_plus_one - 1
        last_index: uint256 = len(self.peg_keepers) - 1
        if index != last_index:
            moved: address = self.peg_keepers[last_index]
            self.peg_keepers[index] = moved
            self._pegKeeperIndexPlusOne[moved] = index + 1

        self.peg_keepers.pop()
        self._pegKeeperIndexPlusOne[keeper] = 0
        log PegKeeperRemoved(pegKeeper=keeper)


@external
@view
def expansion_regime() -> bool:
    return self._aggregate_crvusd_price() >= PRECISION


@external
@view
def can_allocate(_keeper: address) -> bool:
    return self._is_active_keeper(_keeper)


@external
@view
def can_expand(_keeper: address) -> bool:
    if self._aggregate_crvusd_price() < PRECISION:
        return False
    return self._is_locally_expandable(_keeper)


@external
@view
def can_contract(_keeper: address) -> bool:
    if not self._is_bound_keeper(_keeper):
        return False
    return self._aggregate_crvusd_price() <= PRECISION


@external
def transferOwnership(_new_owner: address):
    if msg.sender != self.owner:
        raw_revert(method_id("NotOwner()"))
    if _new_owner == empty(address) or _new_owner == self.owner:
        raw_revert(method_id("InvalidOwner()"))

    self.pendingOwner = _new_owner
    self.ownershipTransferNonce += 1
    log OwnershipTransferStarted(owner=self.owner, pendingOwner=_new_owner)


@external
def acceptOwnership(_expected_nonce: uint256):
    if msg.sender != self.pendingOwner:
        raw_revert(method_id("NotPendingOwner()"))
    if _expected_nonce != self.ownershipTransferNonce:
        raw_revert(method_id("InvalidOwnershipTransferNonce()"))

    old_owner: address = self.owner
    self.owner = msg.sender
    self.pendingOwner = empty(address)
    log OwnershipTransferred(oldOwner=old_owner, newOwner=msg.sender)


@internal
@view
def _check_owner():
    if msg.sender != self.owner:
        raw_revert(method_id("NotOwner()"))
    if self.pendingOwner != empty(address):
        raw_revert(method_id("OwnershipHandoffPending()"))


@internal
@view
def _aggregate_crvusd_price() -> uint256:
    response: Bytes[64] = raw_call(
        self.aggregateCrvUsdOracle,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
    )
    assert len(response) == 32
    price: uint256 = convert(slice(response, 0, 32), uint256)
    assert price > 0
    return price


@internal
@view
def _is_bound_keeper(_keeper: address) -> bool:
    if _keeper == empty(address) or _keeper.codesize == 0:
        return False

    success: bool = False
    response: Bytes[32] = empty(Bytes[32])
    success, response = raw_call(
        _keeper,
        POLICY_SELECTOR,
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not success or len(response) != 32:
        return False
    return abi_decode(response, address) == self


@internal
@view
def _is_locally_expandable(_keeper: address) -> bool:
    if not self._is_active_keeper(_keeper):
        return False

    success: bool = False
    response: Bytes[32] = empty(Bytes[32])
    success, response = raw_call(
        _keeper,
        LOCAL_EXPANDABLE_SELECTOR,
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not success or len(response) != 32:
        return False
    return convert(response, uint256) == 1


@internal
@view
def _is_active_keeper(_keeper: address) -> bool:
    if self._pegKeeperIndexPlusOne[_keeper] == 0:
        return False
    return self._is_bound_keeper(_keeper)
