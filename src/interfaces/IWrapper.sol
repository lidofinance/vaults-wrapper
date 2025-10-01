// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IDashboard} from "./IDashboard.sol";
import {IVaultHub} from "./IVaultHub.sol";

interface IWrapper {
    function STETH() external view returns (address);
    function DASHBOARD() external view returns (IDashboard);
    function VAULT_HUB() external view returns (IVaultHub);
    function STAKING_VAULT() external view returns (address);
    function previewWithdraw(uint256 _assets) external view returns (uint256);
    function previewRedeem(uint256 _stv) external view returns (uint256);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function totalEffectiveAssets() external view returns (uint256);
    function burnStvForWithdrawalQueue(uint256 _stv) external;
    function totalExceedingMintedSteth() external view returns (uint256);
    function rebalanceMintedStethShares(uint256, uint256) external;
}
