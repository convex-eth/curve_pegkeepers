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

interface YieldToken:
    def asset() -> address: view
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def convertToAssets(_yield_token_amount: uint256) -> uint256: view
    def convertToShares(_assets: uint256) -> uint256: view


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

event FeeReceiverUpdated:
    old_receiver: indexed(address)
    new_receiver: indexed(address)

event PolicyUpdated:
    entry_min_profit_ppm: uint256
    normal_exit_min_profit_ppm: uint256
    early_exit_min_profit_ppm: uint256
    keeper_profit_share_bps: uint256
    max_keeper_reward: uint256
    min_deployment_time: uint256
    min_expansion_amount: uint256
    max_deployed_crvusd: uint256

event RolesUpdated:
    old_admin: indexed(address)
    new_admin: indexed(address)
    new_emergency_admin: indexed(address)

event PathsUpdated:
    expansion_path_hash: indexed(bytes32)
    contraction_path_hash: indexed(bytes32)
    expansion_max_route_loss_bps: uint256

event UndeployedBackingDeployed:
    caller: indexed(address)
    target_spent: uint256
    yield_token_received: uint256
    trusted_value_received: uint256
    conversion_cost: uint256


version: public(constant(String[8])) = "3.0.0"

BPS: constant(uint256) = 10_000
PPM: constant(uint256) = 1_000_000
MAX_ROUTE_STEPS: public(constant(uint256)) = 16
STEP_CURVE_SWAP: constant(uint256) = 0
STEP_DAI_USDS_CONVERTER: constant(uint256) = 1
STEP_ERC4626_DEPOSIT: constant(uint256) = 2
STEP_ERC4626_REDEEM: constant(uint256) = 3

DIRECTION_EXPANSION: constant(uint256) = 0
DIRECTION_BACKING_DEPLOYMENT: constant(uint256) = 1
DIRECTION_DIRECT_BUYBACK: constant(uint256) = 2
DIRECTION_UNDEPLOYED_CONTRACTION: constant(uint256) = 3
DIRECTION_YIELD_CONTRACTION: constant(uint256) = 4
DIRECTION_ALL: constant(uint256) = 5

FACTORY: immutable(ControllerFactory)
CRV_USD: immutable(ERC20)
target_amm: public(TwoCoinPool)
TARGET_ASSET: immutable(ERC20)
BACKING_ASSET: immutable(ERC20)
YIELD_TOKEN: immutable(YieldToken)
TARGET_MULTIPLIER: immutable(uint256)
BACKING_MULTIPLIER: immutable(uint256)

admin: public(address)
emergency_admin: public(address)
fee_receiver: public(address)

target_amm_crvusd_index: public(uint256)
target_amm_target_index: public(uint256)

entry_min_profit_ppm: public(uint256)
normal_exit_min_profit_ppm: public(uint256)
early_exit_min_profit_ppm: public(uint256)
keeper_profit_share_bps: public(uint256)
max_keeper_reward: public(uint256)
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

expansion_paused: public(bool)
backing_deployment_paused: public(bool)
direct_buyback_paused: public(bool)
undeployed_contraction_paused: public(bool)
yield_contraction_paused: public(bool)
all_execution_paused: public(bool)


@external
def __init__(
    _factory: ControllerFactory,
    _target_amm: TwoCoinPool,
    _target_asset: ERC20,
    _backing_asset: ERC20,
    _yield_token: YieldToken,
    _fee_receiver: address,
    _admin: address,
    _emergency_admin: address,
    _max_deployed_crvusd: uint256,
):
    assert _factory.address != empty(address), "factory=0"
    assert _target_amm.address != empty(address), "target amm=0"
    assert _target_asset.address != empty(address), "target asset=0"
    assert _backing_asset.address != empty(address), "backing asset=0"
    assert _yield_token.address != empty(address), "yield token=0"
    assert _fee_receiver != empty(address), "fee receiver=0"
    assert _admin != empty(address), "admin=0"
    assert _emergency_admin != empty(address), "emergency admin=0"
    assert _admin != _emergency_admin, "roles overlap"
    assert _max_deployed_crvusd > 0, "max deployed=0"

    crv_usd: address = _factory.stablecoin()
    assert crv_usd != empty(address), "crvUSD=0"
    assert crv_usd != _target_asset.address, "identical pair"
    assert _yield_token.asset() == _backing_asset.address, "yield asset mismatch"
    assert _yield_token.convertToAssets(0) == 0, "bad asset conversion"
    assert _yield_token.convertToShares(0) == 0, "bad share conversion"

    crv_decimals: uint256 = ERC20(crv_usd).decimals()
    target_decimals: uint256 = _target_asset.decimals()
    backing_decimals: uint256 = _backing_asset.decimals()
    assert crv_decimals == 18, "crvUSD decimals"
    assert target_decimals <= 18, "target decimals>18"
    assert backing_decimals <= 18, "backing decimals>18"

    coin_0: address = _target_amm.coins(0)
    coin_1: address = _target_amm.coins(1)
    if coin_0 == crv_usd and coin_1 == _target_asset.address:
        self.target_amm_crvusd_index = 0
        self.target_amm_target_index = 1
    elif coin_0 == _target_asset.address and coin_1 == crv_usd:
        self.target_amm_crvusd_index = 1
        self.target_amm_target_index = 0
    else:
        raise "bad target pair"

    FACTORY = _factory
    CRV_USD = ERC20(crv_usd)
    self.target_amm = _target_amm
    TARGET_ASSET = _target_asset
    BACKING_ASSET = _backing_asset
    YIELD_TOKEN = _yield_token
    TARGET_MULTIPLIER = 10 ** (18 - target_decimals)
    BACKING_MULTIPLIER = 10 ** (18 - backing_decimals)

    self.admin = _admin
    self.emergency_admin = _emergency_admin
    self.fee_receiver = _fee_receiver

    self.entry_min_profit_ppm = 50
    self.normal_exit_min_profit_ppm = 1_000
    self.early_exit_min_profit_ppm = 5_000
    self.keeper_profit_share_bps = 3_000
    self.max_keeper_reward = 20 * 10 ** 18
    self.min_deployment_time = 2 * 86400
    self.min_expansion_amount = 10_000 * 10 ** 18
    self.max_deployed_crvusd = _max_deployed_crvusd

    # A fresh deployment has no routes or benchmarked gas limits. It starts inert.
    self.expansion_paused = True
    self.backing_deployment_paused = True
    self.direct_buyback_paused = True
    self.undeployed_contraction_paused = True
    self.yield_contraction_paused = True
    self.all_execution_paused = True


