// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IStrategyExitInstantly {
    event ExitInstantly(address indexed user, bytes32 requestId, uint256 stethShares, bytes data);

    /// @notice Instantly exits by steth shares
    function instantlyExitByStethShares(uint256 stethSharesToBurn, bytes calldata params) external returns (bytes32 requestId);
}
