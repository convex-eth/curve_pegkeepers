// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDaiUsds {
    function dai() external view returns (address);
    function usds() external view returns (address);
    function daiToUsds(address receiver, uint256 amount) external;
    function usdsToDai(address receiver, uint256 amount) external;
}
