# pragma version 0.3.10
"""
@title PegKeeper V3
@license MIT
@notice Buys and sells approved assets to help keep crvUSD near its target price.
@dev Holds Curve LP backing, limits updates, and uses an admin-selected expansion path.
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
    def aggregateCrvUsdOracle() -> address: view

interface TwoCoinPool:
    def coins(_index: uint256) -> address: view
    def get_dy(_i: int128, _j: int128, _dx: uint256) -> uint256: view
    def exchange(_i: int128, _j: int128, _dx: uint256, _min_dy: uint256): nonpayable


interface YieldAmm:
    def coins(_index: uint256) -> address: view
    def balances(_index: uint256) -> uint256: view
    def balanceOf(_owner: address) -> uint256: view
    def get_virtual_price() -> uint256: view
    def calc_token_amount(_amounts: DynArray[uint256, 2], _is_deposit: bool) -> uint256: view
    def add_liquidity(_amounts: DynArray[uint256, 2], _min_mint_amount: uint256) -> uint256: nonpayable
    def calc_withdraw_one_coin(_lp_tokens: uint256, _index: int128) -> uint256: view
    def remove_liquidity_one_coin(
        _lp_tokens: uint256,
        _index: int128,
        _min_amount: uint256,
    ): nonpayable

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
    yield_amm_execution_buffer_bps: uint256

event TargetAmmUpdated:
    old_target_amm: indexed(address)
    new_target_amm: indexed(address)
    crv_usd_index: uint256
    target_index: uint256
    execution_buffer_bps: uint256

event Expanded:
    keeper: indexed(address)
    crv_usd_sold: uint256
    crv_usd_matched: uint256
    lp_tokens_received: uint256
    gross_profit: uint256
    keeper_reward: uint256
    direct_deposit: bool

event DonatedYieldSwept:
    keeper: indexed(address)
    yield_token_swept: uint256
    crv_usd_matched: uint256
    lp_tokens_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event Contracted:
    keeper: indexed(address)
    lp_tokens_burned: uint256
    crv_usd_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event SurplusClaimed:
    caller: indexed(address)
    receiver: indexed(address)
    crv_usd_transferred: uint256
    deployed_crv_usd_after: uint256

event DebtReduced:
    caller: indexed(address)
    requested_reduction: uint256
    actual_reduction: uint256
    deployed_crv_usd_after: uint256

event PolicyUpdated:
    entry_min_profit_ppm: uint256
    normal_exit_min_profit_ppm: uint256
    keeper_profit_share_bps: uint256
    min_expansion_amount: uint256
    max_deployed_crvusd: uint256

event PathsUpdated:
    expansion_path_hash: indexed(bytes32)
    expansion_max_route_loss_bps: uint256

event OraclePolicyUpdated:
    target_oracle: indexed(address)
    yield_oracle: indexed(address)
    min_target_price: uint256
    min_yield_price: uint256



version: public(constant(String[8])) = "3.2.0"
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
DIRECTION_YIELD_CONTRACTION: constant(uint256) = 1
DIRECTION_ALL: constant(uint256) = 2

PREVIEW_MODULE: immutable(PreviewModule)
_factory: PegKeeperFactory
_controller_factory: ControllerFactory
_crv_usd: ERC20
target_amm: public(TwoCoinPool)
_target_asset: ERC20
_backing_asset: ERC20
_yield_token: YieldToken
yield_amm: public(YieldAmm)
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
yield_amm_crvusd_index: public(uint256)
yield_amm_yield_token_index: public(uint256)

entry_min_profit_ppm: public(uint256)
normal_exit_min_profit_ppm: public(uint256)
keeper_profit_share_bps: public(uint256)
min_expansion_amount: public(uint256)
max_deployed_crvusd: public(uint256)
target_amm_execution_buffer_bps: public(uint256)
yield_amm_execution_buffer_bps: public(uint256)
expansion_path: DynArray[RouteStep, 16]
expansion_max_route_loss_bps: public(uint256)

deployed_crvusd: public(uint256)
_expansion_pressure: uint256
last_expansion_pressure_update: public(uint256)

expansion_paused: public(bool)
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
    self.yield_contraction_paused = True
    self.all_execution_paused = True


@external
def initialize(
    _target_amm: TwoCoinPool,
    _target_asset: ERC20,
    _backing_asset: ERC20,
    _yield_token: YieldToken,
    _yield_amm: YieldAmm,
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
    assert _yield_amm.address != empty(address)
    assert _yield_amm.address.codesize > 0
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
    assert ERC20(_yield_amm.address).decimals() == 18

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

    yield_coin_0: address = _yield_amm.coins(0)
    yield_coin_1: address = _yield_amm.coins(1)
    if yield_coin_0 == crv_usd and yield_coin_1 == _yield_token.address:
        self.yield_amm_crvusd_index = 0
        self.yield_amm_yield_token_index = 1
    elif yield_coin_0 == _yield_token.address and yield_coin_1 == crv_usd:
        self.yield_amm_crvusd_index = 1
        self.yield_amm_yield_token_index = 0
    else:
        raise
    assert _yield_amm.get_virtual_price() > 0

    self._factory = PegKeeperFactory(msg.sender)
    self._controller_factory = ControllerFactory(controller_factory)
    self._crv_usd = ERC20(crv_usd)
    self.target_amm = _target_amm
    self._target_asset = _target_asset
    self._backing_asset = _backing_asset
    self._yield_token = _yield_token
    self.yield_amm = _yield_amm
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
    self.normal_exit_min_profit_ppm = 500
    self.keeper_profit_share_bps = 3_000
    self.min_expansion_amount = 10_000 * 10 ** 18
    self.max_deployed_crvusd = _max_deployed_crvusd
    self.last_expansion_pressure_update = block.timestamp

    self.expansion_paused = True
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
    @notice Returns the asset denomination used to match loose yield tokens with crvUSD.
    """
    return self._backing_asset.address