@external
@pure
def factory() -> address:
    return FACTORY.address


@external
@pure
def crv_usd() -> address:
    return CRV_USD.address


@external
@pure
def target_asset() -> address:
    return TARGET_ASSET.address


@external
@pure
def backing_asset() -> address:
    return BACKING_ASSET.address


@external
@pure
def yield_token() -> address:
    return YIELD_TOKEN.address


@external
@pure
def coins(_index: uint256) -> address:
    if _index == 0:
        return CRV_USD.address
    assert _index == 1, "coin index"
    return YIELD_TOKEN.address


@internal
@pure
def _normalize_target(_amount: uint256) -> uint256:
    return _amount * TARGET_MULTIPLIER


@internal
@pure
def _normalize_backing(_amount: uint256) -> uint256:
    return _amount * BACKING_MULTIPLIER


@internal
@view
def _trusted_backing_value() -> uint256:
    target_value: uint256 = self._normalize_target(self.undeployed_backing)
    backing_amount: uint256 = YIELD_TOKEN.convertToAssets(self.accounted_yield_token_units)
    return target_value + self._normalize_backing(backing_amount)


@internal
@view
def _trusted_yield_value(_yield_token_units: uint256) -> uint256:
    return self._normalize_backing(YIELD_TOKEN.convertToAssets(_yield_token_units))


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
def available_expansion() -> uint256:
    available: uint256 = CRV_USD.balanceOf(self)

    if self.max_deployed_crvusd <= self.deployed_crvusd:
        return 0
    remaining_capacity: uint256 = self.max_deployed_crvusd - self.deployed_crvusd
    if remaining_capacity < available:
        available = remaining_capacity

    factory_allocation: uint256 = FACTORY.debt_ceiling(self)
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
def _preview_buyback(_crv_usd_amount: uint256) -> (uint256, uint256, bool):
    assert _crv_usd_amount > 0, "crvUSD amount=0"
    deployed_before: uint256 = self.deployed_crvusd
    assert _crv_usd_amount <= deployed_before, "exposure amount"

    accounted_before: uint256 = self.accounted_yield_token_units
    assert YIELD_TOKEN.balanceOf(self) >= accounted_before, "insufficient yield balance"

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm

    denominator: uint256 = PPM + exit_margin_ppm
    payout_budget: uint256 = (
        _crv_usd_amount / denominator * PPM
        + (_crv_usd_amount % denominator) * PPM / denominator
    )
    payout_assets: uint256 = payout_budget / BACKING_MULTIPLIER
    assert payout_assets > 1, "payout too small"

    yield_token_out: uint256 = YIELD_TOKEN.convertToShares(payout_assets - 1)
    assert yield_token_out > 0, "payout too small"
    assert yield_token_out <= accounted_before, "insufficient yield"

    trusted_before: uint256 = self._trusted_yield_value(accounted_before)
    trusted_after: uint256 = self._trusted_yield_value(accounted_before - yield_token_out)
    assert trusted_before >= trusted_after, "yield value increased"
    trusted_value_removed: uint256 = trusted_before - trusted_after
    required_exit_profit: uint256 = (
        trusted_value_removed / PPM * exit_margin_ppm
        + (trusted_value_removed % PPM) * exit_margin_ppm / PPM
    )
    assert _crv_usd_amount >= trusted_value_removed, "exit margin"
    assert _crv_usd_amount - trusted_value_removed >= required_exit_profit, "exit margin"

    trusted_total_before: uint256 = self._trusted_backing_value()
    assert trusted_total_before >= trusted_value_removed, "insufficient backing"
    assert (
        trusted_total_before - trusted_value_removed
        >= deployed_before - _crv_usd_amount
    ), "insufficient backing"

    return yield_token_out, required_exit_profit, early_exit


@external
@view
def previewBuyback(_crv_usd_amount: uint256) -> (uint256, uint256, bool):
    return self._preview_buyback(_crv_usd_amount)


