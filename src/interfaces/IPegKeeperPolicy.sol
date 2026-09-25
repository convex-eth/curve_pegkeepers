// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Replaceable global execution policy shared by standalone PegKeeperV3 contracts.
interface IPegKeeperPolicy {
    error InvalidAdmin();
    error InvalidOracle();
    error InvalidFeeReceiver();

    event AggregateCrvUsdOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event FeeReceiverUpdated(address indexed oldFeeReceiver, address indexed newFeeReceiver);
    event CommitNewAdmin(address admin);
    event ApplyNewAdmin(address admin);

    function admin() external view returns (address);
    function future_admin() external view returns (address);
    function new_admin_deadline() external view returns (uint256);
    function aggregateCrvUsdOracle() external view returns (address);
    function fee_receiver() external view returns (address);

    function expansion_regime() external view returns (bool);
    function can_expand() external view returns (bool);
    function can_contract() external view returns (bool);

    function set_aggregate_crvusd_oracle(address newOracle) external;
    function set_fee_receiver(address newFeeReceiver) external;
    function commit_new_admin(address newAdmin) external;
    function apply_new_admin() external;
}
