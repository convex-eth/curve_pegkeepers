# pragma version 0.3.10
"""
@title PegKeeper V3 Preview Module
@license MIT
@notice Shared stateless quote engine for PegKeeperV3 minimal proxies
@dev Keepers preserve their public preview selectors and forward view computation here.
"""


struct RouteStep:
    kind: uint256
    venue: address
    token_in: address
    token_out: address
    pool_index_in: int128
    pool_index_out: int128
    execution_buffer_bps: uint256


struct ExpansionRoutePreview:
    backing_asset_out: uint256
    gross_profit: uint256
    keeper_reward: uint256
    yield_token_out: uint256
    deploy_to_yield: bool


struct ExpansionPreview:
    target_out: uint256
    backing_asset_out: uint256
    gross_profit: uint256
    keeper_reward: uint256
    yield_token_out: uint256
    deploy_to_yield: bool


interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view


interface TwoCoinPool:
    def get_dy(_i: int128, _j: int128, _dx: uint256) -> uint256: view


interface ControllerFactory:
    def debt_ceiling(_keeper: address) -> uint256: view


interface YieldToken:
    def convertToAssets(_shares: uint256) -> uint256: view


interface PriceOracle:
    def price() -> uint256: view


interface ERC4626Route:
    def previewDeposit(_assets: uint256) -> uint256: view
    def previewRedeem(_shares: uint256) -> uint256: view


interface PegKeeperV3:
    def undeployed_backing() -> uint256: view
    def target_amm() -> address: view
    def target_amm_target_index() -> uint256: view
    def target_amm_crvusd_index() -> uint256: view
    def target_asset() -> address: view
    def trusted_backing_value() -> uint256: view
    def keeper_profit_share_bps() -> uint256: view
    def accounted_yield_token_units() -> uint256: view
    def contraction_path_length() -> uint256: view
    def contraction_path_step(_index: uint256) -> RouteStep: view
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
    def expansion_max_route_loss_bps() -> uint256: view
    def entry_min_profit_ppm() -> uint256: view
    def last_expansion_at() -> uint256: view
    def min_deployment_time() -> uint256: view


BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
PRECISION: constant(uint256) = 10 ** 18
MAX_ROUTE_STEPS: constant(uint256) = 16

STEP_CURVE_SWAP: constant(uint256) = 0
STEP_DAI_USDS_CONVERTER: constant(uint256) = 1
STEP_ERC4626_DEPOSIT: constant(uint256) = 2
STEP_FRXUSD_MINT: constant(uint256) = 4


@external
@view
def previewUndeployedContraction(
    _keeper: address,
    _target_amount: uint256,
) -> (uint256, uint256, uint256, bool):
    assert _keeper == msg.sender
    keeper: PegKeeperV3 = PegKeeperV3(_keeper)
    assert _target_amount > 0 and _target_amount <= keeper.undeployed_backing()

    expected_crv_usd: uint256 = TwoCoinPool(keeper.target_amm()).get_dy(
        convert(keeper.target_amm_target_index(), int128),
        convert(keeper.target_amm_crvusd_index(), int128),
        _target_amount,
    )
    target_value: uint256 = self._normalize(_target_amount, keeper.target_asset())
    trusted_backing_after: uint256 = keeper.trusted_backing_value() - target_value
    gross_profit: uint256 = self._realized_contraction_profit(
        keeper,
        expected_crv_usd,
        target_value,
        trusted_backing_after,
    )
    keeper_reward: uint256 = gross_profit * keeper.keeper_profit_share_bps() / BPS
    return expected_crv_usd, gross_profit, keeper_reward, self._is_early_exit(keeper)


@external
@view
def previewKeeperBuyback(
    _keeper: address,
    _yield_token_amount: uint256,
) -> (uint256, uint256, uint256, bool):
    assert _keeper == msg.sender
    keeper: PegKeeperV3 = PegKeeperV3(_keeper)
    accounted: uint256 = keeper.accounted_yield_token_units()
    assert _yield_token_amount > 0 and _yield_token_amount <= accounted
    path_length: uint256 = keeper.contraction_path_length()
    assert path_length > 0 and path_length <= MAX_ROUTE_STEPS

    trusted_before: uint256 = self._trusted_yield_value(keeper, accounted)
    trusted_after: uint256 = self._trusted_yield_value(keeper, accounted - _yield_token_amount)
    trusted_removed: uint256 = trusted_before - trusted_after
    assert trusted_removed <= keeper.deployed_crvusd()

    expected_crv_usd: uint256 = _yield_token_amount
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        expected_crv_usd = self._preview_route_step(
            keeper.contraction_path_step(i),
            expected_crv_usd,
        )

    trusted_backing_after: uint256 = keeper.trusted_backing_value() - trusted_removed
    gross_profit: uint256 = self._realized_contraction_profit(
        keeper,
        expected_crv_usd,
        trusted_removed,
        trusted_backing_after,
    )
    keeper_reward: uint256 = gross_profit * keeper.keeper_profit_share_bps() / BPS
    return expected_crv_usd, gross_profit, keeper_reward, self._is_early_exit(keeper)


