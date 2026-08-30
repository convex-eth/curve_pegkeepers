// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IAggMonetaryPolicy {
    function admin() external view returns (address);
    function CONTROLLER_FACTORY() external view returns (address);
    function peg_keepers(uint256 index) external view returns (address);

    function add_peg_keeper(address pegKeeper) external;
}
