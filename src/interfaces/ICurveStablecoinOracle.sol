// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ICurveStablecoinOracle {
    function pool() external view returns (address);
    function asset() external view returns (address);
    function reference_asset() external view returns (address);
    function inverted() external view returns (bool);
    function price() external view returns (uint256);
}
