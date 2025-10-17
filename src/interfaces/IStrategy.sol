// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";

interface IStrategy {
    event StrategyExecuted(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, bytes data);
    event WithdrawalRequested(address indexed user, bytes32 requestId, uint256 stethShares, bytes data);
    event WithdrawalFinalized(address indexed user, bytes32 requestId, uint256 stethShares);

    function getStrategyProxyAddress(address user) external view returns (address proxy);

    function execute(address _user, uint256 _stv, uint256 _stethShares, bytes calldata _params) external;
    function requestExitByStETH(address _user, uint256 _stethAmount, bytes calldata params) external returns (bytes32 requestId);
    function requestExitByStethShares(address _user, uint256 _stethSharesToBurn, bytes calldata params) external returns (bytes32 requestId);
    function finalizeExit(address _user, address _receiver, bytes32 _requestId) external;


}