@external
@view
def previewExpansion(
    _keeper: address,
    _crv_usd_amount: uint256,
) -> (uint256, uint256, uint256, uint256, uint256, bool):
    assert _keeper == msg.sender
    quote: ExpansionPreview = self._preview_expansion(_keeper, _crv_usd_amount)
    return (
        quote.target_out,
        quote.backing_asset_out,
        quote.gross_profit,
        quote.keeper_reward,
        quote.yield_token_out,
        quote.deploy_to_yield,
    )


@internal
@view
def _preview_expansion(
    _keeper: address,
    _crv_usd_amount: uint256,
) -> ExpansionPreview:
    keeper: PegKeeperV3 = PegKeeperV3(_keeper)
    assert _crv_usd_amount >= keeper.min_expansion_amount()
    assert _crv_usd_amount <= ERC20(keeper.crv_usd()).balanceOf(_keeper)
    assert _crv_usd_amount <= keeper.available_expansion_velocity()
    deployed_after: uint256 = keeper.deployed_crvusd() + _crv_usd_amount
    assert deployed_after <= keeper.max_deployed_crvusd()
    assert deployed_after <= ControllerFactory(keeper.controller_factory()).debt_ceiling(_keeper)

    target_price: uint256 = PriceOracle(keeper.target_oracle()).price()
    assert target_price >= keeper.min_target_oracle_price()

    quote: ExpansionPreview = empty(ExpansionPreview)
    quote.target_out = TwoCoinPool(keeper.target_amm()).get_dy(
        convert(keeper.target_amm_crvusd_index(), int128),
        convert(keeper.target_amm_target_index(), int128),
        _crv_usd_amount,
    )
    route: ExpansionRoutePreview = self._preview_expansion_route(
        keeper,
        quote.target_out,
        _crv_usd_amount,
        target_price,
    )
    quote.backing_asset_out = route.backing_asset_out
    quote.gross_profit = route.gross_profit
    quote.keeper_reward = route.keeper_reward
    quote.yield_token_out = route.yield_token_out
    quote.deploy_to_yield = route.deploy_to_yield

    trusted_backing_before: uint256 = keeper.trusted_backing_value()
    if quote.deploy_to_yield:
        assert trusted_backing_before + self._trusted_yield_value(keeper, quote.yield_token_out) >= deployed_after
        return quote

    target_multiplier: uint256 = self._multiplier(keeper.target_asset())
    target_value: uint256 = self._oracle_value(quote.target_out * target_multiplier, target_price)
    if target_value > _crv_usd_amount:
        quote.gross_profit = target_value - _crv_usd_amount
    else:
        quote.gross_profit = 0
    quote.keeper_reward = (
        quote.gross_profit * keeper.keeper_profit_share_bps() / BPS / target_multiplier
    )
    assert quote.keeper_reward <= quote.target_out
    retained: uint256 = quote.target_out - quote.keeper_reward
    assert self._meets_entry_floor(
        keeper,
        self._oracle_value(retained * target_multiplier, target_price),
        _crv_usd_amount,
    )
    assert trusted_backing_before + retained * target_multiplier >= deployed_after
    quote.backing_asset_out = 0
    quote.yield_token_out = 0
    return quote


