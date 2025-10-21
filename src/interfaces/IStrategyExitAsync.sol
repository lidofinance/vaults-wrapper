// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IStrategyExitAsync {
    event ExitRequested(address indexed user, bytes32 requestId, uint256 stethShares, bytes data);
    event ExitFinalized(address indexed user, bytes32 requestId, uint256 stethShares);

    /// @notice Requests a withdrawal from the strategy
    function requestExitByStethShares(uint256 stethSharesToBurn, bytes calldata params) external returns (bytes32 requestId);

    /// @notice Finalizes a withdrawal from the strategy
    function finalizeRequestExit(address receiver, bytes32 requestId) external;
}