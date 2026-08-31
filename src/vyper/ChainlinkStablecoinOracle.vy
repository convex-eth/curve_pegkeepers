# pragma version 0.3.10
"""
@title Chainlink Stablecoin Oracle Adapter
@license MIT
@notice Normalizes one immutable Chainlink Feed Registry base/USD pair to 1e18 pricing.
@dev Rejects non-positive, incomplete, stale, future-dated, and malformed rounds.
"""

interface ChainlinkFeedRegistry:
    def getFeed(_base: address, _quote: address) -> address: view
    def decimals(_base: address, _quote: address) -> uint8: view
    def latestRoundData(_base: address, _quote: address) -> (uint80, int256, uint256, uint256, uint80): view


PRECISION_DECIMALS: constant(uint256) = 18

REGISTRY: immutable(ChainlinkFeedRegistry)
BASE: immutable(address)
QUOTE: immutable(address)
FEED: immutable(address)
FEED_DECIMALS: immutable(uint256)
MAX_DELAY: immutable(uint256)


@external
def __init__(
    _registry: ChainlinkFeedRegistry,
    _base: address,
    _quote: address,
    _expected_feed: address,
    _max_delay: uint256,
):
    assert _registry.address != empty(address)
    assert _registry.address.codesize > 0
    assert _base != empty(address)
    assert _quote != empty(address)
    assert _base != _quote
    assert _expected_feed != empty(address)
    assert _expected_feed.codesize > 0
    assert _max_delay > 0

    feed: address = _registry.getFeed(_base, _quote)
    assert feed == _expected_feed
    decimals: uint256 = convert(_registry.decimals(_base, _quote), uint256)
    assert decimals <= PRECISION_DECIMALS

    REGISTRY = _registry
    BASE = _base
    QUOTE = _quote
    FEED = _expected_feed
    FEED_DECIMALS = decimals
    MAX_DELAY = _max_delay


@external
@pure
def registry() -> address:
    return REGISTRY.address


@external
@pure
def base() -> address:
    return BASE


@external
@pure
def quote() -> address:
    return QUOTE


@external
@pure
def feed() -> address:
    return FEED


@external
@pure
def feed_decimals() -> uint256:
    return FEED_DECIMALS


@external
@pure
def max_delay() -> uint256:
    return MAX_DELAY


@external
@view
def price() -> uint256:
    assert REGISTRY.getFeed(BASE, QUOTE) == FEED

    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, answer, started_at, updated_at, answered_in_round = REGISTRY.latestRoundData(BASE, QUOTE)

    assert round_id > 0
    assert answer > 0
    assert updated_at > 0
    assert updated_at <= block.timestamp
    assert answered_in_round >= round_id
    assert block.timestamp - updated_at <= MAX_DELAY

    return convert(answer, uint256) * 10 ** (PRECISION_DECIMALS - FEED_DECIMALS)
