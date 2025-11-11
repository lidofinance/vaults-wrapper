// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IStrategy {
    event StrategySupplied(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, bytes data);
    event StrategyExitRequested(address indexed user, bytes32 requestId, uint256 stethSharesToBurn, bytes data);
    event StrategyExitFinalized(address indexed user, bytes32 requestId, uint256 stethShares);

    function POOL() external view returns (address);

    /// @notice Supplies wstETH to the strategy
    function supply(address _referral, uint256 _wstethToMint, bytes calldata _params) external payable;
    function previewSupply(address _user, bytes calldata _params) external view returns (uint256 stv, uint256 maxWstethToMint);

    /// @notice Requests a withdrawal from the strategy
    function requestExitByStethShares(uint256 stethSharesToBurn, bytes calldata params)
        external
        returns (bytes32 requestId);

    /// @notice Finalizes a withdrawal from the strategy
    function finalizeRequestExit(address receiver, bytes32 requestId) external;

    /// @notice Recovers ERC20 tokens from the strategy
    function recoverERC20(address _token, address _recipient, uint256 _amount) external;

    /// @notice Burns wstETH to reduce the user's minted stETH obligation
    function burnWsteth(uint256 _wstethToBurn) external;

    /// @notice Requests a withdrawal from the Withdrawal Queue
    function requestWithdrawalFromPool(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToRebalance,
        address _receiver
    ) external returns (uint256 requestId);
}
