// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {IVaultHub} from "./IVaultHub.sol";

interface IDashboard {
    function vaultHub() external view returns (IVaultHub);
    function stakingVault() external view returns (address);
    function fund() external payable;
    function withdraw(address recipient, uint256 _ether) external;
    function withdrawableValue() external view returns (uint256);
}