@external
@view
def yield_token() -> address:
    """
    @notice Returns the token acquired by expansion and paired with crvUSD in the yield AMM.
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


@internal
@view
def _lp_inventory() -> uint256:
    return self.yield_amm.balanceOf(self)


@internal
@view
def _lp_value(_lp_tokens: uint256) -> uint256:
    virtual_price: uint256 = self.yield_amm.get_virtual_price()
    return (
        _lp_tokens / PRECISION * virtual_price
        + _lp_tokens % PRECISION * virtual_price / PRECISION
    )


@external
@view
def accounted_lp_tokens() -> uint256:
    """
    @notice Returns the complete held balance of yield-AMM LP tokens.
    """
    return self._lp_inventory()


@external
@view
def coins(_index: uint256) -> address:
    """
    @notice Returns crvUSD for index 0 and the held yield-AMM LP token for index 1.
    """
    if _index == 0:
        return self._crv_usd.address
    assert _index == 1
    return self.yield_amm.address


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
def _yield_price() -> uint256:
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
        raise
    price: uint256 = convert(slice(response, 0, 32), uint256)
    assert price >= self.min_yield_oracle_price
    return price


@internal
@view
def _aggregate_crvusd_price() -> uint256:
    oracle: address = self._factory.aggregateCrvUsdOracle()
    assert oracle != empty(address) and oracle.codesize > 0

    ok: bool = False
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        oracle,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        raise
    return convert(slice(response, 0, 32), uint256)


@internal
@view
def _require_expansion_regime():
    assert self._aggregate_crvusd_price() >= PRECISION


@internal
@view
def _require_contraction_regime():
    assert self._aggregate_crvusd_price() <= PRECISION


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
    return self._lp_value(self._lp_inventory())


@internal
@view
def _oracle_backing_value() -> uint256:
    price: uint256 = self._yield_price()
    return self._oracle_value(self._trusted_backing_value(), price)


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
    if self.all_execution_paused or self.expansion_paused:
        return 0
    if self._aggregate_crvusd_price() < PRECISION:
        return 0
    return min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )


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
        assert _token.balanceOf(_recipient) - recipient_balance_before == _amount


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
    amount_spent: uint256 = _input_balance_before - input_balance_after
    assert amount_spent == _amount_in

    output_balance_after: uint256 = _token_out.balanceOf(self)
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
) -> (uint256, uint256):
    gross_profit: uint256 = self._realized_contraction_profit(
        _crv_usd_received,
        _trusted_value_removed,
        _trusted_backing_after,
    )
    exit_margin: uint256 = _trusted_value_removed * self.normal_exit_min_profit_ppm / PPM
    assert gross_profit >= exit_margin
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    self._transfer_exact_to(self._crv_usd, msg.sender, keeper_reward)

    crv_usd_after_reward: uint256 = self._crv_usd.balanceOf(self)
    assert _crv_usd_after_swap - crv_usd_after_reward == keeper_reward
    net_crv_usd: uint256 = crv_usd_after_reward - _crv_usd_before

    deployed_crv_usd: uint256 = self.deployed_crvusd
    if net_crv_usd > deployed_crv_usd:
        self.deployed_crvusd = 0
        self._transfer_exact_to(
            self._crv_usd,
            self._factory.fee_receiver(),
            net_crv_usd - deployed_crv_usd,
        )
    else:
        self.deployed_crvusd = deployed_crv_usd - net_crv_usd
    return gross_profit, keeper_reward


@external
@view
def previewKeeperBuyback(_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Estimates burning yield-AMM LP tokens to withdraw crvUSD.
    """
    assert not self.all_execution_paused
    assert not self.yield_contraction_paused
    self._require_contraction_regime()

    accounted: uint256 = self._lp_inventory()
    assert _amount > 0 and _amount <= accounted
    virtual_price: uint256 = self.yield_amm.get_virtual_price()
    trusted_before: uint256 = self._lp_value_at(accounted, virtual_price)
    trusted_after: uint256 = self._lp_value_at(accounted - _amount, virtual_price)
    trusted_removed: uint256 = trusted_before - trusted_after
    expected_crv_usd: uint256 = self.yield_amm.calc_withdraw_one_coin(
        _amount,
        convert(self.yield_amm_crvusd_index, int128),
    )
    gross_profit: uint256 = self._realized_contraction_profit(
        expected_crv_usd,
        trusted_removed,
        trusted_after,
    )
    exit_margin: uint256 = trusted_removed * self.normal_exit_min_profit_ppm / PPM
    assert gross_profit >= exit_margin
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    net_crv_usd: uint256 = expected_crv_usd - keeper_reward

    deployed_after: uint256 = 0
    if self.deployed_crvusd > net_crv_usd:
        deployed_after = self.deployed_crvusd - net_crv_usd
    assert trusted_after >= deployed_after
    return expected_crv_usd, gross_profit, keeper_reward


