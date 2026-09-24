# pragma version 0.4.3
"""
@title PegKeeperPolicy
@license MIT
@notice Reports whether aggregate crvUSD price permits expansion or contraction.
"""


interface PriceOracle:
    def price() -> uint256: view


event AggregateCrvUsdOracleUpdated:
    oldOracle: indexed(address)
    newOracle: indexed(address)


event FeeReceiverUpdated:
    oldFeeReceiver: indexed(address)
    newFeeReceiver: indexed(address)


event OwnershipTransferStarted:
    owner: indexed(address)
    pendingOwner: indexed(address)


event OwnershipTransferred:
    oldOwner: indexed(address)
    newOwner: indexed(address)


PRECISION: constant(uint256) = 10 ** 18

owner: public(address)
pendingOwner: public(address)
ownershipTransferNonce: public(uint256)
aggregateCrvUsdOracle: public(address)
fee_receiver: public(address)


@deploy
def __init__(
    _initial_owner: address,
    _aggregate_crvusd_oracle: address,
    _fee_receiver: address,
):
    if _initial_owner == empty(address):
        raw_revert(method_id("InvalidOwner()"))
    if _aggregate_crvusd_oracle == empty(address) or _aggregate_crvusd_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))
    if _fee_receiver == empty(address):
        raw_revert(method_id("InvalidFeeReceiver()"))

    self.owner = _initial_owner
    self.aggregateCrvUsdOracle = _aggregate_crvusd_oracle
    self.fee_receiver = _fee_receiver
    log OwnershipTransferred(oldOwner=empty(address), newOwner=_initial_owner)
    log AggregateCrvUsdOracleUpdated(
        oldOracle=empty(address), newOracle=_aggregate_crvusd_oracle
    )
    log FeeReceiverUpdated(oldFeeReceiver=empty(address), newFeeReceiver=_fee_receiver)


@external
def set_aggregate_crvusd_oracle(_new_oracle: address):
    self._check_owner()
    if _new_oracle == empty(address) or _new_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))

    old_oracle: address = self.aggregateCrvUsdOracle
    self.aggregateCrvUsdOracle = _new_oracle
    log AggregateCrvUsdOracleUpdated(oldOracle=old_oracle, newOracle=_new_oracle)


@external
def set_fee_receiver(_new_fee_receiver: address):
    self._check_owner()
    if _new_fee_receiver == empty(address):
        raw_revert(method_id("InvalidFeeReceiver()"))

    old_fee_receiver: address = self.fee_receiver
    self.fee_receiver = _new_fee_receiver
    log FeeReceiverUpdated(
        oldFeeReceiver=old_fee_receiver, newFeeReceiver=_new_fee_receiver
    )


@external
@view
def expansion_regime() -> bool:
    return self._aggregate_crvusd_price() >= PRECISION


@external
@view
def can_expand() -> bool:
    return self._aggregate_crvusd_price() >= PRECISION


@external
@view
def can_contract() -> bool:
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
    price: uint256 = staticcall PriceOracle(self.aggregateCrvUsdOracle).price()
    assert price > 0
    return price
