// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {IDashboard} from "./IDashboard.sol";

interface IVaultFactory {
    struct RoleAssignment {
        address account;
        bytes32 role;
    }

    function createVaultWithDashboard(
        address _defaultAdmin,
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        RoleAssignment[] calldata _roleAssignments
    ) external payable returns (address vault, IDashboard dashboard);
}
