// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegKeeperV2 {
    function factory() external view returns (address);
    function pegged() external view returns (address);
    function pool() external view returns (address);
    function IS_INVERSE() external view returns (bool);
    function IS_NG() external view returns (bool);
    function regulator() external view returns (address);
    function last_change() external view returns (uint256);
    function debt() external view returns (uint256);
    function caller_share() external view returns (uint256);
    function action_delay() external view returns (uint256);
    function admin() external view returns (address);
    function calc_profit() external view returns (uint256);
    function estimate_caller_profit() external view returns (uint256);
    function update(address beneficiary) external returns (uint256);
    function withdraw_profit() external returns (uint256);
    function set_new_regulator(address regulator_) external;
}
