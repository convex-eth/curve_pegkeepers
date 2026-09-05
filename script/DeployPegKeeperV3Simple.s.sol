// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/console2.sol";

import {DeployPegKeeperV3} from "./DeployPegKeeperV3.s.sol";

/// @notice Alternative dependency deployer for the direct frxUSD and sUSDe PegKeeperV3 launch.
/// @dev Adds a USDe/USD adapter to the standard preview/implementation/factory/frxUSD package.
contract DeployPegKeeperV3Simple is DeployPegKeeperV3 {
    string public constant SIMPLE_DEPLOYMENT_OUTPUT_PATH =
        "deployments/mainnet/PegKeeperV3-simple-deployment.json";

    address public constant USDE_USD_PROXY = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    /// @dev Chainlink publishes a 23-hour heartbeat. This adds a two-hour grace period.
    uint256 public constant RECOMMENDED_USDE_CHAINLINK_MAX_DELAY = 25 hours;

    struct SimpleDeployment {
        address previewModule;
        address implementation;
        address factory;
        address frxUsdUsdOracle;
        address usDeUsdOracle;
    }

    function run() external override returns (Deployment memory deployment) {
        require(block.chainid == 1, "mainnet required");
        Config memory config = mainnetConfig();
        _logSimplePlan(config);

        vm.startBroadcast();
        SimpleDeployment memory simpleDeployment = deploySimple(config);
        vm.stopBroadcast();

        writeSimpleDeploymentJson(simpleDeployment, SIMPLE_DEPLOYMENT_OUTPUT_PATH);
        _logSimpleDeployment(simpleDeployment);
        deployment = Deployment({
            previewModule: simpleDeployment.previewModule,
            implementation: simpleDeployment.implementation,
            factory: simpleDeployment.factory,
            frxUsdUsdOracle: simpleDeployment.frxUsdUsdOracle
        });
    }

    function deploySimple(Config memory config)
        public
        returns (SimpleDeployment memory simpleDeployment)
    {
        return deploySimple(config, USDE_USD_PROXY, RECOMMENDED_USDE_CHAINLINK_MAX_DELAY);
    }

    function deploySimple(Config memory config, address usDeProxy, uint256 usDeMaxDelay)
        public
        returns (SimpleDeployment memory simpleDeployment)
    {
        Deployment memory standardDeployment = deploy(config);
        console2.log("Deploying Chainlink USDe/USD oracle");
        address usDeUsdOracle = _deployChainlinkAdapter(usDeProxy, usDeMaxDelay);
        _verifyChainlinkOracle(usDeUsdOracle, usDeProxy, usDeMaxDelay);

        simpleDeployment = SimpleDeployment({
            previewModule: standardDeployment.previewModule,
            implementation: standardDeployment.implementation,
            factory: standardDeployment.factory,
            frxUsdUsdOracle: standardDeployment.frxUsdUsdOracle,
            usDeUsdOracle: usDeUsdOracle
        });
    }

    function writeSimpleDeploymentJson(SimpleDeployment memory deployment, string memory outputPath)
        public
    {
        string memory objectKey = "pegKeeperV3SimpleDeployment";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeAddress(objectKey, "previewModule", deployment.previewModule);
        vm.serializeAddress(objectKey, "implementation", deployment.implementation);
        vm.serializeAddress(objectKey, "factory", deployment.factory);
        vm.serializeAddress(objectKey, "frxUsdUsdOracle", deployment.frxUsdUsdOracle);
        string memory json =
            vm.serializeAddress(objectKey, "usDeUsdOracle", deployment.usDeUsdOracle);
        vm.writeJson(json, outputPath);
    }

    function _logSimplePlan(Config memory config) internal pure {
        console2.log("PegKeeperV3 simple direct-pool mainnet deployment");
        console2.log("Factory owner", config.owner);
        console2.log("ControllerFactory", config.controllerFactory);
        console2.log("Aggregate crvUSD oracle", config.aggregateCrvUsdOracle);
        console2.log("frxUSD Chainlink proxy", config.frxUsdProxy);
        console2.log("USDe Chainlink proxy", USDE_USD_PROXY);
        console2.log("USDe max delay", RECOMMENDED_USDE_CHAINLINK_MAX_DELAY);
        console2.log("Output", SIMPLE_DEPLOYMENT_OUTPUT_PATH);
    }

    function _logSimpleDeployment(SimpleDeployment memory deployment) internal pure {
        console2.log("Preview module", deployment.previewModule);
        console2.log("Implementation", deployment.implementation);
        console2.log("Factory", deployment.factory);
        console2.log("Chainlink frxUSD/USD oracle", deployment.frxUsdUsdOracle);
        console2.log("Chainlink USDe/USD oracle", deployment.usDeUsdOracle);
        console2.log("Deployment JSON", SIMPLE_DEPLOYMENT_OUTPUT_PATH);
    }
}
