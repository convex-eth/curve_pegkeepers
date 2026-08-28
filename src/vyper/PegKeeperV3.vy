# pragma version 0.3.10
"""
@title PegKeeper V3
@license MIT
@notice Asymmetric inventory-backed crvUSD PegKeeper
@dev Initial implementation foundation: fixed endpoints, trusted accounting, roles, pauses, and recovery execution.
"""

interface ERC20:
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view

interface ControllerFactory:
    def stablecoin() -> address: view

interface TwoCoinPool:
    def coins(_index: uint256) -> address: view

interface YieldToken:
    def asset() -> address: view
    def balanceOf(_owner: address) -> uint256: view
    def decimals() -> uint256: view
    def convertToAssets(_yield_token_amount: uint256) -> uint256: view
    def convertToShares(_backing_asset_amount: uint256) -> uint256: view


event DirectionPaused:
    direction: indexed(uint256)
    paused: bool

event Executed:
    target: indexed(address)
    value: uint256
    selector: indexed(bytes4)
    data_hash: bytes32


version: public(constant(String[8])) = "3.0.0"

PPM: constant(uint256) = 1_000_000
BPS: constant(uint256) = 10_000

DIRECTION_EXPANSION: constant(uint256) = 0
DIRECTION_BACKING_DEPLOYMENT: constant(uint256) = 1
DIRECTION_DIRECT_BUYBACK: constant(uint256) = 2
DIRECTION_UNDEPLOYED_CONTRACTION: constant(uint256) = 3
DIRECTION_YIELD_CONTRACTION: constant(uint256) = 4
DIRECTION_ALL: constant(uint256) = 5

FACTORY: immutable(ControllerFactory)
CRV_USD: immutable(ERC20)
TARGET_AMM: immutable(TwoCoinPool)
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
min_downstream_attempt_gas: public(uint256)
fallback_settlement_gas_reserve: public(uint256)

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
    TARGET_AMM = _target_amm
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
def target_amm() -> address:
    return TARGET_AMM.address


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
    pass
