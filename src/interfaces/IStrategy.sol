// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface IStrategy {
    function execute(address _user, uint256 _stvShares, uint256 _stethShares) external;

    function strategyId() external view returns (bytes32);
    function requestWithdrawByStETH(address _user, uint256 _ethAmount) external returns (uint256 requestId);
    function finalizeWithdrawal(address _receiver, uint256 stETHAmount) external;

    function getStrategyProxyAddress(address user) external  view returns (address proxy);
}