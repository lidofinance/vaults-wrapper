// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface IStrategy {
    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external;

    // TODO: remove after all strategies support the new execute interface
    function execute(address user, uint256 stETHAmount) external;

    function strategyId() external view returns (bytes32);
    function requestWithdraw(uint256 shares) external;
    function claim(address asset, uint256 shares) external;
}