# pragma version 0.3.10
"""
@title PegKeeper V3 Preview Module
@license MIT
@notice Calculates LP-backed PegKeeperV3 expansion estimates without trading.
"""

struct RouteStep:
    kind: uint256
    venue: address
    token_in: address
    token_out: address
    pool_index_in: int128
    pool_index_out: int128
    execution_buffer_bps: uint256

struct ExpansionPreview:
    target_out: uint256
    crv_usd_matched: uint256
    gross_profit: uint256
    keeper_reward: uint256
    lp_tokens_out: uint256
    direct_deposit: bool

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view

interface TwoCoinPool:
    def get_dy(_i: int128, _j: int128, _dx: uint256) -> uint256: view

interface YieldAmm:
    def get_virtual_price() -> uint256: view
    def calc_token_amount(_amounts: DynArray[uint256, 2], _is_deposit: bool) -> uint256: view

interface ControllerFactory:
    def debt_ceiling(_keeper: address) -> uint256: view

interface PriceOracle:
    def price() -> uint256: view

interface ERC4626Route:
    def convertToAssets(_shares: uint256) -> uint256: view
    def previewDeposit(_assets: uint256) -> uint256: view
    def previewRedeem(_shares: uint256) -> uint256: view

interface PegKeeperV3:
    def target_amm() -> address: view
    def target_amm_target_index() -> uint256: view
    def target_amm_crvusd_index() -> uint256: view
    def target_amm_execution_buffer_bps() -> uint256: view
    def target_asset() -> address: view
    def yield_amm() -> address: view
    def yield_amm_crvusd_index() -> uint256: view
    def yield_amm_yield_token_index() -> uint256: view
    def keeper_profit_share_bps() -> uint256: view
    def deployed_crvusd() -> uint256: view
    def min_expansion_amount() -> uint256: view
    def crv_usd() -> address: view
    def available_expansion_velocity() -> uint256: view
    def max_deployed_crvusd() -> uint256: view
    def controller_factory() -> address: view
    def target_oracle() -> address: view
    def min_target_oracle_price() -> uint256: view
    def expansion_path_length() -> uint256: view
    def expansion_path_step(_index: uint256) -> RouteStep: view
    def backing_asset() -> address: view
    def yield_oracle() -> address: view
    def min_yield_oracle_price() -> uint256: view
    def yield_token() -> address: view
    def yield_token_assets(_units: uint256) -> uint256: view
    def expansion_max_route_loss_bps() -> uint256: view
    def entry_min_profit_ppm() -> uint256: view

BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
PRECISION: constant(uint256) = 10 ** 18
MAX_ROUTE_STEPS: constant(uint256) = 16

STEP_CURVE_SWAP: constant(uint256) = 0
STEP_DAI_USDS_CONVERTER: constant(uint256) = 1
STEP_ERC4626_DEPOSIT: constant(uint256) = 2
STEP_ERC4626_REDEEM: constant(uint256) = 3
STEP_FRXUSD_MINT: constant(uint256) = 4

@external
@view
def previewExpansion(
    _keeper: address,
    _crv_usd_amount: uint256,
) -> (uint256, uint256, uint256, uint256, uint256, bool):
    """
    @notice Estimates an all-or-nothing LP expansion for the calling keeper.
    """
    assert _keeper == msg.sender
    quote: ExpansionPreview = self._preview_expansion(PegKeeperV3(_keeper), _crv_usd_amount)
    return (
        quote.target_out,
        quote.crv_usd_matched,
        quote.gross_profit,
        quote.keeper_reward,
        quote.lp_tokens_out,
        quote.direct_deposit,
    )

