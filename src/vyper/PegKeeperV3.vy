# pragma version 0.3.10
"""
@title PegKeeper V3
@license MIT
@notice Asymmetric inventory-backed crvUSD PegKeeper
@dev Incremental implementation: core accounting/actions plus bounded typed route execution.
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def approve(_spender: address, _amount: uint256): nonpayable
    def transfer(_recipient: address, _amount: uint256): nonpayable
    def transferFrom(_sender: address, _recipient: address, _amount: uint256): nonpayable

interface ControllerFactory:
    def stablecoin() -> address: view
    def debt_ceiling(_account: address) -> uint256: view

interface PegKeeperFactory:
    def controllerFactory() -> address: view
    def admin() -> address: view
    def emergency_admin() -> address: view
    def fee_receiver() -> address: view

interface TwoCoinPool:
    def coins(_index: uint256) -> address: view
    def get_dy(_i: int128, _j: int128, _dx: uint256) -> uint256: view
    def exchange(_i: int128, _j: int128, _dx: uint256, _min_dy: uint256): nonpayable

interface CurveRoutePool:
    def coins(_index: uint256) -> address: view
    def get_dy(_i: int128, _j: int128, _dx: uint256) -> uint256: view
    def exchange(_i: int128, _j: int128, _dx: uint256, _min_dy: uint256): nonpayable

interface DaiUsds:
    def dai() -> address: view
    def usds() -> address: view
    def daiToUsds(_receiver: address, _amount: uint256): nonpayable
    def usdsToDai(_receiver: address, _amount: uint256): nonpayable

interface ERC4626Route:
    def previewDeposit(_assets: uint256) -> uint256: view
    def deposit(_assets: uint256, _receiver: address) -> uint256: nonpayable
    def previewRedeem(_shares: uint256) -> uint256: view
    def redeem(_shares: uint256, _receiver: address, _owner: address) -> uint256: nonpayable

interface FrxUsdMinter:
    def asset() -> address: view
    def frxUSD() -> address: view
    def previewDeposit(_assets: uint256) -> uint256: view
    def deposit(_assets: uint256, _receiver: address) -> uint256: nonpayable

interface YieldToken:
    def asset() -> address: view
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def convertToAssets(_yield_token_amount: uint256) -> uint256: view
    def convertToShares(_assets: uint256) -> uint256: view

interface PriceOracle:
    def price() -> uint256: view

interface PreviewModule:
    def previewExpansion(_keeper: address, _amount: uint256) -> (uint256, uint256, uint256, uint256, uint256, bool): view
    def previewUndeployedContraction(_keeper: address, _amount: uint256) -> (uint256, uint256, uint256, bool): view
    def previewKeeperBuyback(_keeper: address, _amount: uint256) -> (uint256, uint256, uint256, bool): view


struct RouteStep:
    kind: uint256
    venue: address
    token_in: address
    token_out: address
    pool_index_in: int128
    pool_index_out: int128
    execution_buffer_bps: uint256


event DirectionPaused:
    direction: indexed(uint256)
    paused: bool

event Executed:
    target: indexed(address)
    value: uint256
    selector: indexed(bytes4)
    data_hash: bytes32

event ExpansionConfigUpdated:
    target_amm_execution_buffer_bps: uint256
    min_downstream_attempt_gas: uint256
    fallback_settlement_gas_reserve: uint256

event TargetAmmUpdated:
    old_target_amm: indexed(address)
    new_target_amm: indexed(address)
    crv_usd_index: uint256
    target_index: uint256
    execution_buffer_bps: uint256

event Expanded:
    keeper: indexed(address)
    crv_usd_sold: uint256
    target_received: uint256
    backing_asset_received: uint256
    yield_token_received: uint256
    gross_profit: uint256
    keeper_reward: uint256
    backing_retained: uint256
    deployed_to_yield: bool
    unlock_time: uint256

event KeeperBuyback:
    keeper: indexed(address)
    backing_token: address
    backing_spent: uint256
    yield_token_spent: uint256
    crv_usd_received: uint256
    gross_profit: uint256
    keeper_reward: uint256
    early_exit: bool

event DirectBuyback:
    caller: indexed(address)
    crv_usd_received: uint256
    yield_token_paid: uint256
    early_exit: bool

event SurplusClaimed:
    caller: indexed(address)
    receiver: indexed(address)
    crv_usd_transferred: uint256
    deployed_crv_usd_after: uint256

event PolicyUpdated:
    entry_min_profit_ppm: uint256
    normal_exit_min_profit_ppm: uint256
    early_exit_min_profit_ppm: uint256
    keeper_profit_share_bps: uint256
    min_deployment_time: uint256
    min_expansion_amount: uint256
    max_deployed_crvusd: uint256

event PathsUpdated:
    expansion_path_hash: indexed(bytes32)
    contraction_path_hash: indexed(bytes32)
    expansion_max_route_loss_bps: uint256

event OraclePolicyUpdated:
    target_oracle: indexed(address)
    yield_oracle: indexed(address)
    min_target_price: uint256
    min_yield_price: uint256

event UndeployedBackingDeployed:
    caller: indexed(address)
    target_spent: uint256
    yield_token_received: uint256
    trusted_value_received: uint256
    conversion_cost: uint256


version: public(constant(String[8])) = "3.0.0"
name: public(String[88])
keeper_index: public(uint256)

BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
PRECISION: constant(uint256) = 10 ** 18
DEFAULT_MIN_ORACLE_PRICE: constant(uint256) = 999_700_000_000_000_000
max_expansion_burst_bps: public(constant(uint256)) = 500
expansion_refill_period: public(constant(uint256)) = 5 * 60
MAX_ROUTE_STEPS: public(constant(uint256)) = 16
STEP_CURVE_SWAP: constant(uint256) = 0
STEP_DAI_USDS_CONVERTER: constant(uint256) = 1
STEP_ERC4626_DEPOSIT: constant(uint256) = 2
STEP_ERC4626_REDEEM: constant(uint256) = 3
STEP_FRXUSD_MINT: constant(uint256) = 4

DIRECTION_EXPANSION: constant(uint256) = 0
DIRECTION_BACKING_DEPLOYMENT: constant(uint256) = 1
DIRECTION_DIRECT_BUYBACK: constant(uint256) = 2
DIRECTION_UNDEPLOYED_CONTRACTION: constant(uint256) = 3
DIRECTION_YIELD_CONTRACTION: constant(uint256) = 4
DIRECTION_ALL: constant(uint256) = 5

PREVIEW_MODULE: immutable(PreviewModule)
_factory: PegKeeperFactory
_controller_factory: ControllerFactory
_crv_usd: ERC20
target_amm: public(TwoCoinPool)
_target_asset: ERC20
_backing_asset: ERC20
_yield_token: YieldToken
target_multiplier: uint256
backing_multiplier: uint256
target_oracle: public(PriceOracle)
yield_oracle: public(PriceOracle)
min_target_oracle_price: public(uint256)
min_yield_oracle_price: public(uint256)
initialized: public(bool)

target_amm_crvusd_index: public(uint256)
target_amm_target_index: public(uint256)

entry_min_profit_ppm: public(uint256)
normal_exit_min_profit_ppm: public(uint256)
early_exit_min_profit_ppm: public(uint256)
keeper_profit_share_bps: public(uint256)
min_deployment_time: public(uint256)
min_expansion_amount: public(uint256)
max_deployed_crvusd: public(uint256)
target_amm_execution_buffer_bps: public(uint256)
min_downstream_attempt_gas: public(uint256)
fallback_settlement_gas_reserve: public(uint256)
expansion_path: DynArray[RouteStep, 16]
contraction_path: DynArray[RouteStep, 16]
expansion_max_route_loss_bps: public(uint256)

deployed_crvusd: public(uint256)
undeployed_backing: public(uint256)
accounted_yield_token_units: public(uint256)
last_expansion_at: public(uint256)
_expansion_pressure: uint256
last_expansion_pressure_update: public(uint256)

expansion_paused: public(bool)
backing_deployment_paused: public(bool)
direct_buyback_paused: public(bool)
undeployed_contraction_paused: public(bool)
yield_contraction_paused: public(bool)
all_execution_paused: public(bool)


@external
def __init__(_preview_module: PreviewModule):
    assert _preview_module.address != empty(address)
    assert _preview_module.address.codesize > 0
    PREVIEW_MODULE = _preview_module
    # Lock the standalone implementation. Proxies have independent zeroed storage.
    self.initialized = True
    self.expansion_paused = True
    self.backing_deployment_paused = True
    self.direct_buyback_paused = True
    self.undeployed_contraction_paused = True
    self.yield_contraction_paused = True
    self.all_execution_paused = True


@external
def initialize(
    _target_amm: TwoCoinPool,
    _target_asset: ERC20,
    _backing_asset: ERC20,
    _yield_token: YieldToken,
    _max_deployed_crvusd: uint256,
    _keeper_index: uint256,
    _target_oracle: PriceOracle,
    _yield_oracle: PriceOracle,
):
    assert not self.initialized
    self.initialized = True
    assert msg.sender.codesize > 0
    assert _target_amm.address != empty(address)
    assert _target_asset.address != empty(address)
    assert _backing_asset.address != empty(address)
    assert _yield_token.address != empty(address)
    assert _max_deployed_crvusd > 0
    assert _keeper_index > 0
    assert _target_oracle.address != empty(address)
    assert _yield_oracle.address != empty(address)
    assert _target_oracle.address.codesize > 0
    assert _yield_oracle.address.codesize > 0

    controller_factory: address = PegKeeperFactory(msg.sender).controllerFactory()
    assert controller_factory != empty(address)
    crv_usd: address = ControllerFactory(controller_factory).stablecoin()
    assert crv_usd != empty(address)
    assert crv_usd != _target_asset.address
    assert _yield_token.asset() == _backing_asset.address
    assert _yield_token.convertToAssets(0) == 0
    assert _yield_token.convertToShares(0) == 0

    crv_decimals: uint256 = ERC20(crv_usd).decimals()
    target_decimals: uint256 = _target_asset.decimals()
    backing_decimals: uint256 = _backing_asset.decimals()
    assert crv_decimals == 18
    assert target_decimals <= 18
    assert backing_decimals <= 18

    coin_0: address = _target_amm.coins(0)
    coin_1: address = _target_amm.coins(1)
    if coin_0 == crv_usd and coin_1 == _target_asset.address:
        self.target_amm_crvusd_index = 0
        self.target_amm_target_index = 1
    elif coin_0 == _target_asset.address and coin_1 == crv_usd:
        self.target_amm_crvusd_index = 1
        self.target_amm_target_index = 0
    else:
        raise

    self._factory = PegKeeperFactory(msg.sender)
    self._controller_factory = ControllerFactory(controller_factory)
    self._crv_usd = ERC20(crv_usd)
    self.target_amm = _target_amm
    self._target_asset = _target_asset
    self._backing_asset = _backing_asset
    self._yield_token = _yield_token
    self.target_multiplier = 10 ** (18 - target_decimals)
    self.backing_multiplier = 10 ** (18 - backing_decimals)
    self.target_oracle = _target_oracle
    self.yield_oracle = _yield_oracle
    self.min_target_oracle_price = DEFAULT_MIN_ORACLE_PRICE
    self.min_yield_oracle_price = DEFAULT_MIN_ORACLE_PRICE

    self.keeper_index = _keeper_index
    self.name = concat("Pegkeeper ", uint2str(_keeper_index))
    self.entry_min_profit_ppm = 10
    self.normal_exit_min_profit_ppm = 1_000
    self.early_exit_min_profit_ppm = 5_000
    self.keeper_profit_share_bps = 3_000
    self.min_deployment_time = 2 * 86400
    self.min_expansion_amount = 10_000 * 10 ** 18
    self.max_deployed_crvusd = _max_deployed_crvusd
    self.last_expansion_pressure_update = block.timestamp

    self.expansion_paused = True
    self.backing_deployment_paused = True
    self.direct_buyback_paused = True
    self.undeployed_contraction_paused = True
    self.yield_contraction_paused = True
    self.all_execution_paused = True


@external
@view
def factory() -> address:
    return self._factory.address


@external
@view
def controller_factory() -> address:
    return self._controller_factory.address


@external
@view
def admin() -> address:
    return self._factory.admin()


@external
@view
def emergency_admin() -> address:
    return self._factory.emergency_admin()


@external
@view
def fee_receiver() -> address:
    return self._factory.fee_receiver()


@internal
@view
def _is_admin(_account: address) -> bool:
    return _account == self._factory.admin()


@internal
@view
def _is_admin_or_factory(_account: address) -> bool:
    return _account == self._factory.admin() or _account == self._factory.address


@external
@view
def crv_usd() -> address:
    return self._crv_usd.address


@external
@pure
def preview_module() -> address:
    return PREVIEW_MODULE.address


@external
@view
def target_asset() -> address:
    return self._target_asset.address


@external
@view
def backing_asset() -> address:
    return self._backing_asset.address


@external
@view
def yield_token() -> address:
    return self._yield_token.address


@external
@view
def coins(_index: uint256) -> address:
    if _index == 0:
        return self._crv_usd.address
    assert _index == 1
    return self._yield_token.address


@internal
@pure
def _oracle_value(_value: uint256, _price: uint256) -> uint256:
    price: uint256 = min(_price, PRECISION)
    return _value / PRECISION * price + _value % PRECISION * price / PRECISION


@internal
@view
def _target_price() -> uint256:
    price: uint256 = self.target_oracle.price()
    assert price >= self.min_target_oracle_price
    return price


@internal
@view
def _yield_price() -> (uint256, bool):
    ok: bool = False
    response: Bytes[32] = empty(Bytes[32])
    ok, response = raw_call(
        self.yield_oracle.address,
        method_id("price()"),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        return 0, False
    price: uint256 = convert(response, uint256)
    return price, price >= self.min_yield_oracle_price


@internal
@view
def _max_burst() -> uint256:
    cap: uint256 = self.max_deployed_crvusd
    return cap / BPS * max_expansion_burst_bps + cap % BPS * max_expansion_burst_bps / BPS


@internal
@view
def _current_pressure() -> uint256:
    pressure: uint256 = self._expansion_pressure
    if pressure == 0:
        return 0
    elapsed: uint256 = block.timestamp - self.last_expansion_pressure_update
    if elapsed >= expansion_refill_period:
        return 0
    burst: uint256 = self._max_burst()
    refill: uint256 = burst / expansion_refill_period * elapsed + burst % expansion_refill_period * elapsed / expansion_refill_period
    if refill >= pressure:
        return 0
    return pressure - refill


@internal
@view
def _available_velocity() -> uint256:
    burst: uint256 = self._max_burst()
    pressure: uint256 = self._current_pressure()
    if pressure >= burst:
        return 0
    return burst - pressure


@internal
def _consume_velocity(_amount: uint256):
    pressure: uint256 = self._current_pressure()
    burst: uint256 = self._max_burst()
    assert pressure < burst and _amount <= burst - pressure
    self._expansion_pressure = pressure + _amount
    self.last_expansion_pressure_update = block.timestamp


@external
@view
def expansion_pressure() -> uint256:
    return self._current_pressure()


@external
@view
def available_expansion_velocity() -> uint256:
    return self._available_velocity()


@internal
@view
def _normalize_target(_amount: uint256) -> uint256:
    return _amount * self.target_multiplier


@internal
@view
def _meets_entry_floor(_retained_value: uint256, _principal: uint256) -> bool:
    required_profit: uint256 = _principal * self.entry_min_profit_ppm / PPM
    return _retained_value >= _principal + required_profit


@internal
@view
def _normalize_backing(_amount: uint256) -> uint256:
    return _amount * self.backing_multiplier


@internal
@view
def _trusted_backing_value() -> uint256:
    target_value: uint256 = self._normalize_target(self.undeployed_backing)
    backing_amount: uint256 = self._yield_token.convertToAssets(self.accounted_yield_token_units)
    return target_value + self._normalize_backing(backing_amount)


@internal
@view
def _oracle_backing_value() -> uint256:
    value: uint256 = 0
    if self.undeployed_backing > 0:
        value = self._oracle_value(
            self._normalize_target(self.undeployed_backing), self._target_price()
        )
    if self.accounted_yield_token_units > 0:
        price: uint256 = 0
        healthy: bool = False
        price, healthy = self._yield_price()
        assert healthy
        value += self._oracle_value(
            self._trusted_yield_value(self.accounted_yield_token_units), price
        )
    return value


@internal
@view
def _trusted_yield_value(_yield_token_units: uint256) -> uint256:
    return self._normalize_backing(self._yield_token.convertToAssets(_yield_token_units))


@external
@view
def trusted_backing_value() -> uint256:
    return self._trusted_backing_value()


@external
@view
def protocol_surplus() -> uint256:
    trusted_value: uint256 = self._trusted_backing_value()
    if trusted_value > self.deployed_crvusd:
        return trusted_value - self.deployed_crvusd
    return 0


@external
@view
def debt() -> uint256:
    return self.deployed_crvusd


@external
@view
def available_expansion() -> uint256:
    available: uint256 = min(self._crv_usd.balanceOf(self), self._available_velocity())

    if self.max_deployed_crvusd <= self.deployed_crvusd:
        return 0
    remaining_capacity: uint256 = self.max_deployed_crvusd - self.deployed_crvusd
    if remaining_capacity < available:
        available = remaining_capacity

    factory_allocation: uint256 = self._controller_factory.debt_ceiling(self)
    if factory_allocation <= self.deployed_crvusd:
        return 0
    remaining_allocation: uint256 = factory_allocation - self.deployed_crvusd
    if remaining_allocation < available:
        available = remaining_allocation

    return available


@internal
@view
def _is_early_exit() -> bool:
    return self.deployed_crvusd > 0 and block.timestamp < self.last_expansion_at + self.min_deployment_time


@internal
@view
def _realized_contraction_profit(
    _crv_usd_received: uint256,
    _trusted_value_removed: uint256,
    _trusted_backing_after: uint256,
) -> uint256:
    principal_recovery: uint256 = _trusted_value_removed
    if self.deployed_crvusd > _trusted_backing_after:
        solvency_recovery: uint256 = self.deployed_crvusd - _trusted_backing_after
        if solvency_recovery > principal_recovery:
            principal_recovery = solvency_recovery

    if _crv_usd_received <= principal_recovery:
        return 0
    return _crv_usd_received - principal_recovery


@internal
@view
def _preview_buyback(_crv_usd_amount: uint256) -> (uint256, uint256, bool):
    assert _crv_usd_amount > 0
    deployed_before: uint256 = self.deployed_crvusd
    assert _crv_usd_amount <= deployed_before

    accounted_before: uint256 = self.accounted_yield_token_units
    assert self._yield_token.balanceOf(self) >= accounted_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm

    denominator: uint256 = PPM + exit_margin_ppm
    payout_budget: uint256 = (
        _crv_usd_amount / denominator * PPM
        + (_crv_usd_amount % denominator) * PPM / denominator
    )
    payout_assets: uint256 = payout_budget / self.backing_multiplier
    assert payout_assets > 1

    yield_token_out: uint256 = self._yield_token.convertToShares(payout_assets - 1)
    assert yield_token_out > 0
    assert yield_token_out <= accounted_before

    trusted_before: uint256 = self._trusted_yield_value(accounted_before)
    trusted_after: uint256 = self._trusted_yield_value(accounted_before - yield_token_out)
    assert trusted_before >= trusted_after
    trusted_value_removed: uint256 = trusted_before - trusted_after
    required_exit_profit: uint256 = (
        trusted_value_removed / PPM * exit_margin_ppm
        + (trusted_value_removed % PPM) * exit_margin_ppm / PPM
    )
    assert _crv_usd_amount >= trusted_value_removed
    assert _crv_usd_amount - trusted_value_removed >= required_exit_profit

    trusted_total_before: uint256 = self._trusted_backing_value()
    assert trusted_total_before >= trusted_value_removed
    assert (
        trusted_total_before - trusted_value_removed
        >= deployed_before - _crv_usd_amount
    )

    return yield_token_out, required_exit_profit, early_exit


@external
@view
def previewBuyback(_crv_usd_amount: uint256) -> (uint256, uint256, bool):
    return self._preview_buyback(_crv_usd_amount)


@external
@nonreentrant("lock")
def buyback(_crv_usd_amount: uint256, _min_yield_token_out: uint256) -> uint256:
    assert not self.all_execution_paused
    assert not self.direct_buyback_paused

    expected_yield_token_out: uint256 = 0
    ignored_exit_profit: uint256 = 0
    early_exit: bool = False
    expected_yield_token_out, ignored_exit_profit, early_exit = self._preview_buyback(_crv_usd_amount)
    assert expected_yield_token_out >= _min_yield_token_out

    accounted_before: uint256 = self.accounted_yield_token_units
    deployed_before: uint256 = self.deployed_crvusd
    trusted_yield_before: uint256 = self._trusted_yield_value(accounted_before)
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    caller_crv_usd_before: uint256 = self._crv_usd.balanceOf(msg.sender)
    yield_token_before: uint256 = self._yield_token.balanceOf(self)
    caller_yield_before: uint256 = self._yield_token.balanceOf(msg.sender)

    self._crv_usd.transferFrom(msg.sender, self, _crv_usd_amount)
    crv_usd_after: uint256 = self._crv_usd.balanceOf(self)
    caller_crv_usd_after: uint256 = self._crv_usd.balanceOf(msg.sender)
    assert crv_usd_after >= crv_usd_before
    crv_usd_received: uint256 = crv_usd_after - crv_usd_before
    assert crv_usd_received == _crv_usd_amount
    assert caller_crv_usd_before >= caller_crv_usd_after
    assert caller_crv_usd_before - caller_crv_usd_after == _crv_usd_amount

    ERC20(self._yield_token.address).transfer(msg.sender, expected_yield_token_out)
    yield_token_after: uint256 = self._yield_token.balanceOf(self)
    caller_yield_after: uint256 = self._yield_token.balanceOf(msg.sender)
    assert yield_token_before >= yield_token_after
    yield_token_spent: uint256 = yield_token_before - yield_token_after
    assert yield_token_spent == expected_yield_token_out
    assert caller_yield_after >= caller_yield_before
    yield_token_received: uint256 = caller_yield_after - caller_yield_before
    assert yield_token_received == expected_yield_token_out
    assert yield_token_received >= _min_yield_token_out

    accounted_after: uint256 = accounted_before - yield_token_spent
    trusted_yield_after: uint256 = self._trusted_yield_value(accounted_after)
    assert trusted_yield_before >= trusted_yield_after
    trusted_value_removed: uint256 = trusted_yield_before - trusted_yield_after

    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    required_exit_profit: uint256 = (
        trusted_value_removed / PPM * exit_margin_ppm
        + (trusted_value_removed % PPM) * exit_margin_ppm / PPM
    )
    assert crv_usd_received >= trusted_value_removed
    assert crv_usd_received - trusted_value_removed >= required_exit_profit

    deployed_after: uint256 = deployed_before - crv_usd_received
    self.accounted_yield_token_units = accounted_after
    self.deployed_crvusd = deployed_after
    assert self._trusted_backing_value() >= deployed_after

    log DirectBuyback(msg.sender, crv_usd_received, yield_token_received, early_exit)
    return yield_token_received


@external
@view
def previewUndeployedContraction(_amount: uint256) -> (uint256, uint256, uint256, bool):
    return PREVIEW_MODULE.previewUndeployedContraction(self, _amount)


@external
@view
def previewKeeperBuyback(_amount: uint256) -> (uint256, uint256, uint256, bool):
    return PREVIEW_MODULE.previewKeeperBuyback(self, _amount)


@external
@view
def previewExpansion(_amount: uint256) -> (uint256, uint256, uint256, uint256, uint256, bool):
    return PREVIEW_MODULE.previewExpansion(self, _amount)


@external
def set_target_amm(_new_target_amm: TwoCoinPool, _execution_buffer_bps: uint256):
    assert self._is_admin(msg.sender)
    assert _new_target_amm.address != empty(address)
    assert _execution_buffer_bps <= BPS

    coin_0: address = _new_target_amm.coins(0)
    coin_1: address = _new_target_amm.coins(1)
    crv_usd_index: uint256 = 0
    target_index: uint256 = 0
    if coin_0 == self._crv_usd.address and coin_1 == self._target_asset.address:
        crv_usd_index = 0
        target_index = 1
    elif coin_0 == self._target_asset.address and coin_1 == self._crv_usd.address:
        crv_usd_index = 1
        target_index = 0
    else:
        raise

    old_target_amm: address = self.target_amm.address
    self.target_amm = _new_target_amm
    self.target_amm_crvusd_index = crv_usd_index
    self.target_amm_target_index = target_index
    self.target_amm_execution_buffer_bps = _execution_buffer_bps
    log TargetAmmUpdated(
        old_target_amm,
        _new_target_amm.address,
        crv_usd_index,
        target_index,
        _execution_buffer_bps,
    )


@external
def set_oracles(
    _target_oracle: PriceOracle,
    _yield_oracle: PriceOracle,
    _min_target_price: uint256,
    _min_yield_price: uint256,
):
    assert self._is_admin(msg.sender)
    assert _target_oracle.address != empty(address)
    assert _yield_oracle.address != empty(address)
    assert _target_oracle.address.codesize > 0
    assert _yield_oracle.address.codesize > 0
    assert _min_target_price > 0 and _min_target_price <= PRECISION
    assert _min_yield_price > 0 and _min_yield_price <= PRECISION

    self.target_oracle = _target_oracle
    self.yield_oracle = _yield_oracle
    self.min_target_oracle_price = _min_target_price
    self.min_yield_oracle_price = _min_yield_price
    log OraclePolicyUpdated(
        _target_oracle.address,
        _yield_oracle.address,
        _min_target_price,
        _min_yield_price,
    )


@external
def set_expansion_config(
    _target_amm_execution_buffer_bps: uint256,
    _min_downstream_attempt_gas: uint256,
    _fallback_settlement_gas_reserve: uint256,
):
    assert self._is_admin_or_factory(msg.sender)
    assert _target_amm_execution_buffer_bps <= BPS
    assert _fallback_settlement_gas_reserve > 0
    assert _min_downstream_attempt_gas > _fallback_settlement_gas_reserve

    self.target_amm_execution_buffer_bps = _target_amm_execution_buffer_bps
    self.min_downstream_attempt_gas = _min_downstream_attempt_gas
    self.fallback_settlement_gas_reserve = _fallback_settlement_gas_reserve

    log ExpansionConfigUpdated(
        _target_amm_execution_buffer_bps,
        _min_downstream_attempt_gas,
        _fallback_settlement_gas_reserve,
    )


@external
@nonreentrant("lock")
def expand(_crv_usd_amount: uint256) -> (uint256, uint256, uint256, uint256, bool):
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _crv_usd_amount >= self.min_expansion_amount
    target_price: uint256 = self._target_price()

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    assert _crv_usd_amount <= crv_usd_before

    deployed_after: uint256 = self.deployed_crvusd + _crv_usd_amount
    assert deployed_after <= self.max_deployed_crvusd
    assert deployed_after <= self._controller_factory.debt_ceiling(self)
    self._consume_velocity(_crv_usd_amount)

    crv_usd_index: int128 = convert(self.target_amm_crvusd_index, int128)
    target_index: int128 = convert(self.target_amm_target_index, int128)
    target_quote: uint256 = self.target_amm.get_dy(
        crv_usd_index,
        target_index,
        _crv_usd_amount,
    )
    target_minimum: uint256 = target_quote * (
        BPS - self.target_amm_execution_buffer_bps
    ) / BPS

    target_before: uint256 = self._target_asset.balanceOf(self)
    self._crv_usd.approve(self.target_amm.address, _crv_usd_amount)
    self.target_amm.exchange(
        crv_usd_index,
        target_index,
        _crv_usd_amount,
        target_minimum,
    )
    self._crv_usd.approve(self.target_amm.address, 0)

    crv_usd_after: uint256 = self._crv_usd.balanceOf(self)
    assert crv_usd_before >= crv_usd_after
    crv_usd_sold: uint256 = crv_usd_before - crv_usd_after
    assert crv_usd_sold == _crv_usd_amount

    target_after_swap: uint256 = self._target_asset.balanceOf(self)
    assert target_after_swap >= target_before
    target_received: uint256 = target_after_swap - target_before
    assert target_received >= target_minimum

    downstream_succeeded: bool = False
    downstream_response: Bytes[128] = empty(Bytes[128])
    yield_balance_before_attempt: uint256 = self._yield_token.balanceOf(self)
    if len(self.expansion_path) > 0:
        available_attempt_gas: uint256 = msg.gas
        assert available_attempt_gas >= self.min_downstream_attempt_gas
        forwarded_gas: uint256 = available_attempt_gas - self.fallback_settlement_gas_reserve
        downstream_succeeded, downstream_response = raw_call(
            self,
            _abi_encode(
                target_received,
                crv_usd_sold,
                msg.sender,
                method_id=method_id("executeExpansionPath(uint256,uint256,address)"),
            ),
            gas=forwarded_gas,
            max_outsize=128,
            revert_on_failure=False,
        )

    if downstream_succeeded:
        backing_asset_received: uint256 = 0
        yield_token_received: uint256 = 0
        gross_profit: uint256 = 0
        keeper_reward: uint256 = 0
        backing_asset_received, yield_token_received, gross_profit, keeper_reward = _abi_decode(
            downstream_response,
            (uint256, uint256, uint256, uint256),
        )

        target_after_attempt: uint256 = self._target_asset.balanceOf(self)
        assert target_after_swap >= target_after_attempt
        assert target_after_swap - target_after_attempt == target_received
        assert target_after_attempt == target_before
        yield_balance_after: uint256 = self._yield_token.balanceOf(self)
        assert yield_balance_after >= yield_balance_before_attempt
        assert yield_token_received > 0
        assert yield_balance_after - yield_balance_before_attempt == yield_token_received

        self.accounted_yield_token_units += yield_token_received
        self.deployed_crvusd = deployed_after
        self.last_expansion_at = block.timestamp
        assert self._yield_token.balanceOf(self) >= self.accounted_yield_token_units
        assert self._trusted_backing_value() >= self.deployed_crvusd

        log Expanded(
            msg.sender,
            crv_usd_sold,
            target_received,
            backing_asset_received,
            yield_token_received,
            gross_profit,
            keeper_reward,
            0,
            True,
            block.timestamp + self.min_deployment_time,
        )
        return crv_usd_sold, 0, yield_token_received, keeper_reward, True

    target_value: uint256 = self._oracle_value(
        self._normalize_target(target_received), target_price
    )
    gross_profit: uint256 = 0
    if target_value > crv_usd_sold:
        gross_profit = target_value - crv_usd_sold

    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward: uint256 = keeper_reward_value / self.target_multiplier

    if keeper_reward > 0:
        keeper_balance_before: uint256 = self._target_asset.balanceOf(msg.sender)
        self._target_asset.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = self._target_asset.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before
        assert keeper_balance_after - keeper_balance_before == keeper_reward

    target_after_reward: uint256 = self._target_asset.balanceOf(self)
    assert target_after_swap >= target_after_reward
    assert target_after_swap - target_after_reward == keeper_reward
    assert target_after_reward >= target_before
    target_retained: uint256 = target_after_reward - target_before

    assert self._meets_entry_floor(
        self._oracle_value(self._normalize_target(target_retained), target_price), crv_usd_sold
    )

    self.undeployed_backing += target_retained
    self.deployed_crvusd = deployed_after
    self.last_expansion_at = block.timestamp

    assert self._target_asset.balanceOf(self) >= self.undeployed_backing
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log Expanded(
        msg.sender,
        crv_usd_sold,
        target_received,
        0,
        0,
        gross_profit,
        keeper_reward,
        target_retained,
        False,
        block.timestamp + self.min_deployment_time,
    )

    return crv_usd_sold, target_retained, 0, keeper_reward, False


@external
@nonreentrant("lock")
def contractUndeployedBacking(_target_amount: uint256) -> (uint256, uint256, uint256):
    assert not self.all_execution_paused
    assert not self.undeployed_contraction_paused
    assert _target_amount > 0
    assert _target_amount <= self.undeployed_backing

    target_before: uint256 = self._target_asset.balanceOf(self)
    assert target_before >= self.undeployed_backing

    target_index: int128 = convert(self.target_amm_target_index, int128)
    crv_usd_index: int128 = convert(self.target_amm_crvusd_index, int128)
    crv_usd_quote: uint256 = self.target_amm.get_dy(
        target_index,
        crv_usd_index,
        _target_amount,
    )
    crv_usd_minimum: uint256 = crv_usd_quote * (
        BPS - self.target_amm_execution_buffer_bps
    ) / BPS

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    self._target_asset.approve(self.target_amm.address, _target_amount)
    self.target_amm.exchange(
        target_index,
        crv_usd_index,
        _target_amount,
        crv_usd_minimum,
    )
    self._target_asset.approve(self.target_amm.address, 0)

    target_after: uint256 = self._target_asset.balanceOf(self)
    assert target_before >= target_after
    target_spent: uint256 = target_before - target_after
    assert target_spent == _target_amount

    crv_usd_after_swap: uint256 = self._crv_usd.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_before
    crv_usd_received: uint256 = crv_usd_after_swap - crv_usd_before
    assert crv_usd_received >= crv_usd_minimum

    target_value: uint256 = self._normalize_target(target_spent)
    trusted_backing_after: uint256 = self._trusted_backing_value() - target_value
    gross_profit: uint256 = self._realized_contraction_profit(
        crv_usd_received,
        target_value,
        trusted_backing_after,
    )
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS

    if keeper_reward > 0:
        keeper_balance_before: uint256 = self._crv_usd.balanceOf(msg.sender)
        self._crv_usd.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = self._crv_usd.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before
        assert keeper_balance_after - keeper_balance_before == keeper_reward

    crv_usd_after_reward: uint256 = self._crv_usd.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_after_reward
    assert crv_usd_after_swap - crv_usd_after_reward == keeper_reward
    assert crv_usd_after_reward >= crv_usd_before
    net_crv_usd: uint256 = crv_usd_after_reward - crv_usd_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    exit_margin: uint256 = target_value * exit_margin_ppm / PPM
    assert net_crv_usd >= target_value + exit_margin

    self.undeployed_backing -= target_spent
    exposure_reduction: uint256 = net_crv_usd
    if exposure_reduction > self.deployed_crvusd:
        exposure_reduction = self.deployed_crvusd
    self.deployed_crvusd -= exposure_reduction

    assert self._target_asset.balanceOf(self) >= self.undeployed_backing
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log KeeperBuyback(
        msg.sender,
        self._target_asset.address,
        target_spent,
        0,
        crv_usd_received,
        gross_profit,
        keeper_reward,
        early_exit,
    )

    return target_spent, crv_usd_received, keeper_reward


@external
@nonreentrant("lock")
def claimSurplus(_max_crv_usd_amount: uint256) -> uint256:
    assert not self.all_execution_paused
    assert not self.expansion_paused

    trusted_backing: uint256 = self._oracle_backing_value()
    surplus: uint256 = 0
    if trusted_backing > self.deployed_crvusd:
        surplus = trusted_backing - self.deployed_crvusd

    crv_usd_balance_before: uint256 = self._crv_usd.balanceOf(self)
    allocation: uint256 = self._controller_factory.debt_ceiling(self)
    allocation_remaining: uint256 = 0
    if allocation > self.deployed_crvusd:
        allocation_remaining = allocation - self.deployed_crvusd

    local_capacity_remaining: uint256 = 0
    if self.max_deployed_crvusd > self.deployed_crvusd:
        local_capacity_remaining = self.max_deployed_crvusd - self.deployed_crvusd

    crv_usd_transferred: uint256 = _max_crv_usd_amount
    if crv_usd_transferred > surplus:
        crv_usd_transferred = surplus
    if crv_usd_transferred > crv_usd_balance_before:
        crv_usd_transferred = crv_usd_balance_before
    if crv_usd_transferred > allocation_remaining:
        crv_usd_transferred = allocation_remaining
    if crv_usd_transferred > local_capacity_remaining:
        crv_usd_transferred = local_capacity_remaining
    crv_usd_transferred = min(crv_usd_transferred, self._available_velocity())
    assert crv_usd_transferred > 0
    self._consume_velocity(crv_usd_transferred)

    deployed_crv_usd_after: uint256 = self.deployed_crvusd + crv_usd_transferred
    self.deployed_crvusd = deployed_crv_usd_after

    fee_receiver: address = self._factory.fee_receiver()
    receiver_balance_before: uint256 = self._crv_usd.balanceOf(fee_receiver)
    self._crv_usd.transfer(fee_receiver, crv_usd_transferred)
    crv_usd_balance_after: uint256 = self._crv_usd.balanceOf(self)
    receiver_balance_after: uint256 = self._crv_usd.balanceOf(fee_receiver)
    assert crv_usd_balance_before >= crv_usd_balance_after
    assert crv_usd_balance_before - crv_usd_balance_after == crv_usd_transferred
    assert receiver_balance_after >= receiver_balance_before
    assert receiver_balance_after - receiver_balance_before == crv_usd_transferred

    assert deployed_crv_usd_after <= allocation
    assert deployed_crv_usd_after <= self.max_deployed_crvusd
    assert self._trusted_backing_value() >= deployed_crv_usd_after

    log SurplusClaimed(
        msg.sender,
        fee_receiver,
        crv_usd_transferred,
        deployed_crv_usd_after,
    )
    return crv_usd_transferred


@internal
@view
def _validate_route_step(_step: RouteStep):
    assert _step.venue != empty(address)
    assert _step.token_in != empty(address)
    assert _step.token_out != empty(address)
    assert _step.execution_buffer_bps <= BPS

    if _step.kind == STEP_CURVE_SWAP:
        assert _step.pool_index_in >= 0 and _step.pool_index_out >= 0
        assert _step.pool_index_in != _step.pool_index_out
        assert CurveRoutePool(_step.venue).coins(
            convert(_step.pool_index_in, uint256)
        ) == _step.token_in
        assert CurveRoutePool(_step.venue).coins(
            convert(_step.pool_index_out, uint256)
        ) == _step.token_out
    elif _step.kind == STEP_DAI_USDS_CONVERTER:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0
        assert _step.execution_buffer_bps == 0
        dai: address = DaiUsds(_step.venue).dai()
        usds: address = DaiUsds(_step.venue).usds()
        valid_direction: bool = (
            _step.token_in == dai and _step.token_out == usds
        ) or (
            _step.token_in == usds and _step.token_out == dai
        )
        assert valid_direction
    elif _step.kind == STEP_ERC4626_DEPOSIT:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0
        assert _step.venue == _step.token_out
        assert YieldToken(_step.venue).asset() == _step.token_in
    elif _step.kind == STEP_ERC4626_REDEEM:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0
        assert _step.venue == _step.token_in
        assert YieldToken(_step.venue).asset() == _step.token_out
    elif _step.kind == STEP_FRXUSD_MINT:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0
        assert FrxUsdMinter(_step.venue).asset() == _step.token_in
        assert FrxUsdMinter(_step.venue).frxUSD() == _step.token_out
    else:
        raise


@internal
@view
def _validate_route_continuity(_steps: DynArray[RouteStep, 16]):
    for i in range(MAX_ROUTE_STEPS):
        if i >= len(_steps):
            break
        if i > 0:
            assert _steps[i - 1].token_out == _steps[i].token_in
        self._validate_route_step(_steps[i])


@external
def setPaths(
    _expansion_steps: DynArray[RouteStep, 16],
    _expansion_max_route_loss_bps: uint256,
    _contraction_steps: DynArray[RouteStep, 16],
):
    assert self._is_admin_or_factory(msg.sender)
    assert len(_expansion_steps) > 0
    assert len(_contraction_steps) > 0
    assert _expansion_max_route_loss_bps <= BPS

    assert _expansion_steps[0].token_in == self._target_asset.address
    expansion_last: RouteStep = _expansion_steps[len(_expansion_steps) - 1]
    assert expansion_last.token_out == self._yield_token.address
    assert expansion_last.token_in == self._backing_asset.address

    assert _contraction_steps[0].token_in == self._yield_token.address
    assert _contraction_steps[0].token_out == self._backing_asset.address
    contraction_last: RouteStep = _contraction_steps[len(_contraction_steps) - 1]
    assert contraction_last.token_out == self._crv_usd.address

    self._validate_route_continuity(_expansion_steps)
    self._validate_route_continuity(_contraction_steps)

    self.expansion_path = _expansion_steps
    self.contraction_path = _contraction_steps
    self.expansion_max_route_loss_bps = _expansion_max_route_loss_bps
    log PathsUpdated(
        keccak256(_abi_encode(_expansion_steps)),
        keccak256(_abi_encode(_contraction_steps)),
        _expansion_max_route_loss_bps,
    )


@external
@view
def expansion_path_length() -> uint256:
    return len(self.expansion_path)


@external
@view
def contraction_path_length() -> uint256:
    return len(self.contraction_path)


@external
@view
def expansion_path_step(_index: uint256) -> RouteStep:
    assert _index < len(self.expansion_path)
    return self.expansion_path[_index]


@external
@view
def contraction_path_step(_index: uint256) -> RouteStep:
    assert _index < len(self.contraction_path)
    return self.contraction_path[_index]


@internal
def _execute_route_step(_step: RouteStep, _amount_in: uint256) -> uint256:
    token_in: ERC20 = ERC20(_step.token_in)
    token_out: ERC20 = ERC20(_step.token_out)
    input_balance_before: uint256 = token_in.balanceOf(self)
    output_balance_before: uint256 = token_out.balanceOf(self)
    quoted_output: uint256 = 0
    minimum_output: uint256 = 0

    token_in.approve(_step.venue, 0)
    token_in.approve(_step.venue, _amount_in)

    if _step.kind == STEP_CURVE_SWAP:
        quoted_output = CurveRoutePool(_step.venue).get_dy(
            _step.pool_index_in,
            _step.pool_index_out,
            _amount_in,
        )
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        CurveRoutePool(_step.venue).exchange(
            _step.pool_index_in,
            _step.pool_index_out,
            _amount_in,
            minimum_output,
        )
    elif _step.kind == STEP_DAI_USDS_CONVERTER:
        minimum_output = _amount_in
        if _step.token_in == DaiUsds(_step.venue).dai():
            DaiUsds(_step.venue).daiToUsds(self, _amount_in)
        else:
            DaiUsds(_step.venue).usdsToDai(self, _amount_in)
    elif _step.kind == STEP_ERC4626_DEPOSIT:
        quoted_output = ERC4626Route(_step.venue).previewDeposit(_amount_in)
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        ERC4626Route(_step.venue).deposit(_amount_in, self)
    elif _step.kind == STEP_FRXUSD_MINT:
        quoted_output = FrxUsdMinter(_step.venue).previewDeposit(_amount_in)
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        FrxUsdMinter(_step.venue).deposit(_amount_in, self)
    else:
        quoted_output = ERC4626Route(_step.venue).previewRedeem(_amount_in)
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        ERC4626Route(_step.venue).redeem(_amount_in, self, self)

    token_in.approve(_step.venue, 0)
    input_balance_after: uint256 = token_in.balanceOf(self)
    output_balance_after: uint256 = token_out.balanceOf(self)
    assert input_balance_before >= input_balance_after
    assert input_balance_before - input_balance_after == _amount_in
    assert output_balance_after >= output_balance_before
    amount_out: uint256 = output_balance_after - output_balance_before
    if _step.kind == STEP_DAI_USDS_CONVERTER:
        assert amount_out == minimum_output
    else:
        assert amount_out >= minimum_output
    return amount_out


@internal
def _execute_route(_initial_amount: uint256, _expansion: bool) -> uint256:
    amount_in: uint256 = _initial_amount
    path_length: uint256 = len(self.contraction_path)
    if _expansion:
        path_length = len(self.expansion_path)
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        step: RouteStep = empty(RouteStep)
        if _expansion:
            step = self.expansion_path[i]
        else:
            step = self.contraction_path[i]
        amount_in = self._execute_route_step(step, amount_in)
    return amount_in


@external
def executeExpansionPath(
    _target_amount: uint256,
    _crv_usd_sold: uint256,
    _keeper: address,
) -> (uint256, uint256, uint256, uint256):
    assert msg.sender == self
    assert len(self.expansion_path) > 0
    yield_price: uint256 = 0
    healthy: bool = False
    yield_price, healthy = self._yield_price()
    assert healthy

    amount_in: uint256 = _target_amount
    backing_asset_received: uint256 = 0
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    path_length: uint256 = len(self.expansion_path)
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        step: RouteStep = self.expansion_path[i]
        if i == path_length - 1:
            backing_asset_received = amount_in
            backing_value: uint256 = self._oracle_value(
                backing_asset_received * self.backing_multiplier, yield_price
            )
            if backing_value > _crv_usd_sold:
                gross_profit = backing_value - _crv_usd_sold
            keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
            keeper_reward = keeper_reward_value / self.backing_multiplier
            assert keeper_reward <= backing_asset_received
            if keeper_reward > 0:
                keeper_balance_before: uint256 = self._backing_asset.balanceOf(_keeper)
                self._backing_asset.transfer(_keeper, keeper_reward)
                keeper_balance_after: uint256 = self._backing_asset.balanceOf(_keeper)
                assert keeper_balance_after >= keeper_balance_before
                assert keeper_balance_after - keeper_balance_before == keeper_reward
            amount_in = backing_asset_received - keeper_reward
        amount_in = self._execute_route_step(step, amount_in)

    yield_token_received: uint256 = amount_in
    assert yield_token_received > 0
    trusted_yield_received: uint256 = self._oracle_value(
        self._yield_token.convertToAssets(yield_token_received) * self.backing_multiplier,
        yield_price,
    )
    target_price: uint256 = self._target_price()
    target_value: uint256 = self._oracle_value(
        _target_amount * self.target_multiplier, target_price
    )
    route_retained_value: uint256 = (
        trusted_yield_received
        + self._oracle_value(keeper_reward * self.backing_multiplier, yield_price)
    )
    conversion_cost: uint256 = 0
    if target_value > route_retained_value:
        conversion_cost = target_value - route_retained_value
    assert conversion_cost <= (
        target_value * self.expansion_max_route_loss_bps / BPS
    )
    assert self._meets_entry_floor(trusted_yield_received, _crv_usd_sold)
    return backing_asset_received, yield_token_received, gross_profit, keeper_reward


@external
@nonreentrant("lock")
def deployUndeployedBacking(_target_amount: uint256) -> (uint256, uint256):
    assert not self.all_execution_paused
    assert not self.backing_deployment_paused
    assert _target_amount > 0
    assert _target_amount <= self.undeployed_backing
    assert len(self.expansion_path) > 0
    yield_price: uint256 = 0
    healthy: bool = False
    yield_price, healthy = self._yield_price()
    assert healthy

    trusted_backing_before: uint256 = self._trusted_backing_value()
    available_deployment_surplus: uint256 = 0
    if trusted_backing_before > self.deployed_crvusd:
        available_deployment_surplus = trusted_backing_before - self.deployed_crvusd

    target_balance_before: uint256 = self._target_asset.balanceOf(self)
    yield_balance_before: uint256 = self._yield_token.balanceOf(self)
    assert target_balance_before >= self.undeployed_backing

    self._execute_route(_target_amount, True)

    target_balance_after: uint256 = self._target_asset.balanceOf(self)
    yield_balance_after: uint256 = self._yield_token.balanceOf(self)
    assert target_balance_before >= target_balance_after
    target_spent: uint256 = target_balance_before - target_balance_after
    assert target_spent == _target_amount
    assert yield_balance_after >= yield_balance_before
    yield_token_received: uint256 = yield_balance_after - yield_balance_before
    assert yield_token_received > 0

    target_value_spent: uint256 = target_spent * self.target_multiplier
    trusted_value_received: uint256 = self._oracle_value(
        self._yield_token.convertToAssets(yield_token_received) * self.backing_multiplier,
        yield_price,
    )
    conversion_cost: uint256 = 0
    if target_value_spent > trusted_value_received:
        conversion_cost = target_value_spent - trusted_value_received
    assert conversion_cost <= (
        target_value_spent * self.expansion_max_route_loss_bps / BPS
    )
    assert conversion_cost <= available_deployment_surplus

    self.undeployed_backing -= target_spent
    self.accounted_yield_token_units += yield_token_received
    assert self._target_asset.balanceOf(self) >= self.undeployed_backing
    assert self._yield_token.balanceOf(self) >= self.accounted_yield_token_units
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log UndeployedBackingDeployed(
        msg.sender,
        target_spent,
        yield_token_received,
        trusted_value_received,
        conversion_cost,
    )
    return target_spent, yield_token_received


@external
@nonreentrant("lock")
def contractViaAmm(_yield_token_amount: uint256) -> (uint256, uint256, uint256):
    assert not self.all_execution_paused
    assert not self.yield_contraction_paused
    assert _yield_token_amount > 0
    assert _yield_token_amount <= self.accounted_yield_token_units
    assert len(self.contraction_path) > 0

    accounted_before: uint256 = self.accounted_yield_token_units
    trusted_backing_before: uint256 = self._trusted_backing_value()
    trusted_value_before: uint256 = self._trusted_yield_value(accounted_before)
    quoted_value_after: uint256 = self._trusted_yield_value(
        accounted_before - _yield_token_amount
    )
    quoted_value_removed: uint256 = trusted_value_before - quoted_value_after
    assert quoted_value_removed <= self.deployed_crvusd

    yield_balance_before: uint256 = self._yield_token.balanceOf(self)
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    assert yield_balance_before >= accounted_before

    route_output: uint256 = self._execute_route(_yield_token_amount, False)

    yield_balance_after: uint256 = self._yield_token.balanceOf(self)
    crv_usd_after_swap: uint256 = self._crv_usd.balanceOf(self)
    assert yield_balance_before >= yield_balance_after
    yield_token_spent: uint256 = yield_balance_before - yield_balance_after
    assert yield_token_spent == _yield_token_amount
    assert crv_usd_after_swap >= crv_usd_before
    crv_usd_received: uint256 = crv_usd_after_swap - crv_usd_before
    assert crv_usd_received == route_output

    trusted_value_after: uint256 = self._trusted_yield_value(
        accounted_before - yield_token_spent
    )
    assert trusted_value_before >= trusted_value_after
    trusted_value_removed: uint256 = trusted_value_before - trusted_value_after
    assert trusted_value_removed <= self.deployed_crvusd

    trusted_backing_after: uint256 = trusted_backing_before - trusted_value_removed
    gross_profit: uint256 = self._realized_contraction_profit(
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
    )
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS

    if keeper_reward > 0:
        keeper_balance_before: uint256 = self._crv_usd.balanceOf(msg.sender)
        self._crv_usd.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = self._crv_usd.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before
        assert keeper_balance_after - keeper_balance_before == keeper_reward

    crv_usd_after_reward: uint256 = self._crv_usd.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_after_reward
    assert crv_usd_after_swap - crv_usd_after_reward == keeper_reward
    assert crv_usd_after_reward >= crv_usd_before
    net_crv_usd: uint256 = crv_usd_after_reward - crv_usd_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    exit_margin: uint256 = trusted_value_removed * exit_margin_ppm / PPM
    assert net_crv_usd >= trusted_value_removed + exit_margin

    self.accounted_yield_token_units = accounted_before - yield_token_spent
    exposure_reduction: uint256 = net_crv_usd
    if exposure_reduction > self.deployed_crvusd:
        exposure_reduction = self.deployed_crvusd
    self.deployed_crvusd -= exposure_reduction

    assert self._yield_token.balanceOf(self) >= self.accounted_yield_token_units
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log KeeperBuyback(
        msg.sender,
        self._backing_asset.address,
        0,
        yield_token_spent,
        crv_usd_received,
        gross_profit,
        keeper_reward,
        early_exit,
    )
    return yield_token_spent, crv_usd_received, keeper_reward


@external
@payable
@nonreentrant("lock")
def execute(_target: address, _value: uint256, _data: Bytes[65535]) -> Bytes[65535]:
    assert self._is_admin(msg.sender)
    assert _target != empty(address)

    result: Bytes[65535] = raw_call(
        _target,
        _data,
        value=_value,
        max_outsize=65535,
    )
    selector: bytes4 = empty(bytes4)
    if len(_data) >= 4:
        selector = convert(slice(_data, 0, 4), bytes4)
    log Executed(_target, _value, selector, keccak256(_data))
    return result


@external
def set_policy(
    _entry_min_profit_ppm: uint256,
    _normal_exit_min_profit_ppm: uint256,
    _early_exit_min_profit_ppm: uint256,
    _keeper_profit_share_bps: uint256,
    _min_deployment_time: uint256,
    _min_expansion_amount: uint256,
    _max_deployed_crvusd: uint256,
):
    assert self._is_admin(msg.sender)
    assert _early_exit_min_profit_ppm <= PPM
    assert _normal_exit_min_profit_ppm >= _entry_min_profit_ppm
    assert _early_exit_min_profit_ppm > _normal_exit_min_profit_ppm
    assert _keeper_profit_share_bps <= BPS
    assert _min_expansion_amount > 0
    assert _max_deployed_crvusd > 0

    self.entry_min_profit_ppm = _entry_min_profit_ppm
    self.normal_exit_min_profit_ppm = _normal_exit_min_profit_ppm
    self.early_exit_min_profit_ppm = _early_exit_min_profit_ppm
    self.keeper_profit_share_bps = _keeper_profit_share_bps
    self.min_deployment_time = _min_deployment_time
    self.min_expansion_amount = _min_expansion_amount
    self.max_deployed_crvusd = _max_deployed_crvusd

    log PolicyUpdated(
        _entry_min_profit_ppm,
        _normal_exit_min_profit_ppm,
        _early_exit_min_profit_ppm,
        _keeper_profit_share_bps,
        _min_deployment_time,
        _min_expansion_amount,
        _max_deployed_crvusd,
    )


@external
def set_direction_paused(_direction: uint256, _paused: bool):
    admin: address = self._factory.admin()
    emergency_admin: address = self._factory.emergency_admin()
    assert msg.sender == admin or msg.sender == emergency_admin
    if msg.sender == emergency_admin:
        assert _paused

    if _direction == DIRECTION_EXPANSION:
        if not _paused:
            assert self.min_downstream_attempt_gas > 0
            assert self.fallback_settlement_gas_reserve > 0
        self.expansion_paused = _paused
    elif _direction == DIRECTION_BACKING_DEPLOYMENT:
        self.backing_deployment_paused = _paused
    elif _direction == DIRECTION_DIRECT_BUYBACK:
        self.direct_buyback_paused = _paused
    elif _direction == DIRECTION_UNDEPLOYED_CONTRACTION:
        self.undeployed_contraction_paused = _paused
    elif _direction == DIRECTION_YIELD_CONTRACTION:
        self.yield_contraction_paused = _paused
    elif _direction == DIRECTION_ALL:
        self.all_execution_paused = _paused
    else:
        raise

    log DirectionPaused(_direction, _paused)


@external
@payable
def __default__():
    assert len(msg.data) == 0
