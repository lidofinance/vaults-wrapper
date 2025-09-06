// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface IStrategy {
    function execute(address _user, uint256 _stvShares) external;

    function strategyId() external view returns (bytes32);
    function requestWithdraw(uint256 shares) external;
    function claim(address asset, uint256 shares) external;
}