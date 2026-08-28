// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegKeeperV3 {
    struct RouteStep {
        uint256 kind;
        address venue;
        address tokenIn;
        address tokenOut;
        int128 poolIndexIn;
        int128 poolIndexOut;
        uint256 executionBufferBps;
    }

    event DirectionPaused(uint256 indexed direction, bool paused);
    event Executed(
        address indexed target, uint256 value, bytes4 indexed selector, bytes32 dataHash
    );
    event ExpansionConfigUpdated(
        uint256 targetAmmExecutionBufferBps,
        uint256 minDownstreamAttemptGas,
        uint256 fallbackSettlementGasReserve
    );
    event Expanded(
        address indexed keeper,
        uint256 crvUsdSold,
        uint256 targetReceived,
        uint256 backingAssetReceived,
        uint256 yieldTokenReceived,
        uint256 grossProfit,
        uint256 keeperReward,
        uint256 backingRetained,
        bool deployedToYield,
        uint256 unlockTime
    );
    event KeeperBuyback(
        address indexed keeper,
        address backingToken,
        uint256 backingSpent,
        uint256 yieldTokenSpent,
        uint256 crvUsdReceived,
        uint256 grossProfit,
        uint256 keeperReward,
        bool earlyExit
    );
    event DirectBuyback(
        address indexed caller, uint256 crvUsdReceived, uint256 yieldTokenPaid, bool earlyExit
    );
    event SurplusClaimed(
        address indexed caller,
        address indexed receiver,
        uint256 crvUsdTransferred,
        uint256 deployedCrvUsdAfter
    );
    event FeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event PathsUpdated(
        bytes32 indexed expansionPathHash,
        bytes32 indexed contractionPathHash,
        uint256 expansionMaxRouteLossBps
    );
    event UndeployedBackingDeployed(
        address indexed caller,
        uint256 targetSpent,
        uint256 yieldTokenReceived,
        uint256 trustedValueReceived,
        uint256 conversionCost
    );

    function version() external view returns (string memory);
    function MAX_ROUTE_STEPS() external pure returns (uint256);

    function factory() external view returns (address);
    function crv_usd() external view returns (address);
    function target_amm() external view returns (address);
    function target_asset() external view returns (address);
    function backing_asset() external view returns (address);
    function yield_token() external view returns (address);
    function fee_receiver() external view returns (address);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function target_amm_crvusd_index() external view returns (uint256);
    function target_amm_target_index() external view returns (uint256);

    function coins(uint256 index) external view returns (address);
    function trusted_backing_value() external view returns (uint256);
    function protocol_surplus() external view returns (uint256);

    function entry_min_profit_ppm() external view returns (uint256);
    function normal_exit_min_profit_ppm() external view returns (uint256);
    function early_exit_min_profit_ppm() external view returns (uint256);
    function keeper_profit_share_bps() external view returns (uint256);
    function max_keeper_reward() external view returns (uint256);
    function min_deployment_time() external view returns (uint256);
    function min_expansion_amount() external view returns (uint256);
    function max_deployed_crvusd() external view returns (uint256);
    function target_amm_execution_buffer_bps() external view returns (uint256);
    function min_downstream_attempt_gas() external view returns (uint256);
    function fallback_settlement_gas_reserve() external view returns (uint256);

    function deployed_crvusd() external view returns (uint256);
    function undeployed_backing() external view returns (uint256);
    function accounted_yield_token_units() external view returns (uint256);
    function last_expansion_at() external view returns (uint256);

    function expansion_paused() external view returns (bool);
    function backing_deployment_paused() external view returns (bool);
    function direct_buyback_paused() external view returns (bool);
    function undeployed_contraction_paused() external view returns (bool);
    function yield_contraction_paused() external view returns (bool);
    function all_execution_paused() external view returns (bool);

    function set_direction_paused(uint256 direction, bool paused) external;
    function set_expansion_config(
        uint256 targetAmmExecutionBufferBps,
        uint256 minDownstreamAttemptGas,
        uint256 fallbackSettlementGasReserve
    ) external;
    function set_fee_receiver(address newFeeReceiver) external;
    function setPaths(
        RouteStep[] calldata expansionSteps,
        uint256 expansionMaxRouteLossBps,
        RouteStep[] calldata contractionSteps
    ) external;
    function expansion_path_length() external view returns (uint256);
    function contraction_path_length() external view returns (uint256);
    function expansion_max_route_loss_bps() external view returns (uint256);
    function expansion_path_step(uint256 index) external view returns (RouteStep memory);
    function contraction_path_step(uint256 index) external view returns (RouteStep memory);
    function available_expansion() external view returns (uint256);
    function expand(uint256 crvUsdAmount)
        external
        returns (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,
            uint256 keeperReward,
            bool deployedToYield
        );
    function executeExpansionPath(uint256 targetAmount, uint256 crvUsdSold, address keeper)
        external
        returns (
            uint256 backingAssetReceived,
            uint256 yieldTokenReceived,
            uint256 grossProfit,
            uint256 keeperReward
        );
    function previewBuyback(uint256 crvUsdAmount)
        external
        view
        returns (uint256 expectedYieldTokenOut, uint256 requiredExitProfit, bool earlyExit);
    function buyback(uint256 crvUsdAmount, uint256 minYieldTokenOut)
        external
        returns (uint256 yieldTokenOut);
    function previewUndeployedContraction(uint256 targetAmount)
        external
        view
        returns (
            uint256 expectedCrvUsdOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward,
            bool earlyExit
        );
    function previewKeeperBuyback(uint256 yieldTokenAmount)
        external
        view
        returns (
            uint256 expectedCrvUsdOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward,
            bool earlyExit
        );
    function contractUndeployedBacking(uint256 targetAmount)
        external
        returns (uint256 targetSpent, uint256 crvUsdReceived, uint256 keeperReward);
    function contractViaAmm(uint256 yieldTokenAmount)
        external
        returns (uint256 yieldTokenSpent, uint256 crvUsdReceived, uint256 keeperReward);
    function deployUndeployedBacking(uint256 targetAmount)
        external
        returns (uint256 targetSpent, uint256 yieldTokenReceived);
    function claimSurplus(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
