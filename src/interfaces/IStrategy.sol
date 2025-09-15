// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface IStrategy {
    function initialize(address wrapper) external;
    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external;

    function strategyId() external view returns (bytes32);
    function requestWithdraw(address _user, uint256 _stvShares) external returns (uint256 requestId);
    function finalizeWithdrawal(uint256 shares) external returns(uint256 stvToken);
    function finalizeWithdrawal(address _receiver, uint256 stETHAmount) external returns(uint256 stvToken);
}