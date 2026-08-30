// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ICurveEDAOAdminProxy {
    function execute(address target, bytes calldata data)
        external
        payable
        returns (bytes memory result);
}
