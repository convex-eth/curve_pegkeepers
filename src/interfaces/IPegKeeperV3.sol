// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Lists the public functions available on a PegKeeperV3 contract.
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
    event TargetAmmUpdated(
        address indexed oldTargetAmm,
        address indexed newTargetAmm,
        uint256 crvUsdIndex,
        uint256 targetIndex,
        uint256 executionBufferBps
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

    event PolicyUpdated(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 earlyExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minDeploymentTime,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    );

    event PathsUpdated(
        bytes32 indexed expansionPathHash,
        bytes32 indexed contractionPathHash,
        uint256 expansionMaxRouteLossBps
    );
    event OraclePolicyUpdated(
        address indexed targetOracle,
        address indexed yieldOracle,
        uint256 minTargetPrice,
        uint256 minYieldPrice
    );
    event UndeployedBackingDeployed(
        address indexed caller,
        uint256 targetSpent,
        uint256 yieldTokenReceived,
        uint256 trustedValueReceived,
        uint256 conversionCost
    );
    event YieldBackingUnwound(
        address indexed caller,
        uint256 yieldTokenSpent,
        uint256 targetReceived,
        uint256 trustedValueSpent,
        uint256 conversionCost
    );

    /// @notice Returns the contract version.
    function version() external view returns (string memory);
    /// @notice Returns the keeper's display name.
    function name() external view returns (string memory);
    /// @notice Returns the number assigned to this keeper by the factory.
    function keeper_index() external view returns (uint256);
    /// @notice Returns the most steps allowed in a token route.
    function MAX_ROUTE_STEPS() external view returns (uint256);
    /// @notice Returns whether this keeper has been set up.
    function initialized() external view returns (bool);
    /// @notice Returns the contract used to calculate action estimates.
    function preview_module() external view returns (address);

    /// @notice Returns the factory that created this keeper.
    function factory() external view returns (address);
    /// @notice Returns the shared contract that provides crvUSD and debt limits.
    function controller_factory() external view returns (address);
    /// @notice Returns the crvUSD token address.
    function crv_usd() external view returns (address);
    /// @notice Returns the main pool used to swap crvUSD and the target token.
    function target_amm() external view returns (address);
    /// @notice Returns the token paired with crvUSD in the main swap pool.
    function target_asset() external view returns (address);
    /// @notice Returns the asset represented by the final token.
    function backing_asset() external view returns (address);
    /// @notice Returns the final token held after the configured token path.
    function yield_token() external view returns (address);
    /// @notice Returns whether the final token represents shares in a token vault.
    function yield_token_is_erc4626() external view returns (bool);
    /// @notice Returns the backing-asset amount represented by a final-token amount.
    function yield_token_assets(uint256 units) external view returns (uint256);
    /// @notice Returns the final-token amount represented by a backing-asset amount.
    function yield_token_units(uint256 assets) external view returns (uint256);
    /// @notice Returns the price source for the target token.
    function target_oracle() external view returns (address);
    /// @notice Returns the price source for the asset represented by the final token.
    function yield_oracle() external view returns (address);
    /// @notice Returns the lowest accepted target-token price.
    function min_target_oracle_price() external view returns (uint256);
    /// @notice Returns the lowest accepted price for the asset represented by the final token.
    function min_yield_oracle_price() external view returns (uint256);
    /// @notice Returns the largest short-term expansion as a share of the keeper limit.
    function max_expansion_burst_bps() external view returns (uint256);
    /// @notice Returns how long the short-term expansion allowance takes to refill.
    function expansion_refill_period() external view returns (uint256);
    /// @notice Returns the account that receives claimed crvUSD surplus.
    function fee_receiver() external view returns (address);
    /// @notice Returns the account allowed to change keeper settings.
    function admin() external view returns (address);
    /// @notice Returns the account allowed to pause keeper actions.
    function emergency_admin() external view returns (address);
    /// @notice Returns the crvUSD position in the main swap pool.
    function target_amm_crvusd_index() external view returns (uint256);
    /// @notice Returns the target-token position in the main swap pool.
    function target_amm_target_index() external view returns (uint256);

    /// @notice Returns crvUSD for index 0 and the final token for index 1.
    function coins(uint256 index) external view returns (address);
    /// @notice Returns the total backing value, treating target and backing assets as worth one dollar each.
    function trusted_backing_value() external view returns (uint256);
    /// @notice Returns backing value above the crvUSD amount this keeper must cover.
    function protocol_surplus() external view returns (uint256);

    /// @notice Returns the minimum profit required when buying backing.
    function entry_min_profit_ppm() external view returns (uint256);
    /// @notice Returns the minimum profit required after the minimum holding time.
    function normal_exit_min_profit_ppm() external view returns (uint256);
    /// @notice Returns the minimum profit required before the minimum holding time.
    function early_exit_min_profit_ppm() external view returns (uint256);
    /// @notice Returns the caller's share of profit from keeper actions.
    function keeper_profit_share_bps() external view returns (uint256);
    /// @notice Returns the time that must pass before the lower exit profit applies.
    function min_deployment_time() external view returns (uint256);
    /// @notice Returns the smallest allowed expansion.
    function min_expansion_amount() external view returns (uint256);
    /// @notice Returns the most crvUSD this keeper may record as deployed.
    function max_deployed_crvusd() external view returns (uint256);
    /// @notice Returns the largest allowed drop below the main pool's quote.
    function target_amm_execution_buffer_bps() external view returns (uint256);
    /// @notice Returns the minimum gas required before trying the post-expansion token path.
    function min_downstream_attempt_gas() external view returns (uint256);
    /// @notice Returns the gas kept to finish the trade if the token path fails.
    function fallback_settlement_gas_reserve() external view returns (uint256);

    /// @notice Returns the recorded crvUSD amount for compatibility with existing tools.
    function debt() external view returns (uint256);
    /// @notice Returns the recorded crvUSD amount backed by this keeper.
    function deployed_crvusd() external view returns (uint256);
    /// @notice Returns the keeper's current balance of the target token.
    function undeployed_backing() external view returns (uint256);
    /// @notice Returns the keeper's current balance of the final token.
    function accounted_yield_token_units() external view returns (uint256);
    /// @notice Returns the time of the latest successful expansion.
    function last_expansion_at() external view returns (uint256);
    /// @notice Returns how much of the recent expansion allowance is still in use.
    function expansion_pressure() external view returns (uint256);
    /// @notice Returns the last time the short-term expansion limit was updated.
    function last_expansion_pressure_update() external view returns (uint256);
    /// @notice Returns how much can be expanded now under the short-term rate limit.
    function available_expansion_velocity() external view returns (uint256);

    /// @notice Sets up a new keeper with its pool, tokens, limits, and price sources.
    function initialize(
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        uint256 maxDeployedCrvUsd,
        uint256 keeperIndex,
        address targetOracle,
        address yieldOracle
    ) external;

    /// @notice Returns whether expansions are paused.
    function expansion_paused() external view returns (bool);
    /// @notice Returns whether moving target tokens into the final token is paused.
    function backing_deployment_paused() external view returns (bool);
    /// @notice Returns whether direct crvUSD buybacks are paused.
    function direct_buyback_paused() external view returns (bool);
    /// @notice Returns whether selling held target tokens is paused.
    function undeployed_contraction_paused() external view returns (bool);
    /// @notice Returns whether selling final tokens is paused.
    function yield_contraction_paused() external view returns (bool);
    /// @notice Returns whether all keeper actions are paused.
    function all_execution_paused() external view returns (bool);

    /// @notice Pauses or resumes one keeper action.
    function set_direction_paused(uint256 direction, bool paused) external;
    /// @notice Changes the main crvUSD swap pool and the largest allowed drop below its quote.
    function set_target_amm(address newTargetAmm, uint256 executionBufferBps) external;
    /// @notice Changes the price sources and the lowest accepted prices.
    function set_oracles(
        address targetOracle,
        address yieldOracle,
        uint256 minTargetPrice,
        uint256 minYieldPrice
    ) external;
    /// @notice Changes the allowed quote drop and gas limits used during expansion.
    function set_expansion_config(
        uint256 targetAmmExecutionBufferBps,
        uint256 minDownstreamAttemptGas,
        uint256 fallbackSettlementGasReserve
    ) external;

    /// @notice Changes profit, reward, timing, minimum trade, and crvUSD limits.
    function set_policy(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 earlyExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minDeploymentTime,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    ) external;

    /// @notice Replaces the token paths used after expansion and on the way back to crvUSD.
    function setPaths(
        RouteStep[] calldata expansionSteps,
        uint256 expansionMaxRouteLossBps,
        RouteStep[] calldata contractionSteps
    ) external;
    /// @notice Returns the number of steps in the post-expansion token path.
    function expansion_path_length() external view returns (uint256);
    /// @notice Returns the number of steps in the token path back to crvUSD.
    function contraction_path_length() external view returns (uint256);
    /// @notice Returns the largest allowed value loss across the post-expansion token path.
    function expansion_max_route_loss_bps() external view returns (uint256);
    /// @notice Returns one step from the post-expansion token path.
    function expansion_path_step(uint256 index) external view returns (RouteStep memory);
    /// @notice Returns one step from the token path back to crvUSD.
    function contraction_path_step(uint256 index) external view returns (RouteStep memory);
    /// @notice Returns the most crvUSD that can be used for an expansion now.
    function available_expansion() external view returns (uint256);
    /// @notice Estimates an expansion from current data; actual results may differ.
    function previewExpansion(uint256 crvUsdAmount)
        external
        view
        returns (
            uint256 expectedTargetOut,
            uint256 expectedBackingAssetOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward,
            uint256 expectedYieldToken,
            bool expectedToDeploy
        );
    /// @notice Uses crvUSD to buy backing and pays the caller a share of any profit.
    function expand(uint256 crvUsdAmount)
        external
        returns (
            uint256 crvUsdSold,
            uint256 backingRetained,
            uint256 yieldTokenReceived,
            uint256 keeperReward,
            bool deployedToYield
        );
    /// @notice Runs the post-expansion token path when the keeper calls itself and pays the original caller's reward.
    function executeExpansionPath(uint256 targetAmount, uint256 crvUsdSold, address keeper)
        external
        returns (
            uint256 backingAssetReceived,
            uint256 yieldTokenReceived,
            uint256 grossProfit,
            uint256 keeperReward
        );
    /// @notice Estimates the final tokens paid for a direct crvUSD buyback from current data; actual results may differ.
    function previewBuyback(uint256 crvUsdAmount)
        external
        view
        returns (uint256 expectedYieldTokenOut, uint256 requiredExitProfit, bool earlyExit);
    /// @notice Lets a caller pay crvUSD to buy final tokens from the keeper.
    function buyback(uint256 crvUsdAmount, uint256 minYieldTokenOut)
        external
        returns (uint256 yieldTokenOut);
    /// @notice Estimates selling held target tokens back to crvUSD from current data; actual results may differ.
    function previewUndeployedContraction(uint256 targetAmount)
        external
        view
        returns (
            uint256 expectedCrvUsdOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward,
            bool earlyExit
        );
    /// @notice Estimates selling final tokens back to crvUSD from current data; actual results may differ.
    function previewKeeperBuyback(uint256 yieldTokenAmount)
        external
        view
        returns (
            uint256 expectedCrvUsdOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward,
            bool earlyExit
        );
    /// @notice Swaps held target tokens back to crvUSD and pays the caller a share of any profit.
    function contractUndeployedBacking(uint256 targetAmount)
        external
        returns (uint256 targetSpent, uint256 crvUsdReceived, uint256 keeperReward);
    /// @notice Sells final tokens for crvUSD through the set token path and pays the caller a share of any profit.
    function contractViaAmm(uint256 yieldTokenAmount)
        external
        returns (uint256 yieldTokenSpent, uint256 crvUsdReceived, uint256 keeperReward);
    /// @notice Moves held target tokens through the set token path into the final token.
    function deployUndeployedBacking(uint256 targetAmount)
        external
        returns (uint256 targetSpent, uint256 yieldTokenReceived);
    /// @notice Moves final tokens back into target tokens without selling them for crvUSD.
    function unwindYieldToTarget(uint256 yieldTokenAmount)
        external
        returns (uint256 yieldTokenSpent, uint256 targetReceived);
    /// @notice Sends available crvUSD to the fee receiver when extra backing covers it, up to the caller's limit.
    function claimSurplus(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
    /// @notice Lets the admin call another address and returns any response.
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
