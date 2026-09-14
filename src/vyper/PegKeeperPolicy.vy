# pragma version 0.4.3
"""
@title PegKeeperPolicy
@license MIT
@notice Applies aggregate direction and active-keeper admission to one PegKeeperV3 factory.
"""


interface PriceOracle:
    def price() -> uint256: view


interface PegKeeperFactory:
    def is_active(_keeper: address) -> bool: view


interface PegKeeper:
    def factory() -> address: view


event FactorySet:
    factory: indexed(address)


event AggregateCrvUsdOracleUpdated:
    oldOracle: indexed(address)
    newOracle: indexed(address)


event KeeperProfitShareUpdated:
    oldKeeperProfitShareBps: uint256
    newKeeperProfitShareBps: uint256


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


BPS: constant(uint256) = 10_000
PRECISION: constant(uint256) = 10 ** 18
LOCAL_EXPANDABLE_SELECTOR: constant(Bytes[4]) = method_id("can_expand_without_policy()")

owner: public(address)
pendingOwner: public(address)
ownershipTransferNonce: public(uint256)
factory: public(address)
aggregateCrvUsdOracle: public(address)
_keeperProfitShareBps: uint256


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
def set_factory(_factory: address):
    self._check_owner()
    if self.factory != empty(address) or _factory == empty(address) or _factory.codesize == 0:
        raw_revert(method_id("InvalidFactory()"))

    self.factory = _factory
    log FactorySet(factory=_factory)


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
def expansion_regime() -> bool:
    return self._aggregate_crvusd_price() >= PRECISION


@external
@view
def can_allocate(_keeper: address) -> bool:
    return self._is_active_keeper(_keeper)


@external
@view
def can_expand(_keeper: address) -> bool:
    if self.factory == empty(address):
        return False
    if self._aggregate_crvusd_price() < PRECISION:
        return False
    return self._is_locally_expandable(_keeper)


@external
@view
def can_contract(_keeper: address) -> bool:
    factory: address = self.factory
    if factory == empty(address) or _keeper == empty(address):
        return False
    if staticcall PegKeeper(_keeper).factory() != factory:
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
def _is_active_keeper(_keeper: address) -> bool:
    factory: address = self.factory
    if factory == empty(address) or _keeper == empty(address):
        return False
    if not staticcall PegKeeperFactory(factory).is_active(_keeper):
        return False
    return staticcall PegKeeper(_keeper).factory() == factory


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