@external
@nonreentrant("lock")
def buyback(_crv_usd_amount: uint256, _min_yield_token_out: uint256) -> uint256:
    assert not self.all_execution_paused, "all execution paused"
    assert not self.direct_buyback_paused, "direct buyback paused"

    expected_yield_token_out: uint256 = 0
    ignored_exit_profit: uint256 = 0
    early_exit: bool = False
    expected_yield_token_out, ignored_exit_profit, early_exit = self._preview_buyback(_crv_usd_amount)
    assert expected_yield_token_out >= _min_yield_token_out, "min yield out"

    accounted_before: uint256 = self.accounted_yield_token_units
    deployed_before: uint256 = self.deployed_crvusd
    trusted_yield_before: uint256 = self._trusted_yield_value(accounted_before)
    crv_usd_before: uint256 = CRV_USD.balanceOf(self)
    caller_crv_usd_before: uint256 = CRV_USD.balanceOf(msg.sender)
    yield_token_before: uint256 = YIELD_TOKEN.balanceOf(self)
    caller_yield_before: uint256 = YIELD_TOKEN.balanceOf(msg.sender)

    CRV_USD.transferFrom(msg.sender, self, _crv_usd_amount)
    crv_usd_after: uint256 = CRV_USD.balanceOf(self)
    caller_crv_usd_after: uint256 = CRV_USD.balanceOf(msg.sender)
    assert crv_usd_after >= crv_usd_before, "bad crvUSD receipt"
    crv_usd_received: uint256 = crv_usd_after - crv_usd_before
    assert crv_usd_received == _crv_usd_amount, "bad crvUSD receipt"
    assert caller_crv_usd_before >= caller_crv_usd_after, "bad crvUSD spend"
    assert caller_crv_usd_before - caller_crv_usd_after == _crv_usd_amount, "bad crvUSD spend"

    ERC20(YIELD_TOKEN.address).transfer(msg.sender, expected_yield_token_out)
    yield_token_after: uint256 = YIELD_TOKEN.balanceOf(self)
    caller_yield_after: uint256 = YIELD_TOKEN.balanceOf(msg.sender)
    assert yield_token_before >= yield_token_after, "bad yield spend"
    yield_token_spent: uint256 = yield_token_before - yield_token_after
    assert yield_token_spent == expected_yield_token_out, "bad yield spend"
    assert caller_yield_after >= caller_yield_before, "bad yield receipt"
    yield_token_received: uint256 = caller_yield_after - caller_yield_before
    assert yield_token_received == expected_yield_token_out, "bad yield receipt"
    assert yield_token_received >= _min_yield_token_out, "min yield out"

    accounted_after: uint256 = accounted_before - yield_token_spent
    trusted_yield_after: uint256 = self._trusted_yield_value(accounted_after)
    assert trusted_yield_before >= trusted_yield_after, "yield value increased"
    trusted_value_removed: uint256 = trusted_yield_before - trusted_yield_after

    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    required_exit_profit: uint256 = (
        trusted_value_removed / PPM * exit_margin_ppm
        + (trusted_value_removed % PPM) * exit_margin_ppm / PPM
    )
    assert crv_usd_received >= trusted_value_removed, "exit margin"
    assert crv_usd_received - trusted_value_removed >= required_exit_profit, "exit margin"

    deployed_after: uint256 = deployed_before - crv_usd_received
    self.accounted_yield_token_units = accounted_after
    self.deployed_crvusd = deployed_after
    assert self._trusted_backing_value() >= deployed_after, "insufficient backing"

    log DirectBuyback(msg.sender, crv_usd_received, yield_token_received, early_exit)
    return yield_token_received


@external
@view
def previewUndeployedContraction(_target_amount: uint256) -> (uint256, uint256, uint256, bool):
    assert _target_amount > 0, "target amount=0"
    assert _target_amount <= self.undeployed_backing, "insufficient backing"

    target_index: int128 = convert(self.target_amm_target_index, int128)
    crv_usd_index: int128 = convert(self.target_amm_crvusd_index, int128)
    expected_crv_usd: uint256 = self.target_amm.get_dy(
        target_index,
        crv_usd_index,
        _target_amount,
    )
    target_value: uint256 = self._normalize_target(_target_amount)
    gross_profit: uint256 = 0
    if expected_crv_usd > target_value:
        gross_profit = expected_crv_usd - target_value

    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    if keeper_reward > self.max_keeper_reward:
        keeper_reward = self.max_keeper_reward

    return expected_crv_usd, gross_profit, keeper_reward, self._is_early_exit()


@internal
@view
def _preview_contraction_path(_yield_token_amount: uint256) -> uint256:
    amount_out: uint256 = _yield_token_amount
    for i in range(MAX_ROUTE_STEPS):
        if i >= len(self.contraction_path):
            break
        step: RouteStep = self.contraction_path[i]
        if step.kind == STEP_CURVE_SWAP:
            amount_out = CurveRoutePool(step.venue).get_dy(
                step.pool_index_in,
                step.pool_index_out,
                amount_out,
            )
        elif step.kind == STEP_DAI_USDS_CONVERTER:
            pass
        elif step.kind == STEP_ERC4626_DEPOSIT:
            amount_out = ERC4626Route(step.venue).previewDeposit(amount_out)
        else:
            amount_out = ERC4626Route(step.venue).previewRedeem(amount_out)
    return amount_out


@external
@view
def previewKeeperBuyback(_yield_token_amount: uint256) -> (uint256, uint256, uint256, bool):
    assert _yield_token_amount > 0, "yield amount=0"
    assert _yield_token_amount <= self.accounted_yield_token_units, "insufficient yield"
    assert len(self.contraction_path) > 0, "empty contraction path"

    trusted_value_before: uint256 = self._trusted_yield_value(
        self.accounted_yield_token_units
    )
    trusted_value_after: uint256 = self._trusted_yield_value(
        self.accounted_yield_token_units - _yield_token_amount
    )
    trusted_value_removed: uint256 = trusted_value_before - trusted_value_after
    assert trusted_value_removed <= self.deployed_crvusd, "exposure amount"

    expected_crv_usd: uint256 = self._preview_contraction_path(_yield_token_amount)
    gross_profit: uint256 = 0
    if expected_crv_usd > trusted_value_removed:
        gross_profit = expected_crv_usd - trusted_value_removed
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    if keeper_reward > self.max_keeper_reward:
        keeper_reward = self.max_keeper_reward
    return expected_crv_usd, gross_profit, keeper_reward, self._is_early_exit()