@external
@view
def previewExpansion(_amount: uint256) -> (uint256, uint256, uint256, uint256, uint256, bool):
    """
    @notice Estimates an expansion from current data; actual results may differ.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    self._require_expansion_regime()
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
    _yield_amm_execution_buffer_bps: uint256,
):
    """
    @notice Changes target-swap and yield-AMM execution buffers.
    """
    assert self._is_admin_or_factory(msg.sender)
    assert _target_amm_execution_buffer_bps <= BPS
    assert _yield_amm_execution_buffer_bps <= BPS

    self.target_amm_execution_buffer_bps = _target_amm_execution_buffer_bps
    self.yield_amm_execution_buffer_bps = _yield_amm_execution_buffer_bps

    log ExpansionConfigUpdated(
        _target_amm_execution_buffer_bps,
        _yield_amm_execution_buffer_bps,
    )


@internal
@view
def _lp_value_at(_lp_tokens: uint256, _virtual_price: uint256) -> uint256:
    return (
        _lp_tokens / PRECISION * _virtual_price
        + _lp_tokens % PRECISION * _virtual_price / PRECISION
    )


@internal
def _deposit_to_yield_amm(
    _crv_usd_amount: uint256,
    _yield_token_amount: uint256,
) -> uint256:
    amounts: DynArray[uint256, 2] = [0, 0]
    amounts[self.yield_amm_crvusd_index] = _crv_usd_amount
    amounts[self.yield_amm_yield_token_index] = _yield_token_amount
    quoted_lp: uint256 = self.yield_amm.calc_token_amount(amounts, True)
    min_lp: uint256 = quoted_lp * (BPS - self.yield_amm_execution_buffer_bps) / BPS

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    yield_before: uint256 = self._yield_token.balanceOf(self)
    lp_before: uint256 = self._lp_inventory()

    self._crv_usd.approve(self.yield_amm.address, 0)
    self._crv_usd.approve(self.yield_amm.address, _crv_usd_amount)
    ERC20(self._yield_token.address).approve(self.yield_amm.address, 0)
    ERC20(self._yield_token.address).approve(self.yield_amm.address, _yield_token_amount)
    self.yield_amm.add_liquidity(amounts, min_lp)
    self._crv_usd.approve(self.yield_amm.address, 0)
    ERC20(self._yield_token.address).approve(self.yield_amm.address, 0)

    assert crv_usd_before - self._crv_usd.balanceOf(self) == _crv_usd_amount
    assert yield_before - self._yield_token.balanceOf(self) == _yield_token_amount
    lp_received: uint256 = self._lp_inventory() - lp_before
    assert lp_received >= min_lp
    return lp_received


@internal
def _settle_lp_expansion(
    _lp_before: uint256,
    _lp_value_before: uint256,
    _donated_yield_value: uint256,
    _entry_donation_value: uint256,
    _principal: uint256,
    _lp_received: uint256,
) -> (uint256, uint256):
    lp_after_deposit: uint256 = self._lp_inventory()
    assert lp_after_deposit - _lp_before == _lp_received
    virtual_price_after: uint256 = self.yield_amm.get_virtual_price()
    lp_value_after: uint256 = self._lp_value_at(lp_after_deposit, virtual_price_after)
    accounting_baseline: uint256 = _lp_value_before + _donated_yield_value
    gross_profit: uint256 = 0
    if lp_value_after > accounting_baseline + _principal:
        gross_profit = lp_value_after - accounting_baseline - _principal

    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward: uint256 = keeper_reward_value * PRECISION / virtual_price_after
    assert keeper_reward <= _lp_received
    self._transfer_exact_to(ERC20(self.yield_amm.address), msg.sender, keeper_reward)

    retained_value: uint256 = self._lp_value(self._lp_inventory())
    entry_baseline: uint256 = _lp_value_before + _entry_donation_value
    assert retained_value >= entry_baseline
    assert self._meets_entry_floor(retained_value - entry_baseline, _principal)
    return gross_profit, keeper_reward


@external
@nonreentrant("lock")
def expand(_crv_usd_amount: uint256) -> (uint256, uint256, uint256, uint256, bool):
    """
    @notice Buys the yield token, matches it with crvUSD, and retains yield-AMM LP tokens.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _crv_usd_amount >= self.min_expansion_amount
    self._require_expansion_regime()
    self._target_price()
    self._yield_price()

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    target_before: uint256 = self._target_inventory()
    yield_before: uint256 = self._yield_inventory()
    lp_before: uint256 = self._lp_inventory()
    virtual_price_before: uint256 = self.yield_amm.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    donated_yield_value: uint256 = self._trusted_yield_value(yield_before)

    if self.target_amm.address == self.yield_amm.address:
        assert len(self.expansion_path) == 0
        assert self._target_asset.address == self._yield_token.address
        direct_crv_usd: uint256 = _crv_usd_amount + donated_yield_value
        assert direct_crv_usd <= crv_usd_before
        assert direct_crv_usd <= self._remaining_exposure_capacity()
        self._consume_velocity(direct_crv_usd)

        direct_lp_received: uint256 = self._deposit_to_yield_amm(
            direct_crv_usd,
            yield_before,
        )
        direct_gross_profit: uint256 = 0
        direct_reward: uint256 = 0
        direct_gross_profit, direct_reward = self._settle_lp_expansion(
            lp_before,
            lp_value_before,
            donated_yield_value,
            donated_yield_value,
            direct_crv_usd,
            direct_lp_received,
        )
        self.deployed_crvusd += direct_crv_usd
        assert self._trusted_backing_value() >= self.deployed_crvusd
        log Expanded(
            msg.sender,
            0,
            direct_crv_usd,
            direct_lp_received,
            direct_gross_profit,
            direct_reward,
            True,
        )
        return 0, direct_crv_usd, direct_lp_received, direct_reward, True

    crv_usd_sold: uint256 = 0
    target_received: uint256 = 0
    crv_usd_sold, target_received = self._target_amm_swap_exact_in(
        self._crv_usd,
        self._target_asset,
        convert(self.target_amm_crvusd_index, int128),
        convert(self.target_amm_target_index, int128),
        _crv_usd_amount,
        crv_usd_before,
        target_before,
    )

    path_length: uint256 = len(self.expansion_path)
    if path_length == 0:
        assert self._target_asset.address == self._yield_token.address
    else:
        self._execute_route(target_received)

    if self._target_asset.address != self._yield_token.address:
        assert self._target_inventory() == target_before
    yield_after_route: uint256 = self._yield_inventory()
    assert yield_after_route > yield_before
    fresh_yield_received: uint256 = yield_after_route - yield_before
    fresh_yield_value: uint256 = self._trusted_yield_value(fresh_yield_received)
    target_value: uint256 = self._normalize_target(target_received)
    self._checked_route_conversion_cost(target_value, fresh_yield_value)

    crv_usd_matched: uint256 = self._trusted_yield_value(yield_after_route)
    total_principal: uint256 = crv_usd_sold + crv_usd_matched
    assert total_principal <= crv_usd_before
    assert total_principal <= self._remaining_exposure_capacity()
    self._consume_velocity(total_principal)

    lp_received: uint256 = self._deposit_to_yield_amm(
        crv_usd_matched,
        yield_after_route,
    )
    assert self._yield_inventory() == 0
    assert crv_usd_before - self._crv_usd.balanceOf(self) == total_principal
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_yield_value,
        donated_yield_value,
        total_principal,
        lp_received,
    )

    self.deployed_crvusd += total_principal
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log Expanded(
        msg.sender,
        crv_usd_sold,
        crv_usd_matched,
        lp_received,
        gross_profit,
        keeper_reward,
        False,
    )
    return crv_usd_sold, crv_usd_matched, lp_received, keeper_reward, False


