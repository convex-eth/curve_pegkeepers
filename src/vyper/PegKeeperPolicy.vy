# pragma version 0.4.3
"""
@title PegKeeperPolicy
@license MIT
@notice Applies aggregate direction and three-tier expansion priority to one PegKeeperV3 factory.
"""


interface PriceOracle:
    def price() -> uint256: view


interface PegKeeperFactory:
    def owner() -> address: view
    def is_active(_keeper: address) -> bool: view


interface PegKeeper:
    def factory() -> address: view
    def controller_factory() -> address: view
    def max_deployed_crvusd() -> uint256: view
    def debt() -> uint256: view


interface ControllerFactory:
    def debt_ceiling(_keeper: address) -> uint256: view


event FactorySet:
    factory: indexed(address)


event AggregateCrvUsdOracleUpdated:
    oldOracle: indexed(address)
    newOracle: indexed(address)


event PrimaryUtilizationUpdated:
    oldUtilizationBps: uint256
    newUtilizationBps: uint256


event KeeperProfitShareUpdated:
    oldKeeperProfitShareBps: uint256
    newKeeperProfitShareBps: uint256


event TierUpdated:
    pegKeeper: indexed(address)
    oldTier: uint256
    newTier: uint256


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


BPS: constant(uint256) = 10_000
PRECISION: constant(uint256) = 10 ** 18
TIER_NONE: constant(uint256) = 0
TIER_PRIMARY: constant(uint256) = 1
TIER_SECONDARY: constant(uint256) = 2
TIER_TERTIARY: constant(uint256) = 3
MAX_SECONDARIES: constant(uint256) = 256
LOCAL_EXPANDABLE_SELECTOR: constant(Bytes[4]) = method_id("can_expand_without_policy()")

owner: public(address)
pendingOwner: public(address)
ownershipTransferNonce: public(uint256)
factory: public(address)
aggregateCrvUsdOracle: public(address)
primaryUtilizationBps: public(uint256)
_keeperProfitShareBps: uint256
primary: public(address)
tier: public(HashMap[address, uint256])
secondaryCount: public(uint256)
secondaryAt: public(HashMap[uint256, address])
_secondaryIndexPlusOne: HashMap[address, uint256]
tertiaryCount: public(uint256)
tertiaryAt: public(HashMap[uint256, address])
_tertiaryIndexPlusOne: HashMap[address, uint256]