@internal
@view
def _preview_expansion(
    _keeper: PegKeeperV3,
    _crv_usd_amount: uint256,
) -> ExpansionPreview:
    assert _crv_usd_amount >= _keeper.min_expansion_amount()
    self._assert_oracle(_keeper.target_oracle(), _keeper.min_target_oracle_price())
    self._assert_yield_oracle(_keeper.yield_oracle(), _keeper.min_yield_oracle_price())

    quote: ExpansionPreview = empty(ExpansionPreview)
    yield_amm: YieldAmm = YieldAmm(_keeper.yield_amm())
    lp_before: uint256 = ERC20(_keeper.yield_amm()).balanceOf(_keeper.address)
    virtual_price: uint256 = yield_amm.get_virtual_price()
    lp_value_before: uint256 = self._lp_value(lp_before, virtual_price)
    amounts: DynArray[uint256, 2] = [0, 0]
    principal: uint256 = 0
    accounting_baseline: uint256 = lp_value_before

    if _keeper.target_amm() == _keeper.yield_amm():
        assert _keeper.expansion_path_length() == 0
        assert _keeper.target_asset() == _keeper.yield_token()
        donated_yield: uint256 = ERC20(_keeper.yield_token()).balanceOf(_keeper.address)
        donated_value: uint256 = self._trusted_yield_value(_keeper, donated_yield)
        quote.crv_usd_matched = _crv_usd_amount + donated_value
        quote.direct_deposit = True
        principal = quote.crv_usd_matched
        accounting_baseline += donated_value
        amounts[_keeper.yield_amm_crvusd_index()] = quote.crv_usd_matched
        amounts[_keeper.yield_amm_yield_token_index()] = donated_yield
    else:
        quote.target_out = TwoCoinPool(_keeper.target_amm()).get_dy(
            convert(_keeper.target_amm_crvusd_index(), int128),
            convert(_keeper.target_amm_target_index(), int128),
            _crv_usd_amount,
        )
        target_value: uint256 = self._normalize(quote.target_out, _keeper.target_asset())
        assert target_value >= _crv_usd_amount * (
            BPS - _keeper.target_amm_execution_buffer_bps()
        ) / BPS

        fresh_yield: uint256 = self._preview_expansion_route(_keeper, quote.target_out)
        assert fresh_yield > 0
        fresh_yield_value: uint256 = self._trusted_yield_value(_keeper, fresh_yield)
        conversion_cost: uint256 = 0
        if target_value > fresh_yield_value:
            conversion_cost = target_value - fresh_yield_value
        assert conversion_cost <= target_value * _keeper.expansion_max_route_loss_bps() / BPS

        donated_yield: uint256 = ERC20(_keeper.yield_token()).balanceOf(_keeper.address)
        total_yield: uint256 = donated_yield + fresh_yield
        quote.crv_usd_matched = self._trusted_yield_value(_keeper, total_yield)
        principal = _crv_usd_amount + quote.crv_usd_matched
        accounting_baseline += self._trusted_yield_value(_keeper, donated_yield)
        amounts[_keeper.yield_amm_crvusd_index()] = quote.crv_usd_matched
        amounts[_keeper.yield_amm_yield_token_index()] = total_yield

    assert principal <= ERC20(_keeper.crv_usd()).balanceOf(_keeper.address)
    assert principal <= _keeper.available_expansion_velocity()
    deployed_after: uint256 = _keeper.deployed_crvusd() + principal
    assert deployed_after <= _keeper.max_deployed_crvusd()
    assert deployed_after <= ControllerFactory(_keeper.controller_factory()).debt_ceiling(_keeper.address)

    quote.lp_tokens_out = yield_amm.calc_token_amount(amounts, True)
    lp_value_after: uint256 = self._lp_value(lp_before + quote.lp_tokens_out, virtual_price)
    assert lp_value_after >= accounting_baseline + principal
    quote.gross_profit = lp_value_after - accounting_baseline - principal
    reward_value: uint256 = quote.gross_profit * _keeper.keeper_profit_share_bps() / BPS
    quote.keeper_reward = reward_value * PRECISION / virtual_price
    assert quote.keeper_reward <= quote.lp_tokens_out

    retained_lp: uint256 = lp_before + quote.lp_tokens_out - quote.keeper_reward
    retained_value: uint256 = self._lp_value(retained_lp, virtual_price)
    assert retained_value >= accounting_baseline
    assert self._meets_entry_floor(
        _keeper,
        retained_value - accounting_baseline,
        principal,
    )
    assert retained_value >= deployed_after
    return quote

