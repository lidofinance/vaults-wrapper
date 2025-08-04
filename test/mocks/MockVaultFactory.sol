// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IVaultFactory} from "../../src/interfaces/IVaultFactory.sol";

import {MockDashboard} from "./MockDashboard.sol";
import {MockStakingVault} from "./MockStakingVault.sol";

contract MockVaultFactory is IVaultFactory {
    address public VAULT_HUB;

    constructor(address _vaultHub) {
        VAULT_HUB = _vaultHub;
    }

    function LIDO_LOCATOR() external pure returns (address) {
        return address(0);
    }

    function BEACON() external pure returns (address) {
        return address(0);
    }

    function DASHBOARD_IMPL() external pure returns (address) {
        return address(0);
    }

    function createVaultWithDashboard(
        address _admin,
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        IVaultFactory.RoleAssignment[] memory _roleAssignments
    ) external payable returns (address vault, address dashboard) {
        if (msg.value != 1 ether) {
            revert InsufficientFunds();
        }
        vault = address(new MockStakingVault());
        dashboard = address(new MockDashboard(VAULT_HUB, vault, _admin));
        return (vault, dashboard);
    }

    function createVaultWithDashboardWithoutConnectingToVaultHub(
        address _admin,
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        RoleAssignment[] calldata _roleAssignments
    ) external payable returns (address vault, address dashboard) {
        require(msg.value == 0 ether, "invalid value sent");
        vault = address(new MockStakingVault());
        dashboard = address(new MockDashboard(VAULT_HUB, vault, _admin));
        return (vault, dashboard);
    }
}
