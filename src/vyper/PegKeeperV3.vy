# pragma version 0.3.10
"""
@title PegKeeper V3
@license MIT
@notice Buys and sells approved assets to help keep crvUSD near its target price.
@dev Tracks backing, limits trades, and follows token paths chosen by the admin.
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
    def asset() -> address: view
    def convertToAssets(_shares: uint256) -> uint256: view
    def previewDeposit(_assets: uint256) -> uint256: view
    def deposit(_assets: uint256, _receiver: address) -> uint256: nonpayable
    def previewRedeem(_shares: uint256) -> uint256: view
    def redeem(_shares: uint256, _receiver: address, _owner: address) -> uint256: nonpayable

interface FrxUsdMinter:
    def asset() -> address: view
    def frxUSD() -> address: view
    def previewDeposit(_assets: uint256) -> uint256: view
    def deposit(_assets: uint256, _receiver: address) -> uint256: nonpayable

interface FraxNetDeposit:
    def asset() -> address: view
    def frxUSD() -> address: view
    def USDC() -> address: view
    def factory() -> address: view
    def targetEid() -> uint32: view
    def targetAddress() -> bytes32: view
    def processRedemption(_amount: uint256) -> uint256: nonpayable

interface FraxNetDepositFactory:
    def isFraxNetDeposit(_account: address) -> bool: view

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

event YieldBackingUnwound:
    caller: indexed(address)
    yield_token_spent: uint256
    target_received: uint256
    trusted_value_spent: uint256
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
STEP_FRXUSD_REDEEM: constant(uint256) = 5

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
yield_token_is_erc4626: public(bool)
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
    """
    @notice Sets the preview contract and prevents the base contract from being set up as a keeper.
    """
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
    """
    @notice Sets up a new keeper with its pool, tokens, limits, and price sources.
    """
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
    is_erc4626: bool = _yield_token.address != _backing_asset.address
    if is_erc4626:
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
    self.yield_token_is_erc4626 = is_erc4626
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
    """
    @notice Returns the factory that created this keeper.
    """
    return self._factory.address


@external
@view
def controller_factory() -> address:
    """
    @notice Returns the shared contract that provides crvUSD and debt limits.
    """
    return self._controller_factory.address


@external
@view
def admin() -> address:
    """
    @notice Returns the account allowed to change keeper settings.
    """
    return self._factory.admin()


@external
@view
def emergency_admin() -> address:
    """
    @notice Returns the account allowed to pause keeper actions.
    """
    return self._factory.emergency_admin()


@external
@view
def fee_receiver() -> address:
    """
    @notice Returns the account that receives claimed crvUSD surplus.
    """
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
    """
    @notice Returns the crvUSD token address.
    """
    return self._crv_usd.address


@external
@pure
def preview_module() -> address:
    """
    @notice Returns the contract used to calculate action estimates.
    """
    return PREVIEW_MODULE.address


@external
@view
def target_asset() -> address:
    """
    @notice Returns the token paired with crvUSD in the main swap pool.
    """
    return self._target_asset.address


@external
@view
def backing_asset() -> address:
    """
    @notice Returns the asset represented by the final token.
    """
    return self._backing_asset.address


@external
@view
def yield_token() -> address:
    """
    @notice Returns the final token held after the configured token path.
    """
    return self._yield_token.address


@internal
@view
def _yield_token_assets(_units: uint256) -> uint256:
    if self.yield_token_is_erc4626:
        return self._yield_token.convertToAssets(_units)
    return _units


@internal
@view
def _yield_token_units(_assets: uint256) -> uint256:
    if self.yield_token_is_erc4626:
        return self._yield_token.convertToShares(_assets)
    return _assets


@external
@view
def yield_token_assets(_units: uint256) -> uint256:
    """
    @notice Returns the backing-asset amount represented by a final-token amount.
    """
    return self._yield_token_assets(_units)


@external
@view
def yield_token_units(_assets: uint256) -> uint256:
    """
    @notice Returns the final-token amount represented by a backing-asset amount.
    """
    return self._yield_token_units(_assets)


@internal
@view
def _target_inventory() -> uint256:
    return self._target_asset.balanceOf(self)


@internal
@view
def _yield_inventory() -> uint256:
    return self._yield_token.balanceOf(self)


@external
@view
def undeployed_backing() -> uint256:
    """
    @notice Returns the keeper's current balance of the target token.
    """
    return self._target_inventory()


@external
@view
def accounted_yield_token_units() -> uint256:
    """
    @notice Returns the keeper's current balance of the final token.
    """
    return self._yield_inventory()


@external
@view
def coins(_index: uint256) -> address:
    """
    @notice Returns crvUSD for index 0 and the final token for index 1.
    """
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
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        self.yield_oracle.address,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        return 0, False
    price: uint256 = convert(slice(response, 0, 32), uint256)
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
    """
    @notice Returns how much of the recent expansion allowance is still in use.
    """
    return self._current_pressure()


@external
@view
def available_expansion_velocity() -> uint256:
    """
    @notice Returns how much can be expanded now under the short-term rate limit.
    """
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
    target_value: uint256 = 0
    if self._target_asset.address != self._yield_token.address:
        target_value = self._normalize_target(self._target_inventory())
    backing_amount: uint256 = self._yield_token_assets(self._yield_inventory())
    return target_value + self._normalize_backing(backing_amount)


@internal
@view
def _oracle_backing_value() -> uint256:
    value: uint256 = 0
    target_inventory: uint256 = self._target_inventory()
    yield_inventory: uint256 = self._yield_inventory()
    if target_inventory > 0 and self._target_asset.address != self._yield_token.address:
        value = self._oracle_value(
            self._normalize_target(target_inventory), self._target_price()
        )
    if yield_inventory > 0:
        price: uint256 = 0
        healthy: bool = False
        price, healthy = self._yield_price()
        assert healthy
        value += self._oracle_value(
            self._trusted_yield_value(yield_inventory), price
        )
    return value


@internal
@view
def _trusted_yield_value(_yield_token_units: uint256) -> uint256:
    return self._normalize_backing(self._yield_token_assets(_yield_token_units))


@external
@view
def trusted_backing_value() -> uint256:
    """
    @notice Returns the total backing value, treating target and backing assets as worth one dollar each.
    """
    return self._trusted_backing_value()


@external
@view
def protocol_surplus() -> uint256:
    """
    @notice Returns backing value above the crvUSD amount this keeper must cover.
    """
    trusted_value: uint256 = self._trusted_backing_value()
    if trusted_value > self.deployed_crvusd:
        return trusted_value - self.deployed_crvusd
    return 0


@external
@view
def debt() -> uint256:
    """
    @notice Returns the recorded crvUSD amount for compatibility with existing tools.
    """
    return self.deployed_crvusd


@internal
@view
def _remaining_exposure_capacity() -> uint256:
    deployed: uint256 = self.deployed_crvusd
    if self.max_deployed_crvusd <= deployed:
        return 0
    local_capacity: uint256 = self.max_deployed_crvusd - deployed

    factory_allocation: uint256 = self._controller_factory.debt_ceiling(self)
    if factory_allocation <= deployed:
        return 0
    return min(local_capacity, factory_allocation - deployed)


@external
@view
def available_expansion() -> uint256:
    """
    @notice Returns the most crvUSD that can be used for an expansion now.
    """
    return min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )


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
def _transfer_exact_to(_token: ERC20, _recipient: address, _amount: uint256):
    if _amount > 0:
        recipient_balance_before: uint256 = _token.balanceOf(_recipient)
        _token.transfer(_recipient, _amount)
        recipient_balance_after: uint256 = _token.balanceOf(_recipient)
        assert recipient_balance_after >= recipient_balance_before
        assert recipient_balance_after - recipient_balance_before == _amount


@internal
def _target_amm_swap_exact_in(
    _token_in: ERC20,
    _token_out: ERC20,
    _index_in: int128,
    _index_out: int128,
    _amount_in: uint256,
    _input_balance_before: uint256,
    _output_balance_before: uint256,
) -> (uint256, uint256):
    quoted_output: uint256 = self.target_amm.get_dy(
        _index_in,
        _index_out,
        _amount_in,
    )
    minimum_output: uint256 = quoted_output * (
        BPS - self.target_amm_execution_buffer_bps
    ) / BPS

    _token_in.approve(self.target_amm.address, _amount_in)
    self.target_amm.exchange(
        _index_in,
        _index_out,
        _amount_in,
        minimum_output,
    )
    _token_in.approve(self.target_amm.address, 0)

    input_balance_after: uint256 = _token_in.balanceOf(self)
    assert _input_balance_before >= input_balance_after
    amount_spent: uint256 = _input_balance_before - input_balance_after
    assert amount_spent == _amount_in

    output_balance_after: uint256 = _token_out.balanceOf(self)
    assert output_balance_after >= _output_balance_before
    amount_received: uint256 = output_balance_after - _output_balance_before
    assert amount_received >= minimum_output
    input_value: uint256 = self._normalize_route_amount(_token_in.address, amount_spent)
    output_value: uint256 = self._normalize_route_amount(_token_out.address, amount_received)
    assert output_value >= input_value * (
        BPS - self.target_amm_execution_buffer_bps
    ) / BPS
    return amount_spent, amount_received


@internal
def _settle_keeper_contraction_and_reduce_exposure(
    _crv_usd_before: uint256,
    _crv_usd_after_swap: uint256,
    _crv_usd_received: uint256,
    _trusted_value_removed: uint256,
    _trusted_backing_after: uint256,
) -> (uint256, uint256, bool):
    gross_profit: uint256 = self._realized_contraction_profit(
        _crv_usd_received,
        _trusted_value_removed,
        _trusted_backing_after,
    )
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    self._transfer_exact_to(self._crv_usd, msg.sender, keeper_reward)

    crv_usd_after_reward: uint256 = self._crv_usd.balanceOf(self)
    assert _crv_usd_after_swap >= crv_usd_after_reward
    assert _crv_usd_after_swap - crv_usd_after_reward == keeper_reward
    assert crv_usd_after_reward >= _crv_usd_before
    net_crv_usd: uint256 = crv_usd_after_reward - _crv_usd_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    exit_margin: uint256 = _trusted_value_removed * exit_margin_ppm / PPM
    assert net_crv_usd >= _trusted_value_removed + exit_margin

    exposure_reduction: uint256 = min(net_crv_usd, self.deployed_crvusd)
    self.deployed_crvusd -= exposure_reduction
    return gross_profit, keeper_reward, early_exit


@internal
@view
def _preview_buyback(_crv_usd_amount: uint256) -> (uint256, uint256, bool):
    assert _crv_usd_amount > 0
    deployed_before: uint256 = self.deployed_crvusd
    assert _crv_usd_amount <= deployed_before

    accounted_before: uint256 = self._yield_inventory()

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

    yield_token_out: uint256 = self._yield_token_units(payout_assets - 1)
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
    """
    @notice Estimates the final tokens paid for a direct crvUSD buyback from current data; actual results may differ.
    """
    return self._preview_buyback(_crv_usd_amount)


@external
@nonreentrant("lock")
def buyback(_crv_usd_amount: uint256, _min_yield_token_out: uint256) -> uint256:
    """
    @notice Lets a caller pay crvUSD to buy final tokens from the keeper.
    """
    assert not self.all_execution_paused
    assert not self.direct_buyback_paused

    expected_yield_token_out: uint256 = 0
    ignored_exit_profit: uint256 = 0
    early_exit: bool = False
    expected_yield_token_out, ignored_exit_profit, early_exit = self._preview_buyback(_crv_usd_amount)
    assert expected_yield_token_out >= _min_yield_token_out

    accounted_before: uint256 = self._yield_inventory()
    deployed_before: uint256 = self.deployed_crvusd
    trusted_yield_before: uint256 = self._trusted_yield_value(accounted_before)
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    caller_crv_usd_before: uint256 = self._crv_usd.balanceOf(msg.sender)
    yield_token_before: uint256 = self._yield_token.balanceOf(self)

    self._crv_usd.transferFrom(msg.sender, self, _crv_usd_amount)
    crv_usd_after: uint256 = self._crv_usd.balanceOf(self)
    caller_crv_usd_after: uint256 = self._crv_usd.balanceOf(msg.sender)
    assert crv_usd_after >= crv_usd_before
    crv_usd_received: uint256 = crv_usd_after - crv_usd_before
    assert crv_usd_received == _crv_usd_amount
    assert caller_crv_usd_before >= caller_crv_usd_after
    assert caller_crv_usd_before - caller_crv_usd_after == _crv_usd_amount

    self._transfer_exact_to(
        ERC20(self._yield_token.address),
        msg.sender,
        expected_yield_token_out,
    )
    yield_token_after: uint256 = self._yield_token.balanceOf(self)
    assert yield_token_before >= yield_token_after
    yield_token_spent: uint256 = yield_token_before - yield_token_after
    assert yield_token_spent == expected_yield_token_out
    yield_token_received: uint256 = expected_yield_token_out
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
    self.deployed_crvusd = deployed_after
    assert self._trusted_backing_value() >= deployed_after

    log DirectBuyback(msg.sender, crv_usd_received, yield_token_received, early_exit)
    return yield_token_received


@external
@view
def previewUndeployedContraction(_amount: uint256) -> (uint256, uint256, uint256, bool):
    """
    @notice Estimates selling held target tokens back to crvUSD from current data; actual results may differ.
    """
    return PREVIEW_MODULE.previewUndeployedContraction(self, _amount)


@external
@view
def previewKeeperBuyback(_amount: uint256) -> (uint256, uint256, uint256, bool):
    """
    @notice Estimates selling final tokens back to crvUSD from current data; actual results may differ.
    """
    return PREVIEW_MODULE.previewKeeperBuyback(self, _amount)


@external
@view
def previewExpansion(_amount: uint256) -> (uint256, uint256, uint256, uint256, uint256, bool):
    """
    @notice Estimates an expansion from current data; actual results may differ.
    """
    return PREVIEW_MODULE.previewExpansion(self, _amount)


@external
def set_target_amm(_new_target_amm: TwoCoinPool, _execution_buffer_bps: uint256):
    """
    @notice Changes the main crvUSD swap pool and the largest allowed drop below its quote.
    """
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
    """
    @notice Changes the price sources and the lowest accepted prices.
    """
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
    """
    @notice Changes the allowed quote drop and gas limits used during expansion.
    """
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
    """
    @notice Uses crvUSD to buy backing and pays the caller a share of any profit.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _crv_usd_amount >= self.min_expansion_amount
    target_price: uint256 = self._target_price()

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    assert _crv_usd_amount <= crv_usd_before

    assert _crv_usd_amount <= self._remaining_exposure_capacity()
    deployed_after: uint256 = self.deployed_crvusd + _crv_usd_amount
    self._consume_velocity(_crv_usd_amount)

    crv_usd_index: int128 = convert(self.target_amm_crvusd_index, int128)
    target_index: int128 = convert(self.target_amm_target_index, int128)
    target_before: uint256 = self._target_asset.balanceOf(self)
    crv_usd_sold: uint256 = 0
    target_received: uint256 = 0
    crv_usd_sold, target_received = self._target_amm_swap_exact_in(
        self._crv_usd,
        self._target_asset,
        crv_usd_index,
        target_index,
        _crv_usd_amount,
        crv_usd_before,
        target_before,
    )
    target_after_swap: uint256 = target_before + target_received

    downstream_succeeded: bool = False
    downstream_response: Bytes[128] = empty(Bytes[128])
    yield_balance_before_attempt: uint256 = self._yield_token.balanceOf(self)
    if len(self.expansion_path) > 0 and not self.backing_deployment_paused:
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

        self.deployed_crvusd = deployed_after
        self.last_expansion_at = block.timestamp
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
    self._transfer_exact_to(self._target_asset, msg.sender, keeper_reward)

    target_after_reward: uint256 = self._target_asset.balanceOf(self)
    assert target_after_swap >= target_after_reward
    assert target_after_swap - target_after_reward == keeper_reward
    assert target_after_reward >= target_before
    target_retained: uint256 = target_after_reward - target_before

    assert self._meets_entry_floor(
        self._oracle_value(self._normalize_target(target_retained), target_price), crv_usd_sold
    )

    backing_asset_received: uint256 = 0
    yield_token_received: uint256 = 0
    backing_retained: uint256 = target_retained
    deployed_to_yield: bool = False
    if self._target_asset.address == self._yield_token.address:
        backing_asset_received = target_received
        yield_token_received = target_retained
        backing_retained = 0
        deployed_to_yield = True

    self.deployed_crvusd = deployed_after
    self.last_expansion_at = block.timestamp

    assert self._trusted_backing_value() >= self.deployed_crvusd

    log Expanded(
        msg.sender,
        crv_usd_sold,
        target_received,
        backing_asset_received,
        yield_token_received,
        gross_profit,
        keeper_reward,
        backing_retained,
        deployed_to_yield,
        block.timestamp + self.min_deployment_time,
    )

    return crv_usd_sold, backing_retained, yield_token_received, keeper_reward, deployed_to_yield


