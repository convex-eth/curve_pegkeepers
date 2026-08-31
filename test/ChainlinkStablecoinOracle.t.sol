// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

interface IChainlinkStablecoinOracle {
    function registry() external view returns (address);
    function base() external view returns (address);
    function quote() external view returns (address);
    function feed() external view returns (address);
    function feed_decimals() external view returns (uint256);
    function max_delay() external view returns (uint256);
    function price() external view returns (uint256);
}

contract MockChainlinkFeedRegistry {
    uint8 public feedDecimals = 8;
    address public feedAddress = address(this);
    uint80 public roundId = 1;
    int256 public answer = 1e8;
    uint256 public startedAt = 1;
    uint256 public updatedAt = 1;
    uint80 public answeredInRound = 1;

    function setFeed(address feed_) external {
        feedAddress = feed_;
    }

    function setDecimals(uint8 decimals_) external {
        feedDecimals = decimals_;
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

    function getFeed(address, address) external view returns (address) {
        return feedAddress;
    }

    function decimals(address, address) external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData(address, address)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

contract ChainlinkStablecoinOracleTest is Test {
    uint256 internal constant MAX_DELAY = 1 hours;
    address internal baseAsset = makeAddr("base");
    address internal quoteAsset = address(840);

    function test_normalizesEightDecimalRegistryFeedToOneEighteen() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        registry.setRound(9, 99_970_000, block.timestamp, 9);

        IChainlinkStablecoinOracle oracle =
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        assertEq(oracle.registry(), address(registry));
        assertEq(oracle.base(), baseAsset);
        assertEq(oracle.quote(), quoteAsset);
        assertEq(oracle.feed(), address(registry));
        assertEq(oracle.feed_decimals(), 8);
        assertEq(oracle.max_delay(), MAX_DELAY);
        assertEq(oracle.price(), 999_700_000_000_000_000);
    }

    function test_preservesEighteenDecimalRegistryFeed() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        registry.setDecimals(18);
        vm.warp(10_000);
        registry.setRound(3, 999_800_000_000_000_000, block.timestamp, 3);

        assertEq(
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY).price(),
            999_800_000_000_000_000
        );
    }

    function test_rejectsZeroAndNegativeAnswers() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle =
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        registry.setRound(2, 0, block.timestamp, 2);
        vm.expectRevert();
        oracle.price();

        registry.setRound(3, -1, block.timestamp, 3);
        vm.expectRevert();
        oracle.price();
    }

    function test_rejectsStaleAndFutureRounds() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle =
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        registry.setRound(2, 1e8, block.timestamp - MAX_DELAY - 1, 2);
        vm.expectRevert();
        oracle.price();

        registry.setRound(3, 1e8, block.timestamp + 1, 3);
        vm.expectRevert();
        oracle.price();
    }

    function test_rejectsIncompleteRounds() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        IChainlinkStablecoinOracle oracle =
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        registry.setRound(10, 1e8, block.timestamp, 9);
        vm.expectRevert();
        oracle.price();

        registry.setRound(11, 1e8, 0, 11);
        vm.expectRevert();
        oracle.price();
    }

    function test_rejectsRegistryFeedRotationAfterDeployment() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        vm.warp(10_000);
        registry.setRound(2, 1e8, block.timestamp, 2);
        IChainlinkStablecoinOracle oracle =
            _deploy(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        MockChainlinkFeedRegistry replacement = new MockChainlinkFeedRegistry();
        registry.setFeed(address(replacement));

        vm.expectRevert();
        oracle.price();
    }

    function test_constructorRejectsInvalidRegistryPairFeedDelayAndDecimals() public {
        MockChainlinkFeedRegistry registry = new MockChainlinkFeedRegistry();
        _expectDeploymentFailure(address(0), baseAsset, quoteAsset, MAX_DELAY);
        _expectDeploymentFailure(makeAddr("no code"), baseAsset, quoteAsset, MAX_DELAY);
        _expectDeploymentFailure(address(registry), address(0), quoteAsset, MAX_DELAY);
        _expectDeploymentFailure(address(registry), baseAsset, address(0), MAX_DELAY);
        _expectDeploymentFailure(address(registry), baseAsset, baseAsset, MAX_DELAY);
        _expectDeploymentFailure(address(registry), baseAsset, quoteAsset, 0);

        registry.setFeed(address(0));
        _expectDeploymentFailure(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        MockChainlinkFeedRegistry replacement = new MockChainlinkFeedRegistry();
        registry.setFeed(address(replacement));
        _expectDeploymentFailure(address(registry), baseAsset, quoteAsset, MAX_DELAY);

        registry.setFeed(address(registry));
        registry.setDecimals(19);
        _expectDeploymentFailure(address(registry), baseAsset, quoteAsset, MAX_DELAY);
    }

    function _expectDeploymentFailure(
        address registry_,
        address base_,
        address quote_,
        uint256 maxDelay_
    ) internal {
        bytes memory creationCode = vm.getCode(
            "out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json"
        );
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(registry_, base_, quote_, registry_, maxDelay_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertEq(deployed, address(0));
    }

    function _deploy(address registry_, address base_, address quote_, uint256 maxDelay_)
        internal
        returns (IChainlinkStablecoinOracle oracle)
    {
        bytes memory creationCode =
            vm.getCode("out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json");
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(registry_, base_, quote_, registry_, maxDelay_));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "oracle deployment failed");
        oracle = IChainlinkStablecoinOracle(deployed);
    }
}