@internal
@view
def _preview_expansion_route(
    _keeper: PegKeeperV3,
    _target_amount: uint256,
    _crv_usd_amount: uint256,
    _target_price: uint256,
) -> ExpansionRoutePreview:
    quote: ExpansionRoutePreview = empty(ExpansionRoutePreview)
    path_length: uint256 = _keeper.expansion_path_length()
    assert path_length <= MAX_ROUTE_STEPS
    if path_length == 0:
        return quote

    yield_price: uint256 = 0
    healthy: bool = False
    yield_price, healthy = self._read_yield_price(_keeper)
    if not healthy:
        return quote

    amount_out: uint256 = _target_amount
    backing_multiplier: uint256 = self._multiplier(_keeper.backing_asset())
    for i in range(MAX_ROUTE_STEPS):
        if i >= path_length:
            break
        step: RouteStep = _keeper.expansion_path_step(i)
        if i == path_length - 1:
            quote.backing_asset_out = amount_out
            backing_value: uint256 = self._oracle_value(
                quote.backing_asset_out * backing_multiplier,
                yield_price,
            )
            if backing_value > _crv_usd_amount:
                quote.gross_profit = backing_value - _crv_usd_amount
            quote.keeper_reward = self._backing_reward(
                _keeper,
                quote.gross_profit,
                backing_multiplier,
            )
            if quote.keeper_reward > quote.backing_asset_out:
                return quote
            amount_out = quote.backing_asset_out - quote.keeper_reward
        amount_out = self._preview_route_step(step, amount_out)

    quote.yield_token_out = amount_out
    if quote.yield_token_out == 0:
        return quote

    trusted_yield_value: uint256 = self._oracle_value(
        self._trusted_yield_value(_keeper, quote.yield_token_out),
        yield_price,
    )
    target_value: uint256 = self._oracle_value(
        _target_amount * self._multiplier(_keeper.target_asset()),
        _target_price,
    )
    retained_route_value: uint256 = trusted_yield_value + self._oracle_value(
        quote.keeper_reward * backing_multiplier,
        yield_price,
    )
    conversion_cost: uint256 = 0
    if target_value > retained_route_value:
        conversion_cost = target_value - retained_route_value
    if conversion_cost > target_value * _keeper.expansion_max_route_loss_bps() / BPS:
        return quote
    if not self._meets_entry_floor(_keeper, trusted_yield_value, _crv_usd_amount):
        return quote
    quote.deploy_to_yield = True
    return quote


@internal
@view
def _backing_reward(
    _keeper: PegKeeperV3,
    _gross_profit: uint256,
    _backing_multiplier: uint256,
) -> uint256:
    return _gross_profit * _keeper.keeper_profit_share_bps() / BPS / _backing_multiplier


@internal
@view
def _preview_route_step(_step: RouteStep, _amount_in: uint256) -> uint256:
    if _step.kind == STEP_CURVE_SWAP:
        return TwoCoinPool(_step.venue).get_dy(
            _step.pool_index_in,
            _step.pool_index_out,
            _amount_in,
        )
    if _step.kind == STEP_DAI_USDS_CONVERTER:
        return _amount_in
    if _step.kind == STEP_ERC4626_DEPOSIT or _step.kind == STEP_FRXUSD_MINT:
        return ERC4626Route(_step.venue).previewDeposit(_amount_in)
    return ERC4626Route(_step.venue).previewRedeem(_amount_in)


@internal
@view
def _read_yield_price(_keeper: PegKeeperV3) -> (uint256, bool):
    ok: bool = False
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        _keeper.yield_oracle(),
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        return 0, False
    price: uint256 = convert(slice(response, 0, 32), uint256)
    return price, price >= _keeper.min_yield_oracle_price()


@internal
@view
def _trusted_yield_value(_keeper: PegKeeperV3, _shares: uint256) -> uint256:
    return YieldToken(_keeper.yield_token()).convertToAssets(_shares) * self._multiplier(
        _keeper.backing_asset()
    )


@internal
@view
def _realized_contraction_profit(
    _keeper: PegKeeperV3,
    _received: uint256,
    _trusted_removed: uint256,
    _trusted_backing_after: uint256,
) -> uint256:
    principal_recovery: uint256 = _trusted_removed
    deployed: uint256 = _keeper.deployed_crvusd()
    if deployed > _trusted_backing_after:
        solvency_recovery: uint256 = deployed - _trusted_backing_after
        if solvency_recovery > principal_recovery:
            principal_recovery = solvency_recovery
    if _received <= principal_recovery:
        return 0
    return _received - principal_recovery


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
def _is_early_exit(_keeper: PegKeeperV3) -> bool:
    return (
        _keeper.deployed_crvusd() > 0
        and block.timestamp < _keeper.last_expansion_at() + _keeper.min_deployment_time()
    )


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


@internal
@pure
def _oracle_value(_value: uint256, _price: uint256) -> uint256:
    capped_price: uint256 = min(_price, PRECISION)
    return _value / PRECISION * capped_price + _value % PRECISION * capped_price / PRECISION
