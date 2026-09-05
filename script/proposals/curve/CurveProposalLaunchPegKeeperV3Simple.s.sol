// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CurveProposalLaunchPegKeeperV3} from "./CurveProposalLaunchPegKeeperV3.s.sol";
import {IPegKeeperV3} from "../../../src/interfaces/IPegKeeperV3.sol";
import {IPegKeeperV3Factory} from "../../../src/interfaces/IPegKeeperV3Factory.sol";

interface ISimpleRateAwarePool {
    function coins(uint256 index) external view returns (address);
    function get_virtual_price() external view returns (uint256);
    function stored_rates() external view returns (uint256[] memory);
}

interface ISimpleErc4626 {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title CurveProposalLaunchPegKeeperV3Simple
/// @notice Alternative launch of two paused keepers that deposit directly into their target AMMs.
/// @dev There are no swap routes: arbitrageurs balance the crvUSD/frxUSD and crvUSD/sUSDe pools.
contract CurveProposalLaunchPegKeeperV3Simple is CurveProposalLaunchPegKeeperV3 {
    string public constant SIMPLE_DEPLOYMENT_INPUT_PATH =
        "deployments/mainnet/PegKeeperV3-simple-deployment.json";

    uint256 public constant FRXUSD_CHAINLINK_MAX_DELAY = 26 hours;
    uint256 public constant USDE_CHAINLINK_MAX_DELAY = 25 hours;
    uint256 public constant SUSDE_CAP = 20_000_000e18;

    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant USDE_USD_PROXY = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address public constant SUSDE_CRVUSD_POOL = 0x57064F49Ad7123C92560882a45518374ad982e85;

    address public usDeOracle;

    function run() external override returns (uint256 proposalId) {
        loadSimpleDeployment(SIMPLE_DEPLOYMENT_INPUT_PATH);
        vm.startBroadcast();
        bytes memory script = buildProposalScript();
        proposalId = proposeOwnershipVote(
            script, "Deploy and register two paused direct PegKeeperV3 keepers for frxUSD and sUSDe"
        );
        vm.stopBroadcast();
    }

    function loadSimpleDeployment(string memory path) public {
        string memory json = vm.readFile(path);
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "deployment chain");
        deploymentFactory = vm.parseJsonAddress(json, ".factory");
        frxUsdOracle = vm.parseJsonAddress(json, ".frxUsdUsdOracle");
        usDeOracle = vm.parseJsonAddress(json, ".usDeUsdOracle");
    }

    function setOracleAdapters(address frxUsdUsdOracle, address usDeUsdOracle) external {
        require(frxUsdUsdOracle != address(0), "zero frxUSD oracle");
        require(usDeUsdOracle != address(0), "zero USDe oracle");
        frxUsdOracle = frxUsdUsdOracle;
        usDeOracle = usDeUsdOracle;
    }

    function buildProposalScript() public view override returns (bytes memory script) {
        script = buildScript(CURVE_OWNERSHIP_AGENT, buildProposalActions());
    }

    function buildProposalActions() public view override returns (Action[] memory actions) {
        _validateFactory();
        _validateChainlinkOracle(frxUsdOracle, FRXUSD_USD_PROXY, FRXUSD_CHAINLINK_MAX_DELAY);
        _validateChainlinkOracle(usDeOracle, USDE_USD_PROXY, USDE_CHAINLINK_MAX_DELAY);
        _validateMonetaryPolicies();
        _validateDirectPools();

        address frxUsdKeeper = expectedKeeper(1);
        address sUsdeKeeper = expectedKeeper(2);
        IPegKeeperV3.RouteStep[] memory emptyPath = new IPegKeeperV3.RouteStep[](0);
        actions = new Action[](14);

        actions[0] = _setDefaultsAction(FRXUSD_CAP);
        actions[1] = _deployAction(
            FRXUSD_CRVUSD_POOL, FRXUSD, FRXUSD_CRVUSD_POOL, false, frxUsdOracle, emptyPath
        );
        actions[2] = _setBackingOraclePolicyAction(frxUsdKeeper, frxUsdOracle);
        actions[3] = _setPolicyAction(frxUsdKeeper, FRXUSD_CAP);
        actions[4] = _setInterventionPolicyAction(frxUsdKeeper);
        actions[5] = _debtCeilingAction(frxUsdKeeper, FRXUSD_CAP);
        actions[6] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, frxUsdKeeper);
        actions[7] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, frxUsdKeeper);

        actions[8] =
            _deployAction(SUSDE_CRVUSD_POOL, SUSDE, SUSDE_CRVUSD_POOL, true, usDeOracle, emptyPath);
        actions[9] = _setBackingOraclePolicyAction(sUsdeKeeper, usDeOracle);
        actions[10] = _setPolicyAction(sUsdeKeeper, SUSDE_CAP);
        actions[11] = _setInterventionPolicyAction(sUsdeKeeper);
        actions[12] = _monetaryPolicyAction(CRVUSD_MONETARY_POLICY, sUsdeKeeper);
        actions[13] = _monetaryPolicyAction(CRVUSD_LEGACY_MONETARY_POLICY, sUsdeKeeper);
    }

    function _setBackingOraclePolicyAction(address keeper, address oracle)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            target: keeper,
            data: abi.encodeWithSelector(
                IPegKeeperV3.set_yield_oracle_policy.selector, oracle, MIN_YIELD_ORACLE_PRICE
            )
        });
    }

    function _validateDirectPools() internal view {
        ISimpleRateAwarePool frxUsdPool = ISimpleRateAwarePool(FRXUSD_CRVUSD_POOL);
        require(frxUsdPool.coins(0) == FRXUSD, "frxUSD pool coin 0");
        require(frxUsdPool.coins(1) == CRVUSD, "frxUSD pool coin 1");
        require(frxUsdPool.get_virtual_price() > 0, "frxUSD virtual price");

        ISimpleRateAwarePool sUsdePool = ISimpleRateAwarePool(SUSDE_CRVUSD_POOL);
        require(sUsdePool.coins(0) == CRVUSD, "sUSDe pool coin 0");
        require(sUsdePool.coins(1) == SUSDE, "sUSDe pool coin 1");
        require(sUsdePool.get_virtual_price() > 0, "sUSDe virtual price");
        require(ISimpleErc4626(SUSDE).asset() == USDE, "sUSDe asset");

        uint256[] memory rates = sUsdePool.stored_rates();
        require(rates.length == 2, "sUSDe pool rates length");
        require(rates[0] == 1e18, "crvUSD pool rate");
        uint256 assetsPerShare = ISimpleErc4626(SUSDE).convertToAssets(1e18);
        uint256 rateDifference =
            rates[1] > assetsPerShare ? rates[1] - assetsPerShare : assetsPerShare - rates[1];
        require(rateDifference <= assetsPerShare / 10_000, "sUSDe pool rate drift");
    }
}