@external
def set_target_amm(_new_target_amm: TwoCoinPool, _execution_buffer_bps: uint256):
    assert msg.sender == self.admin, "not admin"
    assert _new_target_amm.address != empty(address), "target amm=0"
    assert _execution_buffer_bps <= BPS, "buffer too high"

    coin_0: address = _new_target_amm.coins(0)
    coin_1: address = _new_target_amm.coins(1)
    crv_usd_index: uint256 = 0
    target_index: uint256 = 0
    if coin_0 == CRV_USD.address and coin_1 == TARGET_ASSET.address:
        crv_usd_index = 0
        target_index = 1
    elif coin_0 == TARGET_ASSET.address and coin_1 == CRV_USD.address:
        crv_usd_index = 1
        target_index = 0
    else:
        raise "bad target pair"

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
def set_expansion_config(
    _target_amm_execution_buffer_bps: uint256,
    _min_downstream_attempt_gas: uint256,
    _fallback_settlement_gas_reserve: uint256,
):
    assert msg.sender == self.admin, "not admin"
    assert _target_amm_execution_buffer_bps <= BPS, "buffer too high"
    assert _fallback_settlement_gas_reserve > 0, "gas reserve"
    assert _min_downstream_attempt_gas > _fallback_settlement_gas_reserve, "gas reserve"

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
    assert not self.all_execution_paused, "all execution paused"
    assert not self.expansion_paused, "expansion paused"
    assert _crv_usd_amount >= self.min_expansion_amount, "expansion too small"

    crv_usd_before: uint256 = CRV_USD.balanceOf(self)
    assert _crv_usd_amount <= crv_usd_before, "insufficient idle"

    deployed_after: uint256 = self.deployed_crvusd + _crv_usd_amount
    assert deployed_after <= self.max_deployed_crvusd, "max deployed"
    assert deployed_after <= FACTORY.debt_ceiling(self), "factory allocation"

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

    target_before: uint256 = TARGET_ASSET.balanceOf(self)
    CRV_USD.approve(self.target_amm.address, _crv_usd_amount)
    self.target_amm.exchange(
        crv_usd_index,
        target_index,
        _crv_usd_amount,
        target_minimum,
    )
    CRV_USD.approve(self.target_amm.address, 0)

    crv_usd_after: uint256 = CRV_USD.balanceOf(self)
    assert crv_usd_before >= crv_usd_after, "bad crvUSD delta"
    crv_usd_sold: uint256 = crv_usd_before - crv_usd_after
    assert crv_usd_sold == _crv_usd_amount, "bad crvUSD spend"

    target_after_swap: uint256 = TARGET_ASSET.balanceOf(self)
    assert target_after_swap >= target_before, "bad target delta"
    target_received: uint256 = target_after_swap - target_before
    assert target_received >= target_minimum, "target minimum"

    downstream_succeeded: bool = False
    downstream_response: Bytes[128] = empty(Bytes[128])
    yield_balance_before_attempt: uint256 = YIELD_TOKEN.balanceOf(self)
    if len(self.expansion_path) > 0:
        available_attempt_gas: uint256 = msg.gas
        assert available_attempt_gas >= self.min_downstream_attempt_gas, "downstream gas"
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

        target_after_attempt: uint256 = TARGET_ASSET.balanceOf(self)
        assert target_after_swap >= target_after_attempt, "bad target spend"
        assert target_after_swap - target_after_attempt == target_received, "bad target spend"
        assert target_after_attempt == target_before, "bad retained target"
        yield_balance_after: uint256 = YIELD_TOKEN.balanceOf(self)
        assert yield_balance_after >= yield_balance_before_attempt, "bad yield output"
        assert yield_token_received > 0, "yield output=0"
        assert yield_balance_after - yield_balance_before_attempt == yield_token_received, "bad yield output"

        self.accounted_yield_token_units += yield_token_received
        self.deployed_crvusd = deployed_after
        self.last_expansion_at = block.timestamp
        assert YIELD_TOKEN.balanceOf(self) >= self.accounted_yield_token_units, "yield accounting"
        assert self._trusted_backing_value() >= self.deployed_crvusd, "insufficient backing"

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

    target_value: uint256 = self._normalize_target(target_received)
    gross_profit: uint256 = 0
    if target_value > crv_usd_sold:
        gross_profit = target_value - crv_usd_sold

    keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    if keeper_reward_value > self.max_keeper_reward:
        keeper_reward_value = self.max_keeper_reward
    keeper_reward: uint256 = keeper_reward_value / TARGET_MULTIPLIER

    if keeper_reward > 0:
        keeper_balance_before: uint256 = TARGET_ASSET.balanceOf(msg.sender)
        TARGET_ASSET.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = TARGET_ASSET.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before, "bad reward delta"
        assert keeper_balance_after - keeper_balance_before == keeper_reward, "bad reward receipt"

    target_after_reward: uint256 = TARGET_ASSET.balanceOf(self)
    assert target_after_swap >= target_after_reward, "bad reward spend"
    assert target_after_swap - target_after_reward == keeper_reward, "bad reward spend"
    assert target_after_reward >= target_before, "bad retained delta"
    target_retained: uint256 = target_after_reward - target_before

    entry_margin: uint256 = crv_usd_sold * self.entry_min_profit_ppm / PPM
    assert self._normalize_target(target_retained) >= crv_usd_sold + entry_margin, "entry margin"

    self.undeployed_backing += target_retained
    self.deployed_crvusd = deployed_after
    self.last_expansion_at = block.timestamp

    assert TARGET_ASSET.balanceOf(self) >= self.undeployed_backing, "target accounting"
    assert self._trusted_backing_value() >= self.deployed_crvusd, "insufficient backing"

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
    assert not self.all_execution_paused, "all execution paused"
    assert not self.undeployed_contraction_paused, "contraction paused"
    assert _target_amount > 0, "target amount=0"
    assert _target_amount <= self.undeployed_backing, "insufficient backing"

    target_before: uint256 = TARGET_ASSET.balanceOf(self)
    assert target_before >= self.undeployed_backing, "target accounting"

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

    crv_usd_before: uint256 = CRV_USD.balanceOf(self)
    TARGET_ASSET.approve(self.target_amm.address, _target_amount)
    self.target_amm.exchange(
        target_index,
        crv_usd_index,
        _target_amount,
        crv_usd_minimum,
    )
    TARGET_ASSET.approve(self.target_amm.address, 0)

    target_after: uint256 = TARGET_ASSET.balanceOf(self)
    assert target_before >= target_after, "bad target spend"
    target_spent: uint256 = target_before - target_after
    assert target_spent == _target_amount, "bad target spend"

    crv_usd_after_swap: uint256 = CRV_USD.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_before, "bad crvUSD delta"
    crv_usd_received: uint256 = crv_usd_after_swap - crv_usd_before
    assert crv_usd_received >= crv_usd_minimum, "crvUSD minimum"

    target_value: uint256 = self._normalize_target(target_spent)
    gross_profit: uint256 = 0
    if crv_usd_received > target_value:
        gross_profit = crv_usd_received - target_value

    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    if keeper_reward > self.max_keeper_reward:
        keeper_reward = self.max_keeper_reward

    if keeper_reward > 0:
        keeper_balance_before: uint256 = CRV_USD.balanceOf(msg.sender)
        CRV_USD.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = CRV_USD.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before, "bad reward delta"
        assert keeper_balance_after - keeper_balance_before == keeper_reward, "bad reward receipt"

    crv_usd_after_reward: uint256 = CRV_USD.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_after_reward, "bad reward spend"
    assert crv_usd_after_swap - crv_usd_after_reward == keeper_reward, "bad reward spend"
    assert crv_usd_after_reward >= crv_usd_before, "bad retained crvUSD"
    net_crv_usd: uint256 = crv_usd_after_reward - crv_usd_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    exit_margin: uint256 = target_value * exit_margin_ppm / PPM
    assert net_crv_usd >= target_value + exit_margin, "exit margin"

    self.undeployed_backing -= target_spent
    exposure_reduction: uint256 = net_crv_usd
    if exposure_reduction > self.deployed_crvusd:
        exposure_reduction = self.deployed_crvusd
    self.deployed_crvusd -= exposure_reduction

    assert TARGET_ASSET.balanceOf(self) >= self.undeployed_backing, "target accounting"
    assert self._trusted_backing_value() >= self.deployed_crvusd, "insufficient backing"

    log KeeperBuyback(
        msg.sender,
        TARGET_ASSET.address,
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
    assert not self.all_execution_paused, "all execution paused"
    assert not self.expansion_paused, "expansion paused"

    trusted_backing: uint256 = self._trusted_backing_value()
    surplus: uint256 = 0
    if trusted_backing > self.deployed_crvusd:
        surplus = trusted_backing - self.deployed_crvusd

    crv_usd_balance_before: uint256 = CRV_USD.balanceOf(self)
    allocation: uint256 = FACTORY.debt_ceiling(self)
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
    assert crv_usd_transferred > 0, "no surplus claim"

    deployed_crv_usd_after: uint256 = self.deployed_crvusd + crv_usd_transferred
    self.deployed_crvusd = deployed_crv_usd_after

    receiver_balance_before: uint256 = CRV_USD.balanceOf(self.fee_receiver)
    CRV_USD.transfer(self.fee_receiver, crv_usd_transferred)
    crv_usd_balance_after: uint256 = CRV_USD.balanceOf(self)
    receiver_balance_after: uint256 = CRV_USD.balanceOf(self.fee_receiver)
    assert crv_usd_balance_before >= crv_usd_balance_after, "bad fee spend"
    assert crv_usd_balance_before - crv_usd_balance_after == crv_usd_transferred, "bad fee spend"
    assert receiver_balance_after >= receiver_balance_before, "bad fee receipt"
    assert receiver_balance_after - receiver_balance_before == crv_usd_transferred, "bad fee receipt"

    assert deployed_crv_usd_after <= allocation, "factory allocation"
    assert deployed_crv_usd_after <= self.max_deployed_crvusd, "max deployed"
    assert self._trusted_backing_value() >= deployed_crv_usd_after, "insufficient backing"

    log SurplusClaimed(
        msg.sender,
        self.fee_receiver,
        crv_usd_transferred,
        deployed_crv_usd_after,
    )
    return crv_usd_transferred


@internal
@view
def _validate_route_step(_step: RouteStep):
    assert _step.venue != empty(address), "route venue=0"
    assert _step.token_in != empty(address), "route tokenIn=0"
    assert _step.token_out != empty(address), "route tokenOut=0"
    assert _step.execution_buffer_bps <= BPS, "step buffer too high"

    if _step.kind == STEP_CURVE_SWAP:
        assert _step.pool_index_in >= 0 and _step.pool_index_out >= 0, "curve index"
        assert _step.pool_index_in != _step.pool_index_out, "curve index"
        assert CurveRoutePool(_step.venue).coins(
            convert(_step.pool_index_in, uint256)
        ) == _step.token_in, "curve tokenIn"
        assert CurveRoutePool(_step.venue).coins(
            convert(_step.pool_index_out, uint256)
        ) == _step.token_out, "curve tokenOut"
    elif _step.kind == STEP_DAI_USDS_CONVERTER:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0, "converter index"
        assert _step.execution_buffer_bps == 0, "converter buffer"
        dai: address = DaiUsds(_step.venue).dai()
        usds: address = DaiUsds(_step.venue).usds()
        valid_direction: bool = (
            _step.token_in == dai and _step.token_out == usds
        ) or (
            _step.token_in == usds and _step.token_out == dai
        )
        assert valid_direction, "converter pair"
    elif _step.kind == STEP_ERC4626_DEPOSIT:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0, "vault index"
        assert _step.venue == _step.token_out, "vault tokenOut"
        assert YieldToken(_step.venue).asset() == _step.token_in, "vault asset"
    elif _step.kind == STEP_ERC4626_REDEEM:
        assert _step.pool_index_in == 0 and _step.pool_index_out == 0, "vault index"
        assert _step.venue == _step.token_in, "vault tokenIn"
        assert YieldToken(_step.venue).asset() == _step.token_out, "vault asset"
    else:
        raise "unknown step"


@internal
@view
def _validate_route_continuity(_steps: DynArray[RouteStep, 16]):
    for i in range(MAX_ROUTE_STEPS):
        if i >= len(_steps):
            break
        if i > 0:
            assert _steps[i - 1].token_out == _steps[i].token_in, "path discontinuity"
        self._validate_route_step(_steps[i])


@external
def setPaths(
    _expansion_steps: DynArray[RouteStep, 16],
    _expansion_max_route_loss_bps: uint256,
    _contraction_steps: DynArray[RouteStep, 16],
):
    assert msg.sender == self.admin, "not admin"
    assert len(_expansion_steps) > 0, "empty expansion path"
    assert len(_contraction_steps) > 0, "empty contraction path"
    assert _expansion_max_route_loss_bps <= BPS, "route loss too high"

    assert _expansion_steps[0].token_in == TARGET_ASSET.address, "expansion start"
    expansion_last: RouteStep = _expansion_steps[len(_expansion_steps) - 1]
    assert expansion_last.token_out == YIELD_TOKEN.address, "expansion end"
    assert expansion_last.token_in == BACKING_ASSET.address, "terminal backing"

    assert _contraction_steps[0].token_in == YIELD_TOKEN.address, "contraction start"
    assert _contraction_steps[0].token_out == BACKING_ASSET.address, "initial backing"
    contraction_last: RouteStep = _contraction_steps[len(_contraction_steps) - 1]
    assert contraction_last.token_out == CRV_USD.address, "contraction end"

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
    assert _index < len(self.expansion_path), "path index"
    return self.expansion_path[_index]


@external
@view
def contraction_path_step(_index: uint256) -> RouteStep:
    assert _index < len(self.contraction_path), "path index"
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
    else:
        quoted_output = ERC4626Route(_step.venue).previewRedeem(_amount_in)
        minimum_output = quoted_output * (BPS - _step.execution_buffer_bps) / BPS
        ERC4626Route(_step.venue).redeem(_amount_in, self, self)

    token_in.approve(_step.venue, 0)
    input_balance_after: uint256 = token_in.balanceOf(self)
    output_balance_after: uint256 = token_out.balanceOf(self)
    assert input_balance_before >= input_balance_after, "bad step spend"
    assert input_balance_before - input_balance_after == _amount_in, "bad step spend"
    assert output_balance_after >= output_balance_before, "bad step output"
    amount_out: uint256 = output_balance_after - output_balance_before
    if _step.kind == STEP_DAI_USDS_CONVERTER:
        assert amount_out == minimum_output, "converter output"
    else:
        assert amount_out >= minimum_output, "step output"
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
    assert msg.sender == self, "not self"
    assert len(self.expansion_path) > 0, "empty expansion path"

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
            backing_value: uint256 = backing_asset_received * BACKING_MULTIPLIER
            if backing_value > _crv_usd_sold:
                gross_profit = backing_value - _crv_usd_sold
            keeper_reward_value: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
            if keeper_reward_value > self.max_keeper_reward:
                keeper_reward_value = self.max_keeper_reward
            keeper_reward = keeper_reward_value / BACKING_MULTIPLIER
            assert keeper_reward <= backing_asset_received, "reward exceeds backing"
            if keeper_reward > 0:
                keeper_balance_before: uint256 = BACKING_ASSET.balanceOf(_keeper)
                BACKING_ASSET.transfer(_keeper, keeper_reward)
                keeper_balance_after: uint256 = BACKING_ASSET.balanceOf(_keeper)
                assert keeper_balance_after >= keeper_balance_before, "bad reward delta"
                assert keeper_balance_after - keeper_balance_before == keeper_reward, "bad reward receipt"
            amount_in = backing_asset_received - keeper_reward
        amount_in = self._execute_route_step(step, amount_in)

    yield_token_received: uint256 = amount_in
    assert yield_token_received > 0, "yield output=0"
    trusted_yield_received: uint256 = (
        YIELD_TOKEN.convertToAssets(yield_token_received) * BACKING_MULTIPLIER
    )
    target_value: uint256 = _target_amount * TARGET_MULTIPLIER
    route_retained_value: uint256 = trusted_yield_received + keeper_reward * BACKING_MULTIPLIER
    conversion_cost: uint256 = 0
    if target_value > route_retained_value:
        conversion_cost = target_value - route_retained_value
    assert conversion_cost <= (
        target_value * self.expansion_max_route_loss_bps / BPS
    ), "route loss"
    entry_margin: uint256 = _crv_usd_sold * self.entry_min_profit_ppm / PPM
    assert trusted_yield_received >= _crv_usd_sold + entry_margin, "entry margin"
    return backing_asset_received, yield_token_received, gross_profit, keeper_reward


@external
@nonreentrant("lock")
def deployUndeployedBacking(_target_amount: uint256) -> (uint256, uint256):
    assert not self.all_execution_paused, "all execution paused"
    assert not self.backing_deployment_paused, "backing deployment paused"
    assert _target_amount > 0, "target amount=0"
    assert _target_amount <= self.undeployed_backing, "insufficient backing"
    assert len(self.expansion_path) > 0, "empty expansion path"

    trusted_backing_before: uint256 = self._trusted_backing_value()
    available_deployment_surplus: uint256 = 0
    if trusted_backing_before > self.deployed_crvusd:
        available_deployment_surplus = trusted_backing_before - self.deployed_crvusd

    target_balance_before: uint256 = TARGET_ASSET.balanceOf(self)
    yield_balance_before: uint256 = YIELD_TOKEN.balanceOf(self)
    assert target_balance_before >= self.undeployed_backing, "target accounting"

    self._execute_route(_target_amount, True)

    target_balance_after: uint256 = TARGET_ASSET.balanceOf(self)
    yield_balance_after: uint256 = YIELD_TOKEN.balanceOf(self)
    assert target_balance_before >= target_balance_after, "bad target spend"
    target_spent: uint256 = target_balance_before - target_balance_after
    assert target_spent == _target_amount, "bad target spend"
    assert yield_balance_after >= yield_balance_before, "bad yield output"
    yield_token_received: uint256 = yield_balance_after - yield_balance_before
    assert yield_token_received > 0, "yield output=0"

    target_value_spent: uint256 = target_spent * TARGET_MULTIPLIER
    trusted_value_received: uint256 = (
        YIELD_TOKEN.convertToAssets(yield_token_received) * BACKING_MULTIPLIER
    )
    conversion_cost: uint256 = 0
    if target_value_spent > trusted_value_received:
        conversion_cost = target_value_spent - trusted_value_received
    assert conversion_cost <= (
        target_value_spent * self.expansion_max_route_loss_bps / BPS
    ), "route loss"
    assert conversion_cost <= available_deployment_surplus, "deployment surplus"

    self.undeployed_backing -= target_spent
    self.accounted_yield_token_units += yield_token_received
    assert TARGET_ASSET.balanceOf(self) >= self.undeployed_backing, "target accounting"
    assert YIELD_TOKEN.balanceOf(self) >= self.accounted_yield_token_units, "yield accounting"
    assert self._trusted_backing_value() >= self.deployed_crvusd, "insufficient backing"

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
    assert not self.all_execution_paused, "all execution paused"
    assert not self.yield_contraction_paused, "yield contraction paused"
    assert _yield_token_amount > 0, "yield amount=0"
    assert _yield_token_amount <= self.accounted_yield_token_units, "insufficient yield"
    assert len(self.contraction_path) > 0, "empty contraction path"

    accounted_before: uint256 = self.accounted_yield_token_units
    trusted_value_before: uint256 = self._trusted_yield_value(accounted_before)
    quoted_value_after: uint256 = self._trusted_yield_value(
        accounted_before - _yield_token_amount
    )
    quoted_value_removed: uint256 = trusted_value_before - quoted_value_after
    assert quoted_value_removed <= self.deployed_crvusd, "exposure amount"

    yield_balance_before: uint256 = YIELD_TOKEN.balanceOf(self)
    crv_usd_before: uint256 = CRV_USD.balanceOf(self)
    assert yield_balance_before >= accounted_before, "yield accounting"

    route_output: uint256 = self._execute_route(_yield_token_amount, False)

    yield_balance_after: uint256 = YIELD_TOKEN.balanceOf(self)
    crv_usd_after_swap: uint256 = CRV_USD.balanceOf(self)
    assert yield_balance_before >= yield_balance_after, "bad yield spend"
    yield_token_spent: uint256 = yield_balance_before - yield_balance_after
    assert yield_token_spent == _yield_token_amount, "bad yield spend"
    assert crv_usd_after_swap >= crv_usd_before, "bad crvUSD delta"
    crv_usd_received: uint256 = crv_usd_after_swap - crv_usd_before
    assert crv_usd_received == route_output, "bad crvUSD output"

    trusted_value_after: uint256 = self._trusted_yield_value(
        accounted_before - yield_token_spent
    )
    assert trusted_value_before >= trusted_value_after, "bad yield value"
    trusted_value_removed: uint256 = trusted_value_before - trusted_value_after
    assert trusted_value_removed <= self.deployed_crvusd, "exposure amount"

    gross_profit: uint256 = 0
    if crv_usd_received > trusted_value_removed:
        gross_profit = crv_usd_received - trusted_value_removed
    keeper_reward: uint256 = gross_profit * self.keeper_profit_share_bps / BPS
    if keeper_reward > self.max_keeper_reward:
        keeper_reward = self.max_keeper_reward

    if keeper_reward > 0:
        keeper_balance_before: uint256 = CRV_USD.balanceOf(msg.sender)
        CRV_USD.transfer(msg.sender, keeper_reward)
        keeper_balance_after: uint256 = CRV_USD.balanceOf(msg.sender)
        assert keeper_balance_after >= keeper_balance_before, "bad reward delta"
        assert keeper_balance_after - keeper_balance_before == keeper_reward, "bad reward receipt"

    crv_usd_after_reward: uint256 = CRV_USD.balanceOf(self)
    assert crv_usd_after_swap >= crv_usd_after_reward, "bad reward spend"
    assert crv_usd_after_swap - crv_usd_after_reward == keeper_reward, "bad reward spend"
    assert crv_usd_after_reward >= crv_usd_before, "bad retained crvUSD"
    net_crv_usd: uint256 = crv_usd_after_reward - crv_usd_before

    early_exit: bool = self._is_early_exit()
    exit_margin_ppm: uint256 = self.normal_exit_min_profit_ppm
    if early_exit:
        exit_margin_ppm = self.early_exit_min_profit_ppm
    exit_margin: uint256 = trusted_value_removed * exit_margin_ppm / PPM
    assert net_crv_usd >= trusted_value_removed + exit_margin, "exit margin"

    self.accounted_yield_token_units = accounted_before - yield_token_spent
    exposure_reduction: uint256 = net_crv_usd
    if exposure_reduction > self.deployed_crvusd:
        exposure_reduction = self.deployed_crvusd
    self.deployed_crvusd -= exposure_reduction

    assert YIELD_TOKEN.balanceOf(self) >= self.accounted_yield_token_units, "yield accounting"
    assert self._trusted_backing_value() >= self.deployed_crvusd, "insufficient backing"

    log KeeperBuyback(
        msg.sender,
        BACKING_ASSET.address,
        0,
        yield_token_spent,
        crv_usd_received,
        gross_profit,
        keeper_reward,
        early_exit,
    )
    return yield_token_spent, crv_usd_received, keeper_reward


@external
def set_policy(
    _entry_min_profit_ppm: uint256,
    _normal_exit_min_profit_ppm: uint256,
    _early_exit_min_profit_ppm: uint256,
    _keeper_profit_share_bps: uint256,
    _max_keeper_reward: uint256,
    _min_deployment_time: uint256,
    _min_expansion_amount: uint256,
    _max_deployed_crvusd: uint256,
):
    assert msg.sender == self.admin, "not admin"
    assert _early_exit_min_profit_ppm <= PPM, "margin ppm"
    assert _normal_exit_min_profit_ppm >= _entry_min_profit_ppm, "normal below entry"
    assert _early_exit_min_profit_ppm > _normal_exit_min_profit_ppm, "early not higher"
    assert _keeper_profit_share_bps <= BPS, "keeper share"
    assert _min_expansion_amount > 0, "min expansion=0"
    assert _max_deployed_crvusd > 0, "max deployed=0"

    self.entry_min_profit_ppm = _entry_min_profit_ppm
    self.normal_exit_min_profit_ppm = _normal_exit_min_profit_ppm
    self.early_exit_min_profit_ppm = _early_exit_min_profit_ppm
    self.keeper_profit_share_bps = _keeper_profit_share_bps
    self.max_keeper_reward = _max_keeper_reward
    self.min_deployment_time = _min_deployment_time
    self.min_expansion_amount = _min_expansion_amount
    self.max_deployed_crvusd = _max_deployed_crvusd

    log PolicyUpdated(
        _entry_min_profit_ppm,
        _normal_exit_min_profit_ppm,
        _early_exit_min_profit_ppm,
        _keeper_profit_share_bps,
        _max_keeper_reward,
        _min_deployment_time,
        _min_expansion_amount,
        _max_deployed_crvusd,
    )


@external
def set_roles(_new_admin: address, _new_emergency_admin: address):
    assert msg.sender == self.admin, "not admin"
    assert _new_admin != empty(address), "admin=0"
    assert _new_emergency_admin != empty(address), "emergency admin=0"
    assert _new_admin != _new_emergency_admin, "roles overlap"

    old_admin: address = self.admin
    self.admin = _new_admin
    self.emergency_admin = _new_emergency_admin
    log RolesUpdated(old_admin, _new_admin, _new_emergency_admin)


@external
def set_fee_receiver(_new_fee_receiver: address):
    assert msg.sender == self.admin, "not admin"
    assert _new_fee_receiver != empty(address), "fee receiver=0"
    old_fee_receiver: address = self.fee_receiver
    self.fee_receiver = _new_fee_receiver
    log FeeReceiverUpdated(old_fee_receiver, _new_fee_receiver)


@external
def set_direction_paused(_direction: uint256, _paused: bool):
    assert msg.sender == self.admin or msg.sender == self.emergency_admin, "not authorized"
    if msg.sender == self.emergency_admin:
        assert _paused, "emergency cannot unpause"

    if _direction == DIRECTION_EXPANSION:
        if not _paused:
            assert self.min_downstream_attempt_gas > 0, "downstream gas unset"
            assert self.fallback_settlement_gas_reserve > 0, "fallback gas unset"
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
        raise "bad direction"

    log DirectionPaused(_direction, _paused)


@external
@payable
@nonreentrant("lock")
def execute(_target: address, _value: uint256, _data: Bytes[65535]) -> Bytes[65535]:
    assert msg.sender == self.admin, "not admin"
    assert _target != empty(address), "target=0"

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
@payable
def __default__():
    assert len(msg.data) == 0, "unknown selector"
