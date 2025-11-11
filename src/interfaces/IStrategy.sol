// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

interface IStrategy {
    event StrategySupplied(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, bytes data);
    event StrategyExitRequested(address indexed user, bytes32 requestId, uint256 stethSharesToBurn, bytes data);
    event StrategyExitFinalized(address indexed user, bytes32 requestId, uint256 stethShares);

    function initialize(address _admin) external;

    function POOL() external view returns (address);

    /// @notice Supplies wstETH to the strategy
    function supply(address _referral, uint256 _wstethToMint, bytes calldata _params) external payable;
    //    function previewSupply(address _user, bytes calldata _params) external view returns (uint256 stv, uint256 maxWstethToMint);

    /// @notice Requests a withdrawal from the strategy
    function requestExitByStethShares(uint256 stethSharesToBurn, bytes calldata params)
        external
        returns (bytes32 requestId);

    /// @notice Finalizes a withdrawal from the strategy
    function finalizeRequestExit(address receiver, bytes32 requestId) external;

    /// @notice Burns wstETH to reduce the user's minted stETH obligation
    function burnWsteth(uint256 _wstethToBurn) external;

    /// @notice Requests a withdrawal from the Withdrawal Queue
    function requestWithdrawalFromPool(uint256 _stvToWithdraw, uint256 _stethSharesToRebalance, address _receiver)
        external
        returns (uint256 requestId);

    /**
     * @notice Returns the amount of wstETH of a user
     * @param _user The user to get the wstETH for
     * @return wsteth The amount of wstETH
     */
    function wstethOf(address _user) external view returns (uint256);

    /**
     * @notice Returns the amount of stv of a user
     * @param _user The user to get the stv for
     * @return stv The amount of stv
     */
    function stvOf(address _user) external view returns (uint256);

    /**
     * @notice Returns the amount of minted stETH shares of a user
     * @param _user The user to get the minted stETH shares for
     * @return mintedStethShares The amount of minted stETH shares
     */
    function mintedStethSharesOf(address _user) external view returns (uint256 mintedStethShares);
}
