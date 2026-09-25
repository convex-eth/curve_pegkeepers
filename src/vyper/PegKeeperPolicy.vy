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


event CommitNewAdmin:
    admin: address


event ApplyNewAdmin:
    admin: address


PRECISION: constant(uint256) = 10 ** 18
ADMIN_ACTIONS_DELAY: constant(uint256) = 3 * 86400

admin: public(address)
future_admin: public(address)
new_admin_deadline: public(uint256)
aggregateCrvUsdOracle: public(address)
fee_receiver: public(address)


@deploy
def __init__(
    _admin: address,
    _aggregate_crvusd_oracle: address,
    _fee_receiver: address,
):
    if _admin == empty(address):
        raw_revert(method_id("InvalidAdmin()"))
    if _aggregate_crvusd_oracle == empty(address) or _aggregate_crvusd_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))
    if _fee_receiver == empty(address):
        raw_revert(method_id("InvalidFeeReceiver()"))

    self.admin = _admin
    self.aggregateCrvUsdOracle = _aggregate_crvusd_oracle
    self.fee_receiver = _fee_receiver
    log ApplyNewAdmin(admin=_admin)
    log AggregateCrvUsdOracleUpdated(
        oldOracle=empty(address), newOracle=_aggregate_crvusd_oracle
    )
    log FeeReceiverUpdated(oldFeeReceiver=empty(address), newFeeReceiver=_fee_receiver)


@external
def set_aggregate_crvusd_oracle(_new_oracle: address):
    self._check_admin()
    if _new_oracle == empty(address) or _new_oracle.codesize == 0:
        raw_revert(method_id("InvalidOracle()"))

    old_oracle: address = self.aggregateCrvUsdOracle
    self.aggregateCrvUsdOracle = _new_oracle
    log AggregateCrvUsdOracleUpdated(oldOracle=old_oracle, newOracle=_new_oracle)


@external
def set_fee_receiver(_new_fee_receiver: address):
    self._check_admin()
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
@nonpayable
def commit_new_admin(_new_admin: address):
    """
    @notice Commit new admin of the Policy.
    @dev In order to revert, commit_new_admin(current_admin) may be called.
    @param _new_admin Address of the new admin.
    """
    assert msg.sender == self.admin
    assert _new_admin != empty(address)

    self.new_admin_deadline = block.timestamp + ADMIN_ACTIONS_DELAY
    self.future_admin = _new_admin
    log CommitNewAdmin(admin=_new_admin)


@external
@nonpayable
def apply_new_admin():
    """
    @notice Apply new admin of the Policy.
    @dev Should be executed from new admin.
    """
    new_admin: address = self.future_admin
    new_admin_deadline: uint256 = self.new_admin_deadline
    assert msg.sender == new_admin
    assert block.timestamp >= new_admin_deadline
    assert new_admin_deadline != 0

    self.admin = new_admin
    self.new_admin_deadline = 0
    log ApplyNewAdmin(admin=new_admin)


@internal
@view
def _check_admin():
    assert msg.sender == self.admin


@internal
@view
def _aggregate_crvusd_price() -> uint256:
    price: uint256 = staticcall PriceOracle(self.aggregateCrvUsdOracle).price()
    assert price > 0
    return price
