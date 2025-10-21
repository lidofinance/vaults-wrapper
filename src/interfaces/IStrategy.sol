// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";

interface IStrategy {
    event StrategyExecuted(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, bytes data);

    /// @notice Supplies stETH to the strategy
    function supply(address _referral, bytes calldata _params) external payable; 

    /// @notice Requests a withdrawal from the Withdrawal Queue
    function requestWithdrawal(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToBurn,
        uint256 _stethSharesToRebalance,
        address _receiver
    ) external returns (uint256 requestId);

    /// @notice Recovers ERC20 tokens from the strategy
    function recoverERC20(address _token, address _recipient, uint256 _amount) external;
}