# pragma version 0.3.10
"""
@title PegKeeper V3
@license MIT
@notice Adds and removes direct Curve liquidity to help keep crvUSD near its target price.
@dev Holds LP backing, accounts crvUSD debt, and delegates admission to Factory policy.
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def approve(_spender: address, _amount: uint256): nonpayable
    def transfer(_recipient: address, _amount: uint256): nonpayable

interface ControllerFactory:
    def stablecoin() -> address: view
    def debt_ceiling(_account: address) -> uint256: view

interface PegKeeperFactory:
    def controllerFactory() -> address: view
    def admin() -> address: view
    def emergency_admin() -> address: view
    def fee_receiver() -> address: view
    def policy() -> address: view

interface PegKeeperPolicy:
    def expansion_regime() -> bool: view
    def can_allocate(_keeper: address) -> bool: view
    def can_expand(_keeper: address) -> bool: view
    def can_contract(_keeper: address) -> bool: view

interface Pool:
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

interface PairedToken:
    def asset() -> address: view
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def convertToAssets(_paired_token_amount: uint256) -> uint256: view
    def convertToShares(_assets: uint256) -> uint256: view

interface PriceOracle:
    def price() -> uint256: view


event DirectionPaused:
    direction: indexed(uint256)
    paused: bool

event Executed:
    target: indexed(address)
    value: uint256
    selector: indexed(bytes4)
    data_hash: bytes32

event AmmExecutionBufferUpdated:
    execution_buffer_bps: uint256

event Expanded:
    keeper: indexed(address)
    crv_usd_deployed: uint256
    lp_tokens_received: uint256
    gross_profit: uint256
    keeper_reward: uint256

event DonatedPairedTokenSwept:
    keeper: indexed(address)
    paired_token_swept: uint256
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

event ProfitWithdrawn:
    caller: indexed(address)
    receiver: indexed(address)
    crv_usd_transferred: uint256
    deployed_crv_usd_after: uint256

event DebtReduced:
    caller: indexed(address)
    requested_reduction: uint256
    actual_reduction: uint256
    deployed_crv_usd_after: uint256

event CrvUsdBorrowed:
    caller: indexed(address)
    receiver: indexed(address)
    amount: uint256
    deployed_crv_usd_after: uint256


event PolicyUpdated:
    entry_min_profit_ppm: uint256
    normal_exit_min_profit_ppm: uint256
    keeper_profit_share_bps: uint256
    min_expansion_amount: uint256
    max_deployed_crvusd: uint256

event InterventionPolicyUpdated:
    max_intervention_share_bps: uint256
    min_intervention_delay: uint256

event BackingOraclePolicyUpdated:
    backing_oracle: indexed(address)
    min_backing_price: uint256



version: public(constant(String[8])) = "3.4.0"
name: public(String[88])
keeper_index: public(uint256)

BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
PRECISION: constant(uint256) = 10 ** 18
DEFAULT_MIN_BACKING_ORACLE_PRICE: constant(uint256) = 999_000_000_000_000_000
max_expansion_burst_bps: public(constant(uint256)) = 500
expansion_refill_period: public(constant(uint256)) = 5 * 60

DIRECTION_EXPANSION: constant(uint256) = 0
DIRECTION_CONTRACTION: constant(uint256) = 1
DIRECTION_ALL: constant(uint256) = 2

_factory: PegKeeperFactory
_controller_factory: ControllerFactory
_crv_usd: ERC20
_backing_asset: ERC20
_paired_token: PairedToken
pool: public(Pool)
paired_token_is_erc4626: public(bool)
backing_multiplier: uint256
backing_oracle: public(PriceOracle)
min_backing_oracle_price: public(uint256)
initialized: public(bool)

pool_crvusd_index: public(uint256)
pool_paired_token_index: public(uint256)

entry_min_profit_ppm: public(uint256)
normal_exit_min_profit_ppm: public(uint256)
keeper_profit_share_bps: public(uint256)
min_expansion_amount: public(uint256)
max_deployed_crvusd: public(uint256)
max_intervention_share_bps: public(uint256)
min_intervention_delay: public(uint256)
last_intervention_at: public(uint256)
amm_execution_buffer_bps: public(uint256)

deployed_crvusd: public(uint256)
_expansion_pressure: uint256
last_expansion_pressure_update: public(uint256)

expansion_paused: public(bool)
contraction_paused: public(bool)
all_execution_paused: public(bool)


@external
def __init__():
    """
    @notice Prevents the base contract from being set up as a keeper.
    """
    # Lock the standalone implementation. Proxies have independent zeroed storage.
    self.initialized = True
    self.expansion_paused = True
    self.contraction_paused = True
    self.all_execution_paused = True


@external
def initialize(
    _backing_asset: ERC20,
    _paired_token: PairedToken,
    _pool: Pool,
    _max_deployed_crvusd: uint256,
    _keeper_index: uint256,
    _backing_oracle: PriceOracle,
):
    """
    @notice Sets up a new keeper with one direct pool, its paired token, limits, and oracle.
    """
    assert not self.initialized
    self.initialized = True
    assert msg.sender.codesize > 0
    assert _backing_asset.address != empty(address)
    assert _paired_token.address != empty(address)
    assert _pool.address != empty(address)
    assert _pool.address.codesize > 0
    assert _max_deployed_crvusd > 0
    assert _keeper_index > 0
    assert _backing_oracle.address != empty(address)
    assert _backing_oracle.address.codesize > 0

    controller_factory: address = PegKeeperFactory(msg.sender).controllerFactory()
    assert controller_factory != empty(address)
    crv_usd: address = ControllerFactory(controller_factory).stablecoin()
    assert crv_usd != empty(address)
    assert crv_usd != _paired_token.address
    is_erc4626: bool = _paired_token.address != _backing_asset.address
    if is_erc4626:
        assert _paired_token.asset() == _backing_asset.address
        assert _paired_token.convertToAssets(0) == 0
        assert _paired_token.convertToShares(0) == 0

    crv_decimals: uint256 = ERC20(crv_usd).decimals()
    backing_decimals: uint256 = _backing_asset.decimals()
    assert crv_decimals == 18
    assert backing_decimals <= 18
    assert ERC20(_pool.address).decimals() == 18

    coin_0: address = _pool.coins(0)
    coin_1: address = _pool.coins(1)
    if coin_0 == crv_usd and coin_1 == _paired_token.address:
        self.pool_crvusd_index = 0
        self.pool_paired_token_index = 1
    elif coin_0 == _paired_token.address and coin_1 == crv_usd:
        self.pool_crvusd_index = 1
        self.pool_paired_token_index = 0
    else:
        raise
    assert _pool.get_virtual_price() > 0

    self._factory = PegKeeperFactory(msg.sender)
    self._controller_factory = ControllerFactory(controller_factory)
    self._crv_usd = ERC20(crv_usd)
    self._backing_asset = _backing_asset
    self._paired_token = _paired_token
    self.pool = _pool
    self.paired_token_is_erc4626 = is_erc4626
    self.backing_multiplier = 10 ** (18 - backing_decimals)
    self.backing_oracle = _backing_oracle
    self.min_backing_oracle_price = DEFAULT_MIN_BACKING_ORACLE_PRICE

    self.keeper_index = _keeper_index
    self.name = concat("Pegkeeper ", uint2str(_keeper_index))
    self.entry_min_profit_ppm = 10
    self.normal_exit_min_profit_ppm = 500
    self.keeper_profit_share_bps = 3_000
    self.min_expansion_amount = 10_000 * 10 ** 18
    self.max_deployed_crvusd = _max_deployed_crvusd
    self.max_intervention_share_bps = 3_333
    self.min_intervention_delay = 12
    self.last_expansion_pressure_update = block.timestamp

    self.expansion_paused = True
    self.contraction_paused = True
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
    @notice Returns the account that receives withdrawn protocol profit.
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
@view
def backing_asset() -> address:
    """
    @notice Returns the asset denomination used to match loose paired tokens with crvUSD.
    """
    return self._backing_asset.address


@external
@view
def paired_token() -> address:
    """
    @notice Returns the non-crvUSD token in the configured pool.
    """
    return self._paired_token.address


@internal
@view
def _paired_token_assets(_units: uint256) -> uint256:
    if self.paired_token_is_erc4626:
        return self._paired_token.convertToAssets(_units)
    return _units


@internal
@view
def _paired_token_units(_assets: uint256) -> uint256:
    if self.paired_token_is_erc4626:
        return self._paired_token.convertToShares(_assets)
    return _assets


@external
@view
def paired_token_assets(_units: uint256) -> uint256:
    """
    @notice Returns the backing-asset amount represented by a paired-token amount.
    """
    return self._paired_token_assets(_units)


@external
@view
def paired_token_units(_assets: uint256) -> uint256:
    """
    @notice Returns the paired-token amount represented by a backing-asset amount.
    """
    return self._paired_token_units(_assets)


@internal
@view
def _paired_token_inventory() -> uint256:
    return self._paired_token.balanceOf(self)


@internal
@view
def _lp_inventory() -> uint256:
    return self.pool.balanceOf(self)


@internal
@view
def _lp_value(_lp_tokens: uint256) -> uint256:
    virtual_price: uint256 = self.pool.get_virtual_price()
    return (
        _lp_tokens / PRECISION * virtual_price
        + _lp_tokens % PRECISION * virtual_price / PRECISION
    )


@external
@view
def accounted_lp_tokens() -> uint256:
    """
    @notice Returns the complete held balance of pool LP tokens.
    """
    return self._lp_inventory()


@external
@view
def coins(_index: uint256) -> address:
    """
    @notice Returns crvUSD for index 0 and the held pool LP token for index 1.
    """
    if _index == 0:
        return self._crv_usd.address
    assert _index == 1
    return self.pool.address


@internal
@pure
def _oracle_value(_value: uint256, _price: uint256) -> uint256:
    price: uint256 = min(_price, PRECISION)
    return _value / PRECISION * price + _value % PRECISION * price / PRECISION


@internal
@view
def _backing_price() -> uint256:
    ok: bool = False
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        self.backing_oracle.address,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        raise
    price: uint256 = convert(slice(response, 0, 32), uint256)
    assert price >= self.min_backing_oracle_price
    return price


@internal
@view
def _policy_address() -> address:
    policy: address = self._factory.policy()
    assert policy != empty(address) and policy.codesize > 0
    return policy


@internal
@view
def _require_expansion_policy():
    assert PegKeeperPolicy(self._policy_address()).can_expand(self)


@internal
@view
def _require_contraction_policy():
    assert PegKeeperPolicy(self._policy_address()).can_contract(self)


@internal
@view
def _allocation_allowed() -> bool:
    policy: address = self._factory.policy()
    if policy == empty(address) or policy.codesize == 0:
        return False

    ok: bool = False
    response: Bytes[64] = empty(Bytes[64])
    ok, response = raw_call(
        policy,
        _abi_encode(self, method_id=method_id("can_allocate(address)")),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(response) != 32:
        return False
    return convert(slice(response, 0, 32), uint256) == 1


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
    price: uint256 = self._backing_price()
    return self._oracle_value(self._trusted_backing_value(), price)


@internal
@view
def _trusted_paired_token_value(_paired_token_units: uint256) -> uint256:
    return self._normalize_backing(self._paired_token_assets(_paired_token_units))


@external
@view
def trusted_backing_value() -> uint256:
    """
    @notice Returns the held pool LP balance valued at the current virtual price.
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


