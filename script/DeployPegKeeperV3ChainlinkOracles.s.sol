// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";

import {IChainlinkStablecoinOracle} from "../src/interfaces/IChainlinkStablecoinOracle.sol";

interface IChainlinkFeedRegistry {
    function getFeed(address base, address quote) external view returns (address);
}

contract DeployPegKeeperV3ChainlinkOracles is Script {
    address public constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant USD = address(840);
    address public constant FRXUSD = 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant FRXUSD_USD_FEED = 0x62a897c3e81d809c7444BB63D7D51E1F2EbB6C3D;
    address public constant USDS_USD_FEED = 0x592700e4FcDd674dC54d2681DED3B63f54F63f9A;

    struct Config {
        address registry;
        address quote;
        address frxUsd;
        address frxUsdExpectedFeed;
        uint256 frxUsdMaxDelay;
        address usds;
        address usdsExpectedFeed;
        uint256 usdsMaxDelay;
    }

    function run() external returns (address frxUsdOracle, address usdsOracle) {
        require(block.chainid == 1, "mainnet required");
        validateMainnetRegistry();
        Config memory config = Config({
            registry: CHAINLINK_FEED_REGISTRY,
            quote: USD,
            frxUsd: FRXUSD,
            frxUsdExpectedFeed: FRXUSD_USD_FEED,
            frxUsdMaxDelay: vm.envUint("PKV3_FRXUSD_CHAINLINK_MAX_DELAY"),
            usds: USDS,
            usdsExpectedFeed: USDS_USD_FEED,
            usdsMaxDelay: vm.envUint("PKV3_USDS_CHAINLINK_MAX_DELAY")
        });
        vm.startBroadcast();
        (frxUsdOracle, usdsOracle) = deploy(config);
        vm.stopBroadcast();
    }

    function validateMainnetRegistry() public view {
        require(block.chainid == 1, "mainnet required");
        IChainlinkFeedRegistry registry = IChainlinkFeedRegistry(CHAINLINK_FEED_REGISTRY);
        require(registry.getFeed(FRXUSD, USD) == FRXUSD_USD_FEED, "frxUSD feed changed");
        require(registry.getFeed(USDS, USD) == USDS_USD_FEED, "USDS feed changed");
    }

    function deploy(Config memory config)
        public
        returns (address frxUsdOracle, address usdsOracle)
    {
        frxUsdOracle = _deployAdapter(
            config.registry,
            config.frxUsd,
            config.quote,
            config.frxUsdExpectedFeed,
            config.frxUsdMaxDelay
        );
        usdsOracle = _deployAdapter(
            config.registry, config.usds, config.quote, config.usdsExpectedFeed, config.usdsMaxDelay
        );

        _verify(
            frxUsdOracle,
            config.registry,
            config.frxUsd,
            config.quote,
            config.frxUsdExpectedFeed,
            config.frxUsdMaxDelay
        );
        _verify(
            usdsOracle,
            config.registry,
            config.usds,
            config.quote,
            config.usdsExpectedFeed,
            config.usdsMaxDelay
        );
    }

    function _deployAdapter(
        address registry,
        address base,
        address quote,
        address expectedFeed,
        uint256 maxDelay
    ) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode(
            "out/ChainlinkStablecoinOracle.vy/ChainlinkStablecoinOracle.json"
        );
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(registry, base, quote, expectedFeed, maxDelay));
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _verify(
        address adapter,
        address registry,
        address base,
        address quote,
        address expectedFeed,
        uint256 maxDelay
    ) internal view {
        require(adapter.code.length > 0, "oracle code missing");
        IChainlinkStablecoinOracle oracle = IChainlinkStablecoinOracle(adapter);
        require(oracle.registry() == registry, "oracle registry mismatch");
        require(oracle.base() == base, "oracle base mismatch");
        require(oracle.quote() == quote, "oracle quote mismatch");
        require(oracle.feed() == expectedFeed, "oracle feed mismatch");
        require(oracle.feed_decimals() <= 18, "oracle decimals invalid");
        require(oracle.max_delay() == maxDelay, "oracle delay mismatch");
        require(oracle.price() > 0, "oracle price invalid");
    }
}
