// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IControllerFactory {
    function admin() external view returns (address);
    function stablecoin() external view returns (address);
    function fee_receiver() external view returns (address);
    function debt_ceiling(address account) external view returns (uint256);
    function debt_ceiling_residual(address account) external view returns (uint256);
    function set_debt_ceiling(address account, uint256 ceiling) external;
    function rug_debt_ceiling(address account) external;
}