@internal
@view
def _local_expansion_limit() -> uint256:
    crv_usd_balance: uint256 = self.pool.balances(self.pool_crvusd_index)
    paired_token_balance: uint256 = self._trusted_paired_token_value(
        self.pool.balances(self.pool_paired_token_index)
    )
    if paired_token_balance <= crv_usd_balance:
        return 0
    return (paired_token_balance - crv_usd_balance) * self.max_intervention_share_bps / BPS


@internal
@view
def _local_contraction_limit() -> uint256:
    crv_usd_balance: uint256 = self.pool.balances(self.pool_crvusd_index)
    paired_token_balance: uint256 = self._trusted_paired_token_value(
        self.pool.balances(self.pool_paired_token_index)
    )
    if crv_usd_balance <= paired_token_balance:
        return 0
    return (crv_usd_balance - paired_token_balance) * self.max_intervention_share_bps / BPS


@internal
@view
def _intervention_delay_elapsed() -> bool:
    last_intervention_at: uint256 = self.last_intervention_at
    if last_intervention_at == 0:
        return True
    if block.timestamp < last_intervention_at:
        return False
    return block.timestamp - last_intervention_at >= self.min_intervention_delay


@internal
@view
def _available_expansion_without_policy() -> uint256:
    if self.all_execution_paused or self.expansion_paused:
        return 0
    if not self._intervention_delay_elapsed():
        return 0
    return min(
        self._local_expansion_limit(),
        min(
            self._crv_usd.balanceOf(self),
            min(self._available_velocity(), self._remaining_exposure_capacity()),
        ),
    )