@deploy
def __init__(
    _initial_owner: address,
    _aggregate_crvusd_oracle: address,
    _primary_utilization_bps: uint256,
    _keeper_profit_share_bps: uint256,
):
    if _initial_owner == empty(address):
        raw_revert(method_id("InvalidOwner()"))
    if _aggregate_crvusd_oracle == empty(address) or _aggregate_crvusd_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))
    if _primary_utilization_bps == 0 or _primary_utilization_bps > BPS:
        raw_revert(method_id("InvalidThreshold()"))
    if _keeper_profit_share_bps > BPS:
        raw_revert(method_id("InvalidThreshold()"))

    self.owner = _initial_owner
    self.aggregateCrvUsdOracle = _aggregate_crvusd_oracle
    self.primaryUtilizationBps = _primary_utilization_bps
    self._keeperProfitShareBps = _keeper_profit_share_bps
    log OwnershipTransferred(oldOwner=empty(address), newOwner=_initial_owner)
    log AggregateCrvUsdOracleUpdated(
        oldOracle=empty(address), newOracle=_aggregate_crvusd_oracle
    )
    log PrimaryUtilizationUpdated(
        oldUtilizationBps=0, newUtilizationBps=_primary_utilization_bps
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
def set_primary_utilization_bps(_new_utilization_bps: uint256):
    self._check_owner()
    if _new_utilization_bps == 0 or _new_utilization_bps > BPS:
        raw_revert(method_id("InvalidThreshold()"))

    old_utilization_bps: uint256 = self.primaryUtilizationBps
    self.primaryUtilizationBps = _new_utilization_bps
    log PrimaryUtilizationUpdated(
        oldUtilizationBps=old_utilization_bps,
        newUtilizationBps=_new_utilization_bps,
    )


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
def set_tier(_keeper: address, _new_tier: uint256):
    self._check_owner()
    if _new_tier > TIER_TERTIARY:
        raw_revert(method_id("InvalidTier()"))
    if _keeper == empty(address) or _keeper.codesize == 0:
        raw_revert(method_id("InvalidKeeper()"))
    if _new_tier != TIER_NONE:
        factory: address = self.factory
        if factory == empty(address):
            raw_revert(method_id("InvalidFactory()"))
        if staticcall PegKeeper(_keeper).factory() != factory or not staticcall PegKeeperFactory(factory).is_active(_keeper):
            raw_revert(method_id("InvalidKeeper()"))

    old_tier: uint256 = self.tier[_keeper]
    if old_tier == _new_tier:
        return

    self._remove_from_tier(_keeper, old_tier)
    if _new_tier == TIER_PRIMARY:
        old_primary: address = self.primary
        if old_primary != empty(address):
            self.primary = empty(address)
            self.tier[old_primary] = TIER_NONE
            log TierUpdated(
                pegKeeper=old_primary,
                oldTier=TIER_PRIMARY,
                newTier=TIER_NONE,
            )
        self.primary = _keeper
    elif _new_tier == TIER_SECONDARY:
        if self.secondaryCount >= MAX_SECONDARIES:
            raw_revert(method_id("TooManySecondaries()"))
        secondary_index: uint256 = self.secondaryCount
        self.secondaryAt[secondary_index] = _keeper
        self._secondaryIndexPlusOne[_keeper] = secondary_index + 1
        self.secondaryCount = secondary_index + 1
    elif _new_tier == TIER_TERTIARY:
        tertiary_index: uint256 = self.tertiaryCount
        self.tertiaryAt[tertiary_index] = _keeper
        self._tertiaryIndexPlusOne[_keeper] = tertiary_index + 1
        self.tertiaryCount = tertiary_index + 1

    self.tier[_keeper] = _new_tier
    log TierUpdated(pegKeeper=_keeper, oldTier=old_tier, newTier=_new_tier)


@external
@view
def expansion_regime() -> bool:
    return self._aggregate_crvusd_price() >= PRECISION


@external
@view
def can_allocate(_keeper: address) -> bool:
    return self._can_allocate(_keeper)


@external
@view
def can_expand(_keeper: address) -> bool:
    factory: address = self.factory
    if factory == empty(address):
        return False
    if self._aggregate_crvusd_price() < PRECISION:
        return False
    if not self._can_allocate(_keeper):
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
    if _keeper == empty(address) or not staticcall PegKeeperFactory(factory).is_active(_keeper):
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


@internal
@view
def _can_allocate(_keeper: address) -> bool:
    if not self._is_active_keeper(_keeper):
        return False

    keeper_tier: uint256 = self.tier[_keeper]
    if keeper_tier == TIER_PRIMARY:
        return _keeper == self.primary
    if keeper_tier == TIER_SECONDARY:
        primary: address = self.primary
        if primary == empty(address):
            return True
        if not self._is_locally_expandable(primary):
            return True
        return self._primary_is_saturated(primary)
    if keeper_tier == TIER_TERTIARY:
        primary: address = self.primary
        if primary != empty(address) and self._is_locally_expandable(primary):
            return False
        for index: uint256 in range(256):
            if index >= self.secondaryCount:
                break
            if self._is_locally_expandable(self.secondaryAt[index]):
                return False
        return True
    return False


@internal
@view
def _primary_is_saturated(_primary: address) -> bool:
    local_maximum: uint256 = staticcall PegKeeper(_primary).max_deployed_crvusd()
    controller_factory: address = staticcall PegKeeper(_primary).controller_factory()
    controller_ceiling: uint256 = staticcall ControllerFactory(controller_factory).debt_ceiling(_primary)
    effective_ceiling: uint256 = min(local_maximum, controller_ceiling)
    if effective_ceiling == 0:
        return True

    quotient: uint256 = effective_ceiling // BPS
    remainder: uint256 = effective_ceiling % BPS
    scaled_remainder: uint256 = remainder * self.primaryUtilizationBps
    required_debt: uint256 = (
        quotient * self.primaryUtilizationBps
        + (scaled_remainder + BPS - 1) // BPS
    )
    return staticcall PegKeeper(_primary).debt() >= required_debt


@internal
def _remove_from_tier(_keeper: address, _old_tier: uint256):
    if _old_tier == TIER_PRIMARY:
        if self.primary == _keeper:
            self.primary = empty(address)
    elif _old_tier == TIER_SECONDARY:
        index_plus_one: uint256 = self._secondaryIndexPlusOne[_keeper]
        if index_plus_one != 0:
            index: uint256 = index_plus_one - 1
            last_index: uint256 = self.secondaryCount - 1
            if index != last_index:
                moved: address = self.secondaryAt[last_index]
                self.secondaryAt[index] = moved
                self._secondaryIndexPlusOne[moved] = index + 1
            self.secondaryAt[last_index] = empty(address)
            self._secondaryIndexPlusOne[_keeper] = 0
            self.secondaryCount = last_index
    elif _old_tier == TIER_TERTIARY:
        index_plus_one: uint256 = self._tertiaryIndexPlusOne[_keeper]
        if index_plus_one != 0:
            index: uint256 = index_plus_one - 1
            last_index: uint256 = self.tertiaryCount - 1
            if index != last_index:
                moved: address = self.tertiaryAt[last_index]
                self.tertiaryAt[index] = moved
                self._tertiaryIndexPlusOne[moved] = index + 1
            self.tertiaryAt[last_index] = empty(address)
            self._tertiaryIndexPlusOne[_keeper] = 0
            self.tertiaryCount = last_index
