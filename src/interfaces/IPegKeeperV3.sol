// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Public ABI for a direct-liquidity, LP-backed PegKeeperV3.
interface IPegKeeperV3 {
    event DirectionPaused(uint256 indexed direction, bool paused);
    event Executed(
        address indexed target, uint256 value, bytes4 indexed selector, bytes32 dataHash
    );
    event AmmExecutionBufferUpdated(uint256 executionBufferBps);
    event Expanded(
        address indexed keeper,
        uint256 crvUsdDeployed,
        uint256 lpTokensReceived,
        uint256 grossProfit,
        uint256 keeperReward
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
    event CrvUsdBorrowed(
        address indexed caller,
        address indexed receiver,
        uint256 amount,
        uint256 deployedCrvUsdAfter
    );
    event PolicyUpdated(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    );
    event InterventionPolicyUpdated(uint256 maxInterventionShareBps, uint256 minInterventionDelay);
    event YieldOraclePolicyUpdated(address indexed yieldOracle, uint256 minYieldPrice);

    function version() external view returns (string memory);
    function name() external view returns (string memory);
    function keeper_index() external view returns (uint256);
    function initialized() external view returns (bool);

    function factory() external view returns (address);
    function controller_factory() external view returns (address);
    function crv_usd() external view returns (address);
    function backing_asset() external view returns (address);
    function yield_token() external view returns (address);
    function yield_amm() external view returns (address);
    function yield_token_is_erc4626() external view returns (bool);
    function yield_token_assets(uint256 units) external view returns (uint256);
    function yield_token_units(uint256 assets) external view returns (uint256);
    function yield_oracle() external view returns (address);
    function min_yield_oracle_price() external view returns (uint256);
    function max_expansion_burst_bps() external view returns (uint256);
    function expansion_refill_period() external view returns (uint256);
    function fee_receiver() external view returns (address);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);
    function yield_amm_crvusd_index() external view returns (uint256);
    function yield_amm_yield_token_index() external view returns (uint256);

    /// @notice Returns crvUSD at index 0 and the held AMM LP token at index 1.
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
    function max_intervention_share_bps() external view returns (uint256);
    function min_intervention_delay() external view returns (uint256);
    function last_intervention_at() external view returns (uint256);
    function yield_amm_execution_buffer_bps() external view returns (uint256);

    function debt() external view returns (uint256);
    function deployed_crvusd() external view returns (uint256);
    function expansion_pressure() external view returns (uint256);
    function last_expansion_pressure_update() external view returns (uint256);
    function available_expansion_velocity() external view returns (uint256);

    function initialize(
        address backingAsset,
        address yieldToken,
        address yieldAmm,
        uint256 maxDeployedCrvUsd,
        uint256 keeperIndex,
        address yieldOracle
    ) external;

    function expansion_paused() external view returns (bool);
    function yield_contraction_paused() external view returns (bool);
    function all_execution_paused() external view returns (bool);
    function set_direction_paused(uint256 direction, bool paused) external;
    function set_yield_oracle_policy(address yieldOracle, uint256 minYieldPrice) external;
    function set_amm_execution_buffer(uint256 executionBufferBps) external;
    function set_policy(
        uint256 entryMinProfitPpm,
        uint256 normalExitMinProfitPpm,
        uint256 keeperProfitShareBps,
        uint256 minExpansionAmount,
        uint256 maxDeployedCrvUsd
    ) external;
    function set_intervention_policy(uint256 maxInterventionShareBps, uint256 minInterventionDelay)
        external;

    /// @notice Local viability probe used by PegKeeperPolicy; does not call policy itself.
    function can_expand_without_policy() external view returns (bool);
    function available_expansion() external view returns (uint256);

    function previewExpansion(uint256 crvUsdAmount)
        external
        view
        returns (
            uint256 crvUsdDeployed,
            uint256 expectedGrossProfit,
            uint256 expectedKeeperRewardLp,
            uint256 expectedLpTokensOut
        );
    function expand(uint256 crvUsdAmount)
        external
        returns (uint256 crvUsdDeployed, uint256 lpTokensReceived, uint256 keeperRewardLp);

    /// @notice Deposits donated paired tokens and matches only policy-approved crvUSD.
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
    /// @notice Burns LP tokens and removes only crvUSD from the fixed AMM.
    function contractViaAmm(uint256 lpTokenAmount)
        external
        returns (uint256 lpTokensBurned, uint256 crvUsdReceived, uint256 keeperReward);

    function claimSurplus(uint256 maxCrvUsdAmount) external returns (uint256 crvUsdTransferred);
    /// @notice Gives Factory-admin-approved crvUSD to a receiver and records it as keeper debt.
    function borrow_crvusd(uint256 amount, address receiver) external;
    function reduce_deployed_crvusd(uint256 amount) external;
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
