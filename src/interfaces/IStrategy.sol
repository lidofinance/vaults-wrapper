// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface IStrategy {
    function initialize(address wrapper) external;
    function execute(address _user, uint256 _stvShares) external;

    function strategyId() external view returns (bytes32);
    function requestWithdrawByETH(address _user, uint256 _ethAmount) external returns (uint256 requestId);
    function finalizeWithdrawal(address _receiver, uint256 stETHAmount) external;
    function getWithdrawableAmount(address _address) external view returns (uint256);
}