@external
@view
def can_expand_without_policy() -> bool:
    """
    @notice Reports whether the configured minimum expansion is locally executable, excluding system policy.
    """
    amount: uint256 = self.min_expansion_amount
    if amount == 0 or self._available_expansion_without_policy() < amount:
        return False

    ok: bool = False
    oracle_response: Bytes[64] = empty(Bytes[64])
    ok, oracle_response = raw_call(
        self.backing_oracle.address,
        method_id("price()"),
        max_outsize=64,
        is_static_call=True,
        revert_on_failure=False,
    )
    if not ok or len(oracle_response) != 32:
        return False
    if convert(slice(oracle_response, 0, 32), uint256) < self.min_backing_oracle_price:
        return False

    return self._expansion_preview_viable(amount)


@external
@view
def available_expansion() -> uint256:
    """
    @notice Returns the most crvUSD that can be used for a policy-approved expansion now.
    """
    if not PegKeeperPolicy(self._policy_address()).can_expand(self):
        return 0
    return self._available_expansion_without_policy()


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
def _settle_keeper_contraction_and_reduce_exposure(
    _crv_usd_before: uint256,
    _crv_usd_after_withdrawal: uint256,
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
    assert _crv_usd_after_withdrawal - crv_usd_after_reward == keeper_reward
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
def preview_contraction(_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Estimates burning pool LP tokens to withdraw crvUSD.
    """
    assert not self.all_execution_paused
    assert not self.contraction_paused
    self._require_contraction_policy()
    assert self._intervention_delay_elapsed()

    accounted: uint256 = self._lp_inventory()
    assert _amount > 0 and _amount <= accounted
    virtual_price: uint256 = self.pool.get_virtual_price()
    trusted_before: uint256 = self._lp_value_at(accounted, virtual_price)
    trusted_after: uint256 = self._lp_value_at(accounted - _amount, virtual_price)
    trusted_removed: uint256 = trusted_before - trusted_after
    expected_crv_usd: uint256 = self.pool.calc_withdraw_one_coin(
        _amount,
        convert(self.pool_crvusd_index, int128),
    )
    assert expected_crv_usd <= self._local_contraction_limit()
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
def preview_expansion(_amount: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Estimates an expansion from current data; actual results may differ.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    self._require_expansion_policy()
    assert self._intervention_delay_elapsed()
    assert _amount <= self._local_expansion_limit()
    return self._preview_expansion(_amount)


@external
def set_backing_oracle_policy(
    _backing_oracle: PriceOracle,
    _min_backing_price: uint256,
):
    """
    @notice Changes the retained-backing price source and lowest accepted price.
    """
    assert self._is_admin(msg.sender)
    assert _backing_oracle.address != empty(address)
    assert _backing_oracle.address.codesize > 0
    assert _min_backing_price > 0 and _min_backing_price <= PRECISION

    self.backing_oracle = _backing_oracle
    self.min_backing_oracle_price = _min_backing_price
    log BackingOraclePolicyUpdated(
        _backing_oracle.address,
        _min_backing_price,
    )


@external
def set_amm_execution_buffer(_execution_buffer_bps: uint256):
    """
    @notice Changes the largest allowed drop below the AMM's LP quote.
    """
    assert self._is_admin_or_factory(msg.sender)
    assert _execution_buffer_bps <= BPS

    self.amm_execution_buffer_bps = _execution_buffer_bps
    log AmmExecutionBufferUpdated(_execution_buffer_bps)


@internal
@view
def _lp_value_at(_lp_tokens: uint256, _virtual_price: uint256) -> uint256:
    return (
        _lp_tokens / PRECISION * _virtual_price
        + _lp_tokens % PRECISION * _virtual_price / PRECISION
    )


@internal
@view
def _expansion_preview_viable(_crv_usd_amount: uint256) -> bool:
    lp_before: uint256 = self._lp_inventory()
    virtual_price: uint256 = self.pool.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price)
    donated_paired_token: uint256 = self._paired_token_inventory()
    donated_value: uint256 = self._trusted_paired_token_value(donated_paired_token)
    crv_usd_deployed: uint256 = _crv_usd_amount + donated_value

    if crv_usd_deployed > self._crv_usd.balanceOf(self):
        return False
    if crv_usd_deployed > self._available_velocity():
        return False
    deployed_after: uint256 = self.deployed_crvusd + crv_usd_deployed
    if deployed_after > self.max_deployed_crvusd:
        return False
    if deployed_after > self._controller_factory.debt_ceiling(self):
        return False

    amounts: DynArray[uint256, 2] = [0, 0]
    amounts[self.pool_crvusd_index] = crv_usd_deployed
    amounts[self.pool_paired_token_index] = donated_paired_token
    lp_tokens_out: uint256 = self.pool.calc_token_amount(amounts, True)

    accounting_baseline: uint256 = lp_value_before + donated_value
    lp_value_after: uint256 = self._lp_value_at(lp_before + lp_tokens_out, virtual_price)
    if lp_value_after < accounting_baseline + crv_usd_deployed:
        return False
    gross_profit: uint256 = lp_value_after - accounting_baseline - crv_usd_deployed
    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward: uint256 = keeper_reward_value * PRECISION / virtual_price
    if keeper_reward > lp_tokens_out:
        return False

    retained_value: uint256 = self._lp_value_at(
        lp_before + lp_tokens_out - keeper_reward,
        virtual_price,
    )
    if retained_value < accounting_baseline:
        return False
    if not self._meets_entry_floor(retained_value - accounting_baseline, crv_usd_deployed):
        return False
    return retained_value >= deployed_after


@internal
@view
def _preview_expansion(_crv_usd_amount: uint256) -> (uint256, uint256, uint256, uint256):
    assert _crv_usd_amount >= self.min_expansion_amount
    self._backing_price()

    lp_before: uint256 = self._lp_inventory()
    virtual_price: uint256 = self.pool.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price)
    donated_paired_token: uint256 = self._paired_token_inventory()
    donated_value: uint256 = self._trusted_paired_token_value(donated_paired_token)
    crv_usd_deployed: uint256 = _crv_usd_amount + donated_value
    accounting_baseline: uint256 = lp_value_before + donated_value

    amounts: DynArray[uint256, 2] = [0, 0]
    amounts[self.pool_crvusd_index] = crv_usd_deployed
    amounts[self.pool_paired_token_index] = donated_paired_token

    assert crv_usd_deployed <= self._crv_usd.balanceOf(self)
    assert crv_usd_deployed <= self._available_velocity()
    deployed_after: uint256 = self.deployed_crvusd + crv_usd_deployed
    assert deployed_after <= self.max_deployed_crvusd
    assert deployed_after <= self._controller_factory.debt_ceiling(self)

    lp_tokens_out: uint256 = self.pool.calc_token_amount(amounts, True)
    lp_value_after: uint256 = self._lp_value_at(lp_before + lp_tokens_out, virtual_price)
    assert lp_value_after >= accounting_baseline + crv_usd_deployed
    gross_profit: uint256 = lp_value_after - accounting_baseline - crv_usd_deployed
    reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward: uint256 = reward_value * PRECISION / virtual_price
    assert keeper_reward <= lp_tokens_out

    retained_lp: uint256 = lp_before + lp_tokens_out - keeper_reward
    retained_value: uint256 = self._lp_value_at(retained_lp, virtual_price)
    assert retained_value >= accounting_baseline
    assert self._meets_entry_floor(
        retained_value - accounting_baseline,
        crv_usd_deployed,
    )
    assert retained_value >= deployed_after
    return crv_usd_deployed, gross_profit, keeper_reward, lp_tokens_out


@internal
def _deposit_to_pool(
    _crv_usd_amount: uint256,
    _paired_token_amount: uint256,
) -> uint256:
    amounts: DynArray[uint256, 2] = [0, 0]
    amounts[self.pool_crvusd_index] = _crv_usd_amount
    amounts[self.pool_paired_token_index] = _paired_token_amount
    quoted_lp: uint256 = self.pool.calc_token_amount(amounts, True)
    min_lp: uint256 = quoted_lp * (BPS - self.amm_execution_buffer_bps) / BPS

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    paired_token_before: uint256 = self._paired_token.balanceOf(self)
    lp_before: uint256 = self._lp_inventory()

    self._crv_usd.approve(self.pool.address, 0)
    self._crv_usd.approve(self.pool.address, _crv_usd_amount)
    ERC20(self._paired_token.address).approve(self.pool.address, 0)
    ERC20(self._paired_token.address).approve(self.pool.address, _paired_token_amount)
    self.pool.add_liquidity(amounts, min_lp)
    self._crv_usd.approve(self.pool.address, 0)
    ERC20(self._paired_token.address).approve(self.pool.address, 0)

    assert crv_usd_before - self._crv_usd.balanceOf(self) == _crv_usd_amount
    assert paired_token_before - self._paired_token.balanceOf(self) == _paired_token_amount
    lp_received: uint256 = self._lp_inventory() - lp_before
    assert lp_received >= min_lp
    return lp_received


@internal
def _settle_lp_expansion(
    _lp_before: uint256,
    _lp_value_before: uint256,
    _donated_paired_token_value: uint256,
    _entry_donation_value: uint256,
    _principal: uint256,
    _lp_received: uint256,
) -> (uint256, uint256):
    lp_after_deposit: uint256 = self._lp_inventory()
    assert lp_after_deposit - _lp_before == _lp_received
    virtual_price_after: uint256 = self.pool.get_virtual_price()
    lp_value_after: uint256 = self._lp_value_at(lp_after_deposit, virtual_price_after)
    accounting_baseline: uint256 = _lp_value_before + _donated_paired_token_value
    gross_profit: uint256 = 0
    if lp_value_after > accounting_baseline + _principal:
        gross_profit = lp_value_after - accounting_baseline - _principal

    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    keeper_reward: uint256 = keeper_reward_value * PRECISION / virtual_price_after
    assert keeper_reward <= _lp_received
    self._transfer_exact_to(ERC20(self.pool.address), msg.sender, keeper_reward)

    retained_value: uint256 = self._lp_value(self._lp_inventory())
    entry_baseline: uint256 = _lp_value_before + _entry_donation_value
    assert retained_value >= entry_baseline
    assert self._meets_entry_floor(retained_value - entry_baseline, _principal)
    return gross_profit, keeper_reward


@external
@nonreentrant("lock")
def expand_supply(_crv_usd_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Deposits crvUSD and any donated paired token directly into the keeper's AMM.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _crv_usd_amount >= self.min_expansion_amount
    self._require_expansion_policy()
    assert self._intervention_delay_elapsed()
    assert _crv_usd_amount <= self._local_expansion_limit()
    self._backing_price()

    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)
    paired_token_before: uint256 = self._paired_token_inventory()
    lp_before: uint256 = self._lp_inventory()
    virtual_price_before: uint256 = self.pool.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(paired_token_before)

    crv_usd_deployed: uint256 = _crv_usd_amount + donated_paired_token_value
    assert crv_usd_deployed <= crv_usd_before
    assert crv_usd_deployed <= self._remaining_exposure_capacity()
    self._consume_velocity(crv_usd_deployed)

    lp_received: uint256 = self._deposit_to_pool(
        crv_usd_deployed,
        paired_token_before,
    )
    assert crv_usd_before - self._crv_usd.balanceOf(self) == crv_usd_deployed

    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_paired_token_value,
        donated_paired_token_value,
        crv_usd_deployed,
        lp_received,
    )
    self.deployed_crvusd += crv_usd_deployed
    assert self._trusted_backing_value() >= self.deployed_crvusd
    self.last_intervention_at = block.timestamp

    log Expanded(
        msg.sender,
        crv_usd_deployed,
        lp_received,
        gross_profit,
        keeper_reward,
    )
    return crv_usd_deployed, lp_received, keeper_reward


@internal
@view
def _donation_match_amount(_donated_paired_token_value: uint256) -> uint256:
    if not self._allocation_allowed():
        return 0
    if PegKeeperPolicy(self._policy_address()).expansion_regime():
        return _donated_paired_token_value

    pool_crv_usd: uint256 = self.pool.balances(self.pool_crvusd_index)
    pool_paired_token_value: uint256 = self._trusted_paired_token_value(
        self.pool.balances(self.pool_paired_token_index)
    )
    paired_token_value_after: uint256 = pool_paired_token_value + _donated_paired_token_value
    if paired_token_value_after <= pool_crv_usd:
        return 0
    return min(_donated_paired_token_value, paired_token_value_after - pool_crv_usd)


@internal
def _settle_donated_paired_token(
    _max_paired_token_amount: uint256,
    _matching_budget: uint256,
    _require_minimum: bool,
) -> (uint256, uint256, uint256, uint256):
    paired_token_swept: uint256 = min(_max_paired_token_amount, self._paired_token_inventory())
    if paired_token_swept == 0:
        return 0, 0, 0, 0

    self._backing_price()
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(paired_token_swept)
    if _require_minimum:
        assert donated_paired_token_value >= self.min_expansion_amount

    crv_usd_matched: uint256 = min(
        self._donation_match_amount(donated_paired_token_value),
        _matching_budget,
    )
    if crv_usd_matched > 0:
        assert crv_usd_matched <= self._crv_usd.balanceOf(self)
        assert crv_usd_matched <= self._remaining_exposure_capacity()
        self._consume_velocity(crv_usd_matched)

    lp_before: uint256 = self._lp_inventory()
    virtual_price_before: uint256 = self.pool.get_virtual_price()
    lp_value_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    lp_received: uint256 = self._deposit_to_pool(
        crv_usd_matched,
        paired_token_swept,
    )
    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_lp_expansion(
        lp_before,
        lp_value_before,
        donated_paired_token_value,
        0,
        crv_usd_matched,
        lp_received,
    )

    self.deployed_crvusd += crv_usd_matched
    assert self._trusted_backing_value() >= self.deployed_crvusd

    log DonatedPairedTokenSwept(
        msg.sender,
        paired_token_swept,
        crv_usd_matched,
        lp_received,
        gross_profit,
        keeper_reward,
    )
    return paired_token_swept, crv_usd_matched, lp_received, keeper_reward


@external
@nonreentrant("lock")
def sweep_donated_paired_token(_max_paired_token_amount: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Deposits donated paired tokens and matches only the crvUSD appropriate for the current regime.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _max_paired_token_amount > 0

    matching_budget: uint256 = min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )
    return self._settle_donated_paired_token(
        _max_paired_token_amount,
        matching_budget,
        True,
    )


@external
@nonreentrant("lock")
def withdraw_profit(_max_crv_usd_amount: uint256 = max_value(uint256)) -> uint256:
    """
    @notice Withdraws eligible protocol profit in crvUSD; the no-argument overload uses the maximum limit.
    """
    assert not self.all_execution_paused
    assert not self.expansion_paused

    backing_price: uint256 = self._backing_price()
    backing_before_sweep: uint256 = self._oracle_value(
        self._trusted_backing_value(),
        backing_price,
    )
    potential_surplus: uint256 = 0
    if backing_before_sweep > self.deployed_crvusd:
        potential_surplus = backing_before_sweep - self.deployed_crvusd
    donated_paired_token_value: uint256 = self._trusted_paired_token_value(self._paired_token_inventory())
    potential_surplus += self._oracle_value(donated_paired_token_value, backing_price)

    available_budget: uint256 = min(
        self._crv_usd.balanceOf(self),
        min(self._available_velocity(), self._remaining_exposure_capacity()),
    )
    withdrawal_reserve: uint256 = min(
        _max_crv_usd_amount,
        min(potential_surplus, available_budget),
    )
    self._settle_donated_paired_token(
        self._paired_token_inventory(),
        available_budget - withdrawal_reserve,
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

    log ProfitWithdrawn(
        msg.sender,
        fee_receiver,
        crv_usd_transferred,
        deployed_crv_usd_after,
    )
    return crv_usd_transferred


@external
@nonreentrant("lock")
def contract_supply(_lp_token_amount: uint256) -> (uint256, uint256, uint256):
    """
    @notice Burns held pool LP tokens and withdraws only crvUSD.
    """
    assert not self.all_execution_paused
    assert not self.contraction_paused
    self._require_contraction_policy()
    assert self._intervention_delay_elapsed()
    lp_before: uint256 = self._lp_inventory()
    assert _lp_token_amount > 0 and _lp_token_amount <= lp_before

    virtual_price_before: uint256 = self.pool.get_virtual_price()
    trusted_backing_before: uint256 = self._lp_value_at(lp_before, virtual_price_before)
    local_contraction_limit: uint256 = self._local_contraction_limit()
    quoted_crv_usd: uint256 = self.pool.calc_withdraw_one_coin(
        _lp_token_amount,
        convert(self.pool_crvusd_index, int128),
    )
    assert quoted_crv_usd <= local_contraction_limit
    min_crv_usd: uint256 = quoted_crv_usd * (
        BPS - self.amm_execution_buffer_bps
    ) / BPS
    crv_usd_before: uint256 = self._crv_usd.balanceOf(self)

    self.pool.remove_liquidity_one_coin(
        _lp_token_amount,
        convert(self.pool_crvusd_index, int128),
        min_crv_usd,
    )

    lp_after: uint256 = self._lp_inventory()
    assert lp_before - lp_after == _lp_token_amount
    crv_usd_after_withdrawal: uint256 = self._crv_usd.balanceOf(self)
    crv_usd_received: uint256 = crv_usd_after_withdrawal - crv_usd_before
    assert crv_usd_received >= min_crv_usd
    assert crv_usd_received <= local_contraction_limit

    virtual_price_after: uint256 = self.pool.get_virtual_price()
    trusted_backing_after: uint256 = self._lp_value_at(lp_after, virtual_price_after)
    assert trusted_backing_before >= trusted_backing_after
    trusted_value_removed: uint256 = trusted_backing_before - trusted_backing_after
    assert trusted_value_removed > 0

    gross_profit: uint256 = 0
    keeper_reward: uint256 = 0
    gross_profit, keeper_reward = self._settle_keeper_contraction_and_reduce_exposure(
        crv_usd_before,
        crv_usd_after_withdrawal,
        crv_usd_received,
        trusted_value_removed,
        trusted_backing_after,
    )
    assert self._trusted_backing_value() >= self.deployed_crvusd
    self.last_intervention_at = block.timestamp

    log Contracted(
        msg.sender,
        _lp_token_amount,
        crv_usd_received,
        gross_profit,
        keeper_reward,
    )
    return _lp_token_amount, crv_usd_received, keeper_reward


@external
@nonreentrant("lock")
def borrow_crvusd(_amount: uint256, _receiver: address):
    """
    @notice Gives a Factory-admin-selected receiver policy-approved crvUSD and records it as debt.
    """
    assert self._is_admin(msg.sender)
    assert not self.all_execution_paused
    assert not self.expansion_paused
    assert _receiver != empty(address)
    assert _amount >= self.min_expansion_amount
    self._require_expansion_policy()
    assert self._intervention_delay_elapsed()
    assert _amount <= self._local_expansion_limit()
    self._backing_price()

    deployed_after: uint256 = self.deployed_crvusd + _amount
    assert deployed_after <= self.max_deployed_crvusd
    assert deployed_after <= self._controller_factory.debt_ceiling(self)
    assert _amount <= self._crv_usd.balanceOf(self)

    self._consume_velocity(_amount)
    self.deployed_crvusd = deployed_after
    self.last_intervention_at = block.timestamp
    self._transfer_exact_to(self._crv_usd, _receiver, _amount)
    log CrvUsdBorrowed(msg.sender, _receiver, _amount, deployed_after)


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
def set_intervention_policy(
    _max_intervention_share_bps: uint256,
    _min_intervention_delay: uint256,
):
    """
    @notice Changes the local-imbalance share and minimum time between interventions.
    """
    assert self._is_admin(msg.sender)
    assert _max_intervention_share_bps > 0
    assert _max_intervention_share_bps <= BPS

    self.max_intervention_share_bps = _max_intervention_share_bps
    self.min_intervention_delay = _min_intervention_delay
    log InterventionPolicyUpdated(
        _max_intervention_share_bps,
        _min_intervention_delay,
    )


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
    elif _direction == DIRECTION_CONTRACTION:
        self.contraction_paused = _paused
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