@external
@nonreentrant("lock")
def contractUndeployedBacking(_target_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Swaps held target tokens back to crvUSD and pays the caller a share of any profit.
    """
    assert not self.all_execution_paused
    assert not self.undeployed_contraction_paused
    assert _target_amount > 0
    assert _target_amount <= self._target_inventory()

    target_before: uint256 = self._target_asset.balanceOf(self)
    trusted_backing_before: uint256 = self._trusted_backing_value()

    target_index: int128 = convert(self.target_amm_target_index, int128)
    crv_usd_index: int128 = convert(self.target_amm_crvusd_index, int128)
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    target_spent: uint256 = 0
    crv_usd_received: uint256 = 0
    target_spent, crv_usd_received = self._target_amm_swap_exact_in(
        self._target_asset,
        self._crv_usd,
        target_index,
        crv_usd_index,
        _target_amount,
        target_before,
        crv_usd_before,
    )
    crv_usd_after_swap: uint256 = crv_usd_before + crv_usd_received

    trusted_backing_after: uint256 = self._trusted_backing_value()
    assert trusted_backing_before >= trusted_backing_after
    trusted_value_removed: uint256 = trusted_backing_before - trusted_backing_after
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    early_exit: bool = False
    gross_profit, keeper_reward, early_exit = self._settle_keeper_contraction_and_reduce_exposure(
        crv_usd_before,
        crv_usd_after_swap,
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
    )

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
    """
    @notice Sends available crvUSD to the fee receiver when extra backing covers it, up to the caller's limit.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused

    trusted_backing: uint256 = self._oracle_backing_value()
    surplus: uint256 = 0
    if trusted_backing > self.deployed_crvusd:
        surplus = trusted_backing - self.deployed_crvusd

    crv_usd_balance_before: uint256 = self._crv_usd.balanceOf(self)
    exposure_capacity: uint256 = self._remaining_exposure_capacity()
    crv_usd_transferred: uint256 = _max_crv_usd_amount
    if crv_usd_transferred > surplus:
        crv_usd_transferred = surplus
    if crv_usd_transferred > crv_usd_balance_before:
        crv_usd_transferred = crv_usd_balance_before
    if crv_usd_transferred > exposure_capacity:
        crv_usd_transferred = exposure_capacity
    crv_usd_transferred = min(crv_usd_transferred, self._available_velocity())
    assert crv_usd_transferred > 0
    self._consume_velocity(crv_usd_transferred)

    deployed_crv_usd_after: uint256 = self.deployed_crvusd + crv_usd_transferred
    self.deployed_crvusd = deployed_crv_usd_after

    fee_receiver: address = self._factory.fee_receiver()
    self._transfer_exact_to(self._crv_usd, fee_receiver, crv_usd_transferred)
    crv_usd_balance_after: uint256 = self._crv_usd.balanceOf(self)
    assert crv_usd_balance_before >= crv_usd_balance_after
    assert crv_usd_balance_before - crv_usd_balance_after == crv_usd_transferred

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
    assert ERC20(_step.token_in).decimals() <= 18
    assert ERC20(_step.token_out).decimals() <= 18

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
    elif _step.kind == STEP_FRXUSD_REDEEM:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0
        assert FraxNetDeposit(_step.venue).asset() == _step.token_in
        assert FraxNetDeposit(_step.venue).frxUSD() == _step.token_in
        assert FraxNetDeposit(_step.venue).USDC() == _step.token_out
        frax_net_factory: address = FraxNetDeposit(_step.venue).factory()
        assert frax_net_factory != empty(address)
        assert FraxNetDepositFactory(frax_net_factory).isFraxNetDeposit(_step.venue)
        assert FraxNetDeposit(_step.venue).targetEid() == 30_101
        assert FraxNetDeposit(_step.venue).targetAddress() == convert(self, bytes32)
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
    """
    @notice Replaces the token paths used after expansion and on the way back to crvUSD.
    """
    assert self._is_admin_or_factory(msg.sender)
    assert _expansion_max_route_loss_bps <= BPS

    if len(_expansion_steps) == 0:
        assert self._target_asset.address == self._yield_token.address
    else:
        assert _expansion_steps[0].token_in == self._target_asset.address
        expansion_last: RouteStep = _expansion_steps[len(_expansion_steps) - 1]
        assert expansion_last.token_out == self._yield_token.address

    assert len(_contraction_steps) > 0
    assert _contraction_steps[0].token_in == self._yield_token.address
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
    """
    @notice Returns the number of steps in the post-expansion token path.
    """
    return len(self.expansion_path)


@external
@view
def contraction_path_length() -> uint256:
    """
    @notice Returns the number of steps in the token path back to crvUSD.
    """
    return len(self.contraction_path)


@external
@view
def expansion_path_step(_index: uint256) -> RouteStep:
    """
    @notice Returns one step from the post-expansion token path.
    """
    assert _index < len(self.expansion_path)
    return self.expansion_path[_index]


@external
@view
def contraction_path_step(_index: uint256) -> RouteStep:
    """
    @notice Returns one step from the token path back to crvUSD.
    """
    assert _index < len(self.contraction_path)
    return self.contraction_path[_index]


@internal
@view
def _normalize_route_amount(_token: address, _amount: uint256) -> uint256:
    token_decimals: uint256 = ERC20(_token).decimals()
    assert token_decimals <= 18
    return _amount * 10 ** (18 - token_decimals)


@internal
def _execute_route_step(_step: RouteStep, _amount_in: uint256) -> uint256:
    token_in: ERC20 = ERC20(_step.token_in)
    token_out: ERC20 = ERC20(_step.token_out)
    input_balance_before: uint256 = token_in.balanceOf(self)
    output_balance_before: uint256 = token_out.balanceOf(self)
    yield_value_before: uint256 = 0
    if _step.token_in == self._yield_token.address or _step.token_out == self._yield_token.address:
        yield_value_before = self._trusted_yield_value(self._yield_token.balanceOf(self))
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
    elif _step.kind == STEP_FRXUSD_REDEEM:
        quoted_output = self._normalize_route_amount(_step.token_in, _amount_in) / 10 ** (
            18 - ERC20(_step.token_out).decimals()
        )
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        token_in.transfer(_step.venue, _amount_in)
        FraxNetDeposit(_step.venue).processRedemption(_amount_in)
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

    input_value: uint256 = 0
    output_value: uint256 = 0
    if _step.kind == STEP_ERC4626_DEPOSIT:
        input_value = self._normalize_route_amount(_step.token_in, _amount_in)
        output_value = self._normalize_route_amount(
            _step.token_in,
            ERC4626Route(_step.venue).convertToAssets(amount_out),
        )
    elif _step.kind == STEP_ERC4626_REDEEM:
        input_value = self._normalize_route_amount(
            _step.token_out,
            ERC4626Route(_step.venue).convertToAssets(_amount_in),
        )
        output_value = self._normalize_route_amount(_step.token_out, amount_out)
    elif _step.token_in == self._yield_token.address:
        yield_value_after: uint256 = self._trusted_yield_value(input_balance_after)
        assert yield_value_before >= yield_value_after
        input_value = yield_value_before - yield_value_after
        output_value = self._normalize_route_amount(_step.token_out, amount_out)
    elif _step.token_out == self._yield_token.address:
        yield_value_after: uint256 = self._trusted_yield_value(output_balance_after)
        assert yield_value_after >= yield_value_before
        input_value = self._normalize_route_amount(_step.token_in, _amount_in)
        output_value = yield_value_after - yield_value_before
    else:
        input_value = self._normalize_route_amount(_step.token_in, _amount_in)
        output_value = self._normalize_route_amount(_step.token_out, amount_out)
    assert output_value >= input_value * (BPS - _step.execution_buffer_bps) / BPS
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


@internal
@view
def _checked_route_conversion_cost(_source_value: uint256, _retained_value: uint256) -> uint256:
    conversion_cost: uint256 = 0
    if _source_value > _retained_value:
        conversion_cost = _source_value - _retained_value
    assert conversion_cost <= _source_value * self.expansion_max_route_loss_bps / BPS
    return conversion_cost


@external
def executeExpansionPath(
    _target_amount: uint256,
    _crv_usd_sold: uint256,
    _keeper: address,
) -> (uint256, uint256, uint256, uint256):
    """
    @notice Runs the post-expansion token path when the keeper calls itself and pays the original caller's reward.
    """
    assert msg.sender == self
    assert not self.backing_deployment_paused
    assert len(self.expansion_path) > 0
    yield_price: uint256 = 0
    healthy: bool = False
    yield_price, healthy = self._yield_price()
    assert healthy

    amount_in: uint256 = _target_amount
    path_length: uint256 = len(self.expansion_path)
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        amount_in = self._execute_route_step(self.expansion_path[i], amount_in)

    gross_yield_token_received: uint256 = amount_in
    assert gross_yield_token_received > 0
    backing_asset_received: uint256 = self._yield_token_assets(gross_yield_token_received)
    gross_route_value: uint256 = self._oracle_value(
        backing_asset_received * self.backing_multiplier,
        yield_price,
    )
    gross_profit: uint256 = 0
    if gross_route_value > _crv_usd_sold:
        gross_profit = gross_route_value - _crv_usd_sold

    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward_assets: uint256 = keeper_reward_value / self.backing_multiplier
    keeper_reward: uint256 = self._yield_token_units(keeper_reward_assets)
    assert keeper_reward <= gross_yield_token_received
    self._transfer_exact_to(ERC20(self._yield_token.address), _keeper, keeper_reward)

    yield_token_received: uint256 = gross_yield_token_received - keeper_reward
    assert yield_token_received > 0
    trusted_yield_received: uint256 = self._oracle_value(
        self._yield_token_assets(yield_token_received) * self.backing_multiplier,
        yield_price,
    )
    target_price: uint256 = self._target_price()
    target_value: uint256 = self._oracle_value(
        _target_amount * self.target_multiplier, target_price
    )
    self._checked_route_conversion_cost(target_value, gross_route_value)
    assert self._meets_entry_floor(trusted_yield_received, _crv_usd_sold)
    return backing_asset_received, yield_token_received, gross_profit, keeper_reward


@external
@nonreentrant("lock")
def deployUndeployedBacking(_target_amount: uint256) -> (uint256, uint256):
    """
    @notice Moves held target tokens through the set token path into the final token.
    """
    assert not self.all_execution_paused
    assert not self.backing_deployment_paused
    assert _target_amount > 0
    assert _target_amount <= self._target_inventory()
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
        self._yield_token_assets(yield_token_received) * self.backing_multiplier,
        yield_price,
    )
    conversion_cost: uint256 = self._checked_route_conversion_cost(
        target_value_spent,
        trusted_value_received,
    )
    assert conversion_cost <= available_deployment_surplus

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
def unwindYieldToTarget(_yield_token_amount: uint256) -> (uint256, uint256):
    """
    @notice Moves final tokens back into target tokens without selling them for crvUSD.
    """
    assert not self.all_execution_paused
    assert self.backing_deployment_paused
    assert not self.yield_contraction_paused
    assert _yield_token_amount > 0
    assert _yield_token_amount <= self._yield_inventory()

    path_length: uint256 = len(self.contraction_path)
    assert path_length > 1
    final_step: RouteStep = self.contraction_path[path_length - 1]
    assert final_step.token_in == self._target_asset.address

    trusted_backing_before: uint256 = self._trusted_backing_value()
    available_surplus: uint256 = 0
    if trusted_backing_before > self.deployed_crvusd:
        available_surplus = trusted_backing_before - self.deployed_crvusd

    yield_balance_before: uint256 = self._yield_token.balanceOf(self)
    target_balance_before: uint256 = self._target_asset.balanceOf(self)
    trusted_yield_before: uint256 = self._trusted_yield_value(yield_balance_before)

    route_output: uint256 = _yield_token_amount
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length - 1:
            break
        route_output = self._execute_route_step(self.contraction_path[i], route_output)

    yield_balance_after: uint256 = self._yield_token.balanceOf(self)
    target_balance_after: uint256 = self._target_asset.balanceOf(self)
    assert yield_balance_before >= yield_balance_after
    yield_token_spent: uint256 = yield_balance_before - yield_balance_after
    assert yield_token_spent == _yield_token_amount
    assert target_balance_after >= target_balance_before
    target_received: uint256 = target_balance_after - target_balance_before
    assert target_received == route_output
    assert target_received > 0

    trusted_yield_after: uint256 = self._trusted_yield_value(yield_balance_after)
    assert trusted_yield_before >= trusted_yield_after
    trusted_value_spent: uint256 = trusted_yield_before - trusted_yield_after
    target_price: uint256 = self._target_price()
    target_value_received: uint256 = self._oracle_value(
        self._normalize_target(target_received),
        target_price,
    )
    conversion_cost: uint256 = self._checked_route_conversion_cost(
        trusted_value_spent,
        target_value_received,
    )
    assert conversion_cost <= available_surplus
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log YieldBackingUnwound(
        msg.sender,
        yield_token_spent,
        target_received,
        trusted_value_spent,
        conversion_cost,
    )
    return yield_token_spent, target_received


