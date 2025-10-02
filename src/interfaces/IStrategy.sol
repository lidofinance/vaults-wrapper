// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";

interface IStrategy {
    function strategyId() external view returns (bytes32);
    function getStrategyProxyAddress(address user) external view returns (address proxy);
    
    function execute(address _user, uint256 _stvShares, uint256 _stethShares) external;
    function requestWithdrawByStETH(address _user, uint256 _stethAmount, bytes calldata params) external returns (bytes32 requestId);
    function finalizeWithdrawal(WithdrawalRequest memory request) external;
}