@internal
@view
def _donation_match_amount(_donated_yield_value: uint256) -> uint256:
    if self._aggregate_crvusd_price() >= PRECISION:
        return _donated_yield_value

    pool_crv_usd: uint256 = self.yield_amm.balances(self.yield_amm_crvusd_index)
    pool_yield_value: uint256 = self._trusted_yield_value(
        self.yield_amm.balances(self.yield_amm_yield_token_index)
    )
    yield_value_after: uint256 = pool_yield_value + _donated_yield_value
    if yield_value_after <= pool_crv_usd:
        return 0
    return min(_donated_yield_value, yield_value_after - pool_crv_usd)


@internal
def _settle_donated_yield(
    _max_yield_token_amount: uint256,
    _matching_budget: uint256,
    _require_minimum: bool,
) -> (uint256, uint256, uint256, uint256):
    yield_token_swept: uint256 = min(_max_yield_token_amount, self._yield_inventory())
    if yield_token_swept == 0:
        return 0, 0, 0, 0

    self._yield_price()
    donated_yield_value: uint256 = self._trusted_yield_value(yield_token_swept)
    if _require_minimum:
        assert donated_yield_value >= self.min_expansion_amount

    crv_usd_matched: uint256 = min(
        self._donation_match_amount(donated_yield_value),
        _matching_budget,
    )
    if crv_usd_matched > 0:
        assert crv_usd_matched <= self._crv_usd.balanceOf(self)
        assert crv_usd_matched <= self._remaining_exposure_capacity()
        self._consume_velocity(crv_usd_matched)

    lp_before: uint256 = self._lp_inventory()
    virtual_price_before: uint256 = self.yield_amm.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    lp_received: uint256 = self._deposit_to_yield_amm(
        crv_usd_matched,
        yield_token_swept,
    )
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_yield_value,
        0,
        crv_usd_matched,
        lp_received,
    )

    self.deployed_crvusd += crv_usd_matched
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log DonatedYieldSwept(
        msg.sender,
        yield_token_swept,
        crv_usd_matched,
        lp_received,
        gross_profit,
        keeper_reward,
    )
    return yield_token_swept, crv_usd_matched, lp_received, keeper_reward


