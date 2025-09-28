// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IDashboard} from "./IDashboard.sol";

interface IWrapper {
    function maxWithdraw(address _owner) external view returns (uint256);
    function previewWithdraw(uint256 _assets) external view returns (uint256);
    function previewRedeem(uint256 _assets) external view returns (uint256);
    function burnShares(uint256 _shares) external;
    function DASHBOARD() external view returns (IDashboard);
    function STAKING_VAULT() external view returns (address);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function burnSharesForWithdrawalQueue(uint256 _shares) external;
}
