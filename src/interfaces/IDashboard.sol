// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {IVaultHub} from "./IVaultHub.sol";

interface IDashboard is IAccessControlEnumerable {
    // Constants
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32);

    function NODE_OPERATOR_MANAGER_ROLE() external view returns (bytes32);

    // Functions
    function vaultHub() external view returns (IVaultHub);

    function stakingVault() external view returns (address);

    function fund() external payable;

    function withdraw(address recipient, uint256 _ether) external;

    function withdrawableValue() external view returns (uint256);

    // Admin only Management functions
    function setConfirmExpiry(
        uint256 _newConfirmExpiry
    ) external returns (bool);

    function setNodeOperatorFeeRate(
        uint256 _newNodeOperatorFeeRate
    ) external returns (bool);
}
