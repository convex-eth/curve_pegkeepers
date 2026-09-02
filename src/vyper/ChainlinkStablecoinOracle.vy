# pragma version 0.3.10
"""
@title Chainlink Stablecoin Oracle Adapter
@license MIT
@notice Reads one Chainlink price source and returns prices in a standard format.
@dev Rejects missing, invalid, old, or future-dated updates.
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
    """
    @notice Sets the price source and the maximum accepted update age.
    """
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
    """
    @notice Returns the Chainlink price source.
    """
    return FEED.address


@external
@pure
def feed_decimals() -> uint256:
    """
    @notice Returns the number of decimal places used by the price source.
    """
    return FEED_DECIMALS


@external
@pure
def max_delay() -> uint256:
    """
    @notice Returns the maximum accepted age of a price update.
    """
    return MAX_DELAY


@external
@view
def price() -> uint256:
    """
    @notice Returns the latest valid price in a standard 18-decimal format.
    """
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
