// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Public ABI for an LP-backed PegKeeperV3.
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
        uint256 targetAmmExecutionBufferBps, uint256 yieldAmmExecutionBufferBps
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
        uint256 crvUsdMatched,
        uint256 lpTokensReceived,
        uint256 grossProfit,
        uint256 keeperReward,
        bool directDeposit
    );
    event DonatedYieldSwept(
        address indexed keeper,
        uint256 yieldTokenSwept,
        uint256 crvUsdMatched,
        uint256 lpTokensReceived,
        uint256 grossProfit,
        uint256 keeperReward
    );
    event Contracted(
        address indexed keeper,
        uint256 lpTokensBurned,
        uint256 crvUsdReceived,
        uint256 grossProfit,
        uint256 keeperReward
    );
    event SurplusClaimed(
        address indexed caller,
        address indexed receiver,
        uint256 crvUsdTransferred,
        uint256 deployedCrvUsdAfter
    );
    event DebtReduced(
        address indexed caller,
        uint256 requestedReduction,
        uint256 actualReduction,
        uint256 deployedCrvUsdAfter
    );
    event PolicyUpdated(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    );
    event PathsUpdated(bytes32 indexed expansionPathHash, uint256 expansionMaxRouteLossBps);
    event OraclePolicyUpdated(
        address indexed targetOracle,
        address indexed yieldOracle,
        uint256 minTargetPrice,
        uint256 minYieldPrice
    );

    function version() external view returns (string memory);
    function name() external view returns (string memory);
    function keeper_index() external view returns (uint256);
    function MAX_ROUTE_STEPS() external view returns (uint256);
    function initialized() external view returns (bool);
    function preview_module() external view returns (address);

    function factory() external view returns (address);
    function controller_factory() external view returns (address);
    function crv_usd() external view returns (address);
    function target_amm() external view returns (address);
    function target_asset() external view returns (address);
    function backing_asset() external view returns (address);
    function yield_token() external view returns (address);
    function yield_amm() external view returns (address);
    function yield_token_is_erc4626() external view returns (bool);
    function yield_token_assets(uint256 units) external view returns (uint256);
    function yield_token_units(uint256 assets) external view returns (uint256);
    function target_oracle() external view returns (address);
    function yield_oracle() external view returns (address);
    function min_target_oracle_price() external view returns (uint256);
    function min_yield_oracle_price() external view returns (uint256);
    function max_expansion_burst_bps() external view returns (uint256);
    function expansion_refill_period() external view returns (uint256);
    function fee_receiver() external view returns (address);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function target_amm_crvusd_index() external view returns (uint256);
    function target_amm_target_index() external view returns (uint256);
    function yield_amm_crvusd_index() external view returns (uint256);
    function yield_amm_yield_token_index() external view returns (uint256);

    /// @notice Returns crvUSD at index 0 and the held yield-AMM LP token at index 1.
    function coins(uint256 index) external view returns (address);
    /// @notice Returns floor(LP balance * current virtual price / 1e18).
    function trusted_backing_value() external view returns (uint256);
    function protocol_surplus() external view returns (uint256);
    function accounted_lp_tokens() external view returns (uint256);

    function entry_min_profit_ppm() external view returns (uint256);
    function normal_exit_min_profit_ppm() external view returns (uint256);
    function keeper_profit_share_bps() external view returns (uint256);
    function min_expansion_amount() external view returns (uint256);
    function max_deployed_crvusd() external view returns (uint256);
    function target_amm_execution_buffer_bps() external view returns (uint256);
    function yield_amm_execution_buffer_bps() external view returns (uint256);

    function debt() external view returns (uint256);
    function deployed_crvusd() external view returns (uint256);
    function expansion_pressure() external view returns (uint256);
    function last_expansion_pressure_update() external view returns (uint256);
    function available_expansion_velocity() external view returns (uint256);

    function initialize(
        address targetAmm,
        address targetAsset,
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployedCrvUsd,
        uint256 keeperIndex,
        address targetOracle,
        address yieldOracle
    ) external;

    function expansion_paused() external view returns (bool);
    function yield_contraction_paused() external view returns (bool);
    function all_execution_paused() external view returns (bool);
    function set_direction_paused(uint256 direction, bool paused) external;
    function set_target_amm(address newTargetAmm, uint256 executionBufferBps) external;
    function set_oracles(
        address targetOracle,
        address yieldOracle,
        uint256 minTargetPrice,
        uint256 minYieldPrice
    ) external;
    function set_expansion_config(
        uint256 targetAmmExecutionBufferBps,
        uint256 yieldAmmExecutionBufferBps
    ) external;
    function set_policy(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    ) external;

    function setPaths(RouteStep[] calldata expansionSteps, uint256 expansionMaxRouteLossBps)
        external;
    function expansion_path_length() external view returns (uint256);
    function expansion_max_route_loss_bps() external view returns (uint256);
    function expansion_path_step(uint256 index) external view returns (RouteStep memory);
    function available_expansion() external view returns (uint256);

    function previewExpansion(uint256 crvUsdAmount)
        external
        view
        returns (
            uint256 expectedTargetOut,
            uint256 expectedCrvUsdMatched,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperRewardLp,
            uint256 expectedLpTokensOut,
            bool directDeposit
        );
    function expand(uint256 crvUsdAmount)
        external
        returns (
            uint256 crvUsdSold,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,
            uint256 keeperRewardLp,
            bool directDeposit
        );
    /// @notice Deposits donated yield and matches crvUSD according to aggregate direction and pool balance.
    function sweepDonatedYield(uint256 maxYieldTokenAmount)
        external
        returns (
            uint256 yieldTokenSwept,
            uint256 crvUsdMatched,
            uint256 lpTokensReceived,
            uint256 keeperRewardLp
        );

    /// @notice Estimates a fixed one-coin LP withdrawal into crvUSD.
    function previewKeeperBuyback(uint256 lpTokenAmount)
        external
        view
        returns (
            uint256 expectedCrvUsdOut,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperReward
        );
    /// @notice Burns LP tokens and removes only crvUSD from the fixed yield AMM.
    function contractViaAmm(uint256 lpTokenAmount)
        external
        returns (uint256 lpTokensBurned, uint256 crvUsdReceived, uint256 keeperReward);

    function claimSurplus(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
    function reduce_deployed_crvusd(uint256 amount) external;
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