@external
@nonreentrant("lock")
def contractViaAmm(_yield_token_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Sells final tokens for crvUSD through the set token path and pays the caller a share of any profit.
    """
    assert not self.all_execution_paused
    assert not self.yield_contraction_paused
    assert _yield_token_amount > 0
    assert _yield_token_amount <= self._yield_inventory()
    assert len(self.contraction_path) > 0

    accounted_before: uint256 = self._yield_inventory()
    trusted_backing_before: uint256 = self._trusted_backing_value()
    trusted_value_before: uint256 = self._trusted_yield_value(accounted_before)
    quoted_value_after: uint256 = self._trusted_yield_value(
        accounted_before - _yield_token_amount
    )
    quoted_value_removed: uint256 = trusted_value_before - quoted_value_after
    assert quoted_value_removed <= self.deployed_crvusd

    yield_balance_before: uint256 = self._yield_token.balanceOf(self)
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)

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
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    early_exit: bool = False
    gross_profit, keeper_reward, early_exit = self._settle_keeper_contraction_and_reduce_exposure(
        crv_usd_before,
        crv_usd_after_swap,
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
    )

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
    """
    @notice Lets the admin call another address and returns any response.
    """
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
    """
    @notice Changes profit, reward, timing, minimum trade, and crvUSD limits.
    """
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
    """
    @notice Pauses or resumes one keeper action.
    """
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
    """
    @notice Accepts ETH sent without call data and rejects unknown calls.
    """
    assert len(msg.data) == 0
