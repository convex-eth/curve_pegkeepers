// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";

contract MockChainlinkAggregator {
    uint8 public feedDecimals = 8;
    uint80 public roundId = 1;
    int256 public answer = 1e8;
    uint256 public startedAt = 1;
    uint256 public updatedAt = 1;
    uint80 public answeredInRound = 1;

    function setDecimals(uint8 decimals_) external {
        feedDecimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract MockChainlinkProxy {
    MockChainlinkAggregator public aggregator;

    constructor(MockChainlinkAggregator aggregator_) {
        aggregator = aggregator_;
    }

    function setAggregator(MockChainlinkAggregator aggregator_) external {
        aggregator = aggregator_;
    }

    function decimals() external view returns (uint8) {
        return aggregator.decimals();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return aggregator.latestRoundData();
    }
}

contract ChainlinkStablecoinOracleTest is Test {
    uint256 internal constant MAX_DELAY = 1 hours;

    function test_normalizesEightDecimalProxyFeedToOneEighteen() public {
        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        vm.warp(10_000);
        aggregator.setRound(9, 99_970_000, block.timestamp, 9);

        IChainlinkStablecoinOracle oracle = _deploy(address(proxy), MAX_DELAY);

        assertEq(oracle.feed(), address(proxy));
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), MAX_DELAY);
        assertEq(oracle.price(), 999_700_000_000_000_000);
    }

    function test_preservesEighteenDecimalProxyFeed() public {
        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        aggregator.setDecimals(18);
        vm.warp(10_000);
        aggregator.setRound(3, 999_800_000_000_000_000, block.timestamp, 3);

        assertEq(_deploy(address(proxy), MAX_DELAY).price(), 999_800_000_000_000_000);
    }

    function test_rejectsZeroAndNegativeAnswers() public {
        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle = _deploy(address(proxy), MAX_DELAY);

        aggregator.setRound(2, 0, block.timestamp, 2);
        vm.expectRevert();
        oracle.price();

        aggregator.setRound(3, -1, block.timestamp, 3);
        vm.expectRevert();
        oracle.price();
    }

    function test_rejectsStaleAndFutureRounds() public {
        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle = _deploy(address(proxy), MAX_DELAY);

        aggregator.setRound(2, 1e8, block.timestamp - MAX_DELAY - 1, 2);
        vm.expectRevert();
        oracle.price();

        aggregator.setRound(3, 1e8, block.timestamp + 1, 3);
        vm.expectRevert();
        oracle.price();
    }

    function test_rejectsIncompleteRounds() public {
        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle = _deploy(address(proxy), MAX_DELAY);

        aggregator.setRound(10, 1e8, block.timestamp, 9);
        vm.expectRevert();
        oracle.price();

        aggregator.setRound(11, 1e8, 0, 11);
        vm.expectRevert();
        oracle.price();
    }

    function test_proxyAggregatorRotationRemainsLive() public {
        (MockChainlinkAggregator first, MockChainlinkProxy proxy) = _newProxy();
        vm.warp(10_000);
        first.setRound(2, 1e8, block.timestamp, 2);
        IChainlinkStablecoinOracle oracle = _deploy(address(proxy), MAX_DELAY);
        assertEq(oracle.price(), 1e18);

        MockChainlinkAggregator replacement = new MockChainlinkAggregator();
        replacement.setRound(3, 99_980_000, block.timestamp, 3);
        proxy.setAggregator(replacement);

        assertEq(oracle.price(), 999_800_000_000_000_000);
        assertEq(oracle.feed(), address(proxy));
    }

    function test_constructorRejectsInvalidFeedDelayAndDecimals() public {
        _expectDeploymentFailure(address(0), MAX_DELAY);
        _expectDeploymentFailure(makeAddr("no code"), MAX_DELAY);

        (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy) = _newProxy();
        _expectDeploymentFailure(address(proxy), 0);

        aggregator.setDecimals(19);
        _expectDeploymentFailure(address(proxy), MAX_DELAY);
    }

    function _newProxy()
        internal
        returns (MockChainlinkAggregator aggregator, MockChainlinkProxy proxy)
    {
        aggregator = new MockChainlinkAggregator();
        proxy = new MockChainlinkProxy(aggregator);
    }

    function _expectDeploymentFailure(address feed_, uint256 maxDelay_) internal {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(feed_, maxDelay_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertEq(deployed, address(0));
    }

    function _deploy(address feed_, uint256 maxDelay_)
        internal
        returns (IChainlinkStablecoinOracle oracle)
    {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        bytes memory initCode = bytes.concat(creationCode, abi.encode(feed_, maxDelay_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "oracle deployment failed");
        oracle = IChainlinkStablecoinOracle(deployed);
    }
}
