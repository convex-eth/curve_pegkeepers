// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegKeeperV3 {
    event DirectionPaused(uint256 indexed direction, bool paused);
    event Executed(
        address indexed target, uint256 value, bytes4 indexed selector, bytes32 dataHash
    );

    function version() external view returns (string memory);

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
    function execute(address target, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
