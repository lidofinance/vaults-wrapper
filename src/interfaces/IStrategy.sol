// SPDX-License-Identifier: GPL-3.0
pragma solidity >= 0.5.0;

interface IStrategy {
    function strategyId() external view returns (bytes32);
    function execute(address user, uint256 stETHAmount) external;
    function requestWithdraw(uint256 shares) external;
    function claim(address asset, uint256 shares) external;
}