@external
@nonreentrant("lock")
def sweepDonatedYield(_max_yield_token_amount: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Deposits donated yield and matches only the crvUSD appropriate for the current regime.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _max_yield_token_amount > 0

    matching_budget: uint256 = min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )
    return self._settle_donated_yield(
        _max_yield_token_amount,
        matching_budget,
        True,
    )


@external
@nonreentrant("lock")
def claimSurplus(_max_crv_usd_amount: uint256) -> uint256:
    """
    @notice Sends available crvUSD to the fee receiver when extra backing covers it, up to the caller's limit.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused

    yield_price: uint256 = self._yield_price()
    backing_before_sweep: uint256 = self._oracle_value(
        self._trusted_backing_value(),
        yield_price,
    )
    potential_surplus: uint256 = 0
    if backing_before_sweep > self.deployed_crvusd:
        potential_surplus = backing_before_sweep - self.deployed_crvusd
    donated_yield_value: uint256 = self._trusted_yield_value(self._yield_inventory())
    potential_surplus += self._oracle_value(donated_yield_value, yield_price)

    available_budget: uint256 = min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )
    claim_reserve: uint256 = min(
        _max_crv_usd_amount,
        min(potential_surplus, available_budget),
    )
    self._settle_donated_yield(
        self._yield_inventory(),
        available_budget - claim_reserve,
        False,
    )

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
    assert _step.token_in != self._crv_usd.address
    assert _step.token_out != self._crv_usd.address
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
):
    """
    @notice Replaces the token path used between the target asset and yield token.
    """
    assert self._is_admin_or_factory(msg.sender)
    assert _expansion_max_route_loss_bps <= BPS

    if self._target_asset.address == self._yield_token.address:
        assert len(_expansion_steps) == 0
    else:
        assert len(_expansion_steps) > 0
        assert _expansion_steps[0].token_in == self._target_asset.address
        expansion_last: RouteStep = _expansion_steps[len(_expansion_steps) - 1]
        assert expansion_last.token_out == self._yield_token.address

    self._validate_route_continuity(_expansion_steps)

    self.expansion_path = _expansion_steps
    self.expansion_max_route_loss_bps = _expansion_max_route_loss_bps
    log PathsUpdated(
        keccak256(_abi_encode(_expansion_steps)),
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
def expansion_path_step(_index: uint256) -> RouteStep:
    """
    @notice Returns one step from the post-expansion token path.
    """
    assert _index < len(self.expansion_path)
    return self.expansion_path[_index]


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
    else:
        quoted_output = ERC4626Route(_step.venue).previewRedeem(_amount_in)
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        ERC4626Route(_step.venue).redeem(_amount_in, self, self)

    token_in.approve(_step.venue, 0)
    input_balance_after: uint256 = token_in.balanceOf(self)
    output_balance_after: uint256 = token_out.balanceOf(self)
    assert input_balance_before - input_balance_after == _amount_in
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
def _execute_route(_initial_amount: uint256) -> uint256:
    amount_in: uint256 = _initial_amount
    for i in range(MAX_ROUTE_STEPS):
        if i >= len(self.expansion_path):
            break
        amount_in = self._execute_route_step(self.expansion_path[i], amount_in)
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
@nonreentrant("lock")
def contractViaAmm(_lp_token_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Burns held yield-AMM LP tokens and withdraws only crvUSD.
    """
    assert not self.all_execution_paused
    assert not self.yield_contraction_paused
    self._require_contraction_regime()
    lp_before: uint256 = self._lp_inventory()
    assert _lp_token_amount > 0 and _lp_token_amount <= lp_before

    virtual_price_before: uint256 = self.yield_amm.get_virtual_price()
    trusted_backing_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    quoted_crv_usd: uint256 = self.yield_amm.calc_withdraw_one_coin(
        _lp_token_amount,
        convert(self.yield_amm_crvusd_index, int128),
    )
    min_crv_usd: uint256 = quoted_crv_usd * (
        BPS - self.yield_amm_execution_buffer_bps
    ) / BPS
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)

    self.yield_amm.remove_liquidity_one_coin(
        _lp_token_amount,
        convert(self.yield_amm_crvusd_index, int128),
        min_crv_usd,
    )

    lp_after: uint256 = self._lp_inventory()
    assert lp_before - lp_after == _lp_token_amount
    crv_usd_after_swap: uint256 = self._crv_usd.balanceOf(self)
    crv_usd_received: uint256 = crv_usd_after_swap - crv_usd_before
    assert crv_usd_received >= min_crv_usd

    virtual_price_after: uint256 = self.yield_amm.get_virtual_price()
    trusted_backing_after: uint256 = self._lp_value_at(lp_after, virtual_price_after)
    assert trusted_backing_before >= trusted_backing_after
    trusted_value_removed: uint256 = trusted_backing_before - trusted_backing_after
    assert trusted_value_removed > 0

    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_keeper_contraction_and_reduce_exposure(
        crv_usd_before,
        crv_usd_after_swap,
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
    )
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log Contracted(
        msg.sender,
        _lp_token_amount,
        crv_usd_received,
        gross_profit,
        keeper_reward,
    )
    return _lp_token_amount, crv_usd_received, keeper_reward


