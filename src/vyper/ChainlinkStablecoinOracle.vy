# pragma version 0.3.10
"""
@title Chainlink Stablecoin Oracle Adapter
@license MIT
@notice Normalizes one immutable canonical Chainlink proxy feed to 1e18 pricing.
@dev Rejects non-positive, incomplete, stale, future-dated, and malformed rounds.
"""

interface ChainlinkFeed:
    def decimals() -> uint8: view
    def latestRoundData() -> (uint80, int256, uint256, uint256, uint80): view


PRECISION_DECIMALS: constant(uint256) = 18

FEED: immutable(ChainlinkFeed)
FEED_DECIMALS: immutable(uint256)
MAX_DELAY: immutable(uint256)


@external
def __init__(
    _feed: ChainlinkFeed,
    _max_delay: uint256,
):
    assert _feed.address != empty(address)
    assert _feed.address.codesize > 0
    assert _max_delay > 0

    decimals: uint256 = convert(_feed.decimals(), uint256)
    assert decimals <= PRECISION_DECIMALS

    FEED = _feed
    FEED_DECIMALS = decimals
    MAX_DELAY = _max_delay


@external
@pure
def feed() -> address:
    return FEED.address


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
    round_id: uint80 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    round_id, answer, started_at, updated_at, answered_in_round = FEED.latestRoundData()

    assert round_id > 0
    assert answer > 0
    assert updated_at > 0
    assert updated_at <= block.timestamp
    assert answered_in_round >= round_id
    assert block.timestamp - updated_at <= MAX_DELAY

    return convert(answer, uint256) * 10 ** (PRECISION_DECIMALS - FEED_DECIMALS)
