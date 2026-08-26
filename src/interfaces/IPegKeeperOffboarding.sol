// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IPegKeeperOffboarding {
    struct PegKeeperInfo {
        address pegKeeper;
        address pool;
        bool isInverse;
        bool includeIndex;
    }

    function version() external view returns (string memory);
    function fee_receiver() external view returns (address);
    function is_killed() external view returns (uint256);
    function admin() external view returns (address);
    function emergency_admin() external view returns (address);

    function provide_allowed() external view returns (uint256);
    function provide_allowed(address pegKeeper) external view returns (uint256);
    function withdraw_allowed() external view returns (uint256);
    function withdraw_allowed(address pegKeeper) external view returns (uint256);
    function peg_keepers(uint256 index) external view returns (PegKeeperInfo memory);

    function add_peg_keepers(address[] calldata pegKeepers) external;
    function remove_peg_keepers(address[] calldata pegKeepers) external;
    function set_fee_receiver(address feeReceiver) external;
    function set_killed(uint256 killed) external;
    function set_admin(address admin_) external;
    function set_emergency_admin(address emergencyAdmin) external;
}
