# pragma version 0.3.10
"""
@title Curve Stablecoin Oracle Adapter
@license MIT
@notice Normalizes a two-coin Curve StableSwap-NG EMA to asset/reference 1e18 pricing.
@dev Curve price_oracle(0) is coin[1] quoted in coin[0], with configured rate providers applied.
"""

interface CurvePool:
    def coins(_index: uint256) -> address: view
    def price_oracle(_index: uint256) -> uint256: view


PRECISION: constant(uint256) = 10 ** 18

POOL: immutable(CurvePool)
ASSET: immutable(address)
REFERENCE_ASSET: immutable(address)
INVERTED: immutable(bool)


@external
def __init__(_pool: CurvePool, _asset: address, _reference_asset: address):
    assert _pool.address != empty(address)
    assert _pool.address.codesize > 0
    assert _asset != empty(address)
    assert _reference_asset != empty(address)
    assert _asset != _reference_asset

    coin_0: address = _pool.coins(0)
    coin_1: address = _pool.coins(1)
    inverted: bool = False
    if coin_0 == _reference_asset and coin_1 == _asset:
        inverted = False
    elif coin_0 == _asset and coin_1 == _reference_asset:
        inverted = True
    else:
        raise

    assert _pool.price_oracle(0) > 0
    POOL = _pool
    ASSET = _asset
    REFERENCE_ASSET = _reference_asset
    INVERTED = inverted


@external
@pure
def pool() -> address:
    return POOL.address


@external
@pure
def asset() -> address:
    return ASSET


@external
@pure
def reference_asset() -> address:
    return REFERENCE_ASSET


@external
@pure
def inverted() -> bool:
    return INVERTED


@external
@view
def price() -> uint256:
    oracle_price: uint256 = POOL.price_oracle(0)
    assert oracle_price > 0
    if INVERTED:
        return PRECISION * PRECISION / oracle_price
    return oracle_price