@external
def reduce_deployed_crvusd(_amount: uint256):
    """
    @notice Lets the admin reduce the recorded externalized crvUSD amount, clamped at zero.
    """
    assert self._is_admin(msg.sender)

    reduction: uint256 = min(_amount, self.deployed_crvusd)
    self.deployed_crvusd -= reduction
    log DebtReduced(msg.sender, _amount, reduction, self.deployed_crvusd)


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
    _keeper_profit_share_bps: uint256,
    _min_expansion_amount: uint256,
    _max_deployed_crvusd: uint256,
):
    """
    @notice Changes profit, reward, minimum trade, and crvUSD limits.
    """
    assert self._is_admin(msg.sender)
    assert _normal_exit_min_profit_ppm <= PPM
    assert _normal_exit_min_profit_ppm >= _entry_min_profit_ppm
    assert _keeper_profit_share_bps <= BPS
    assert _min_expansion_amount > 0
    assert _max_deployed_crvusd > 0

    self.entry_min_profit_ppm = _entry_min_profit_ppm
    self.normal_exit_min_profit_ppm = _normal_exit_min_profit_ppm
    self.keeper_profit_share_bps = _keeper_profit_share_bps
    self.min_expansion_amount = _min_expansion_amount
    self.max_deployed_crvusd = _max_deployed_crvusd

    log PolicyUpdated(
        _entry_min_profit_ppm,
        _normal_exit_min_profit_ppm,
        _keeper_profit_share_bps,
        _min_expansion_amount,
        _max_deployed_crvusd,
    )


@external
def set_direction_paused(_direction: uint256, _paused: bool):
    """
    @notice Pauses or resumes expansion, contraction, or all execution.
    """
    admin: address = self._factory.admin()
    emergency_admin: address = self._factory.emergency_admin()
    assert msg.sender == admin or msg.sender == emergency_admin
    if msg.sender == emergency_admin:
        assert _paused

    if _direction == DIRECTION_EXPANSION:
        self.expansion_paused = _paused
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
    @notice Rejects unsupported calls.
    """
    raise