@internal
@view
def _preview_expansion_route(_keeper: PegKeeperV3, _amount: uint256) -> uint256:
    path_length: uint256 = _keeper.expansion_path_length()
    assert path_length <= MAX_ROUTE_STEPS
    if path_length == 0:
        assert _keeper.target_asset() == _keeper.yield_token()
        return _amount

    amount_out: uint256 = _amount
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        amount_out = self._preview_route_step(_keeper, _keeper.expansion_path_step(i), amount_out)
    return amount_out

@internal
@view
def _preview_route_step(
    _keeper: PegKeeperV3,
    _step: RouteStep,
    _amount_in: uint256,
) -> uint256:
    amount_out: uint256 = 0
    if _step.kind == STEP_CURVE_SWAP:
        amount_out = TwoCoinPool(_step.venue).get_dy(
            _step.pool_index_in,
            _step.pool_index_out,
            _amount_in,
        )
    elif _step.kind == STEP_DAI_USDS_CONVERTER:
        amount_out = _amount_in
    elif _step.kind == STEP_ERC4626_DEPOSIT or _step.kind == STEP_FRXUSD_MINT:
        amount_out = ERC4626Route(_step.venue).previewDeposit(_amount_in)
    elif _step.kind == STEP_ERC4626_REDEEM:
        amount_out = ERC4626Route(_step.venue).previewRedeem(_amount_in)
    else:
        raise

    input_value: uint256 = 0
    output_value: uint256 = 0
    if _step.kind == STEP_ERC4626_DEPOSIT:
        input_value = self._normalize(_amount_in, _step.token_in)
        output_value = self._normalize(
            ERC4626Route(_step.venue).convertToAssets(amount_out),
            _step.token_in,
        )
    elif _step.kind == STEP_ERC4626_REDEEM:
        input_value = self._normalize(
            ERC4626Route(_step.venue).convertToAssets(_amount_in),
            _step.token_out,
        )
        output_value = self._normalize(amount_out, _step.token_out)
    elif _step.token_out == _keeper.yield_token():
        input_value = self._normalize(_amount_in, _step.token_in)
        output_value = self._trusted_yield_value(_keeper, amount_out)
    else:
        input_value = self._normalize(_amount_in, _step.token_in)
        output_value = self._normalize(amount_out, _step.token_out)
    assert output_value >= input_value * (BPS - _step.execution_buffer_bps) / BPS
    return amount_out

@internal
@view
def _trusted_yield_value(_keeper: PegKeeperV3, _units: uint256) -> uint256:
    return _keeper.yield_token_assets(_units) * self._multiplier(_keeper.backing_asset())

@internal
@pure
def _lp_value(_lp_tokens: uint256, _virtual_price: uint256) -> uint256:
    return (
        _lp_tokens / PRECISION * _virtual_price
        + _lp_tokens % PRECISION * _virtual_price / PRECISION
    )

@internal
@view
def _assert_oracle(_oracle: address, _minimum: uint256):
    assert PriceOracle(_oracle).price() >= _minimum


@internal
@view
def _assert_yield_oracle(_oracle: address, _minimum: uint256):
    ok: bool = False
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        _oracle,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        raise
    assert convert(slice(response, 0, 32), uint256) >= _minimum

@internal
@view
def _meets_entry_floor(
    _keeper: PegKeeperV3,
    _retained_value: uint256,
    _principal: uint256,
) -> bool:
    if _retained_value < _principal:
        return False
    profit: uint256 = _retained_value - _principal
    ppm: uint256 = _keeper.entry_min_profit_ppm()
    required: uint256 = _principal / PPM * ppm + _principal % PPM * ppm / PPM
    return profit >= required

@internal
@view
def _normalize(_amount: uint256, _token: address) -> uint256:
    return _amount * self._multiplier(_token)

@internal
@view
def _multiplier(_token: address) -> uint256:
    decimals: uint256 = ERC20(_token).decimals()
    assert decimals <= 18
    return 10 ** (18 - decimals)
