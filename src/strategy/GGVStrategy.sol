// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;


import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

contract GGVStrategy is Strategy {

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    event Execute(address indexed user, uint256 stETHAmount);
    event RequestWithdraw(address indexed user, uint256 shares);
    event Claim(address indexed user, address indexed asset, uint256 shares);
    
    error InvalidStETHAmount();
    error InvalidGGVShares();

    constructor (
        address _strategyProxyImplmentation,
        address _stETH, 
        address _teller, 
        address _boringQueue
    ) Strategy(_stETH, _strategyProxyImplmentation) {
        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);
    }

    function strategyId() public pure override returns (bytes32) {
        return keccak256("strategy.ggv.v1");
    }

    //negative steth rebase - how to finalize requests
    //requestid - if not exists - claim

    /// @notice Executes the strategy
    /// @param user The user to execute the strategy for
    /// @param stETHAmount The amount of stETH to execute the strategy for

    //stvToken
    function execute(address user, uint256 stETHAmount) external override {
        if (stETHAmount == 0) revert InvalidStETHAmount();

        address proxy = _getOrCreateProxy(user);

        STETH.transfer(proxy, stETHAmount);

        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stETHAmount)
        );
        IStrategyProxy(proxy).call(
            address(TELLER), 
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stETHAmount, 0)
        );

        emit Execute(msg.sender, stETHAmount);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param shares The number of ggv shares to withdraw
    function requestWithdraw(uint256 shares) external override {
        if (shares == 0) revert InvalidGGVShares();
        address proxy = _getOrCreateProxy(msg.sender);

        IERC20 boringVault = IERC20(TELLER.vault());

        IStrategyProxy(proxy).call(
            address(boringVault),
            abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), shares)
        );
         IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(BORING_QUEUE.requestOnChainWithdraw.selector, address(STETH), uint128(shares), 1, type(uint24).max)
        );

        emit RequestWithdraw(msg.sender, shares);
    }

    /// @notice Claims the specified asset from the strategy
    /// @param asset The asset to claim
    /// @param shares The number of shares to claim
    function claim(address asset, uint256 shares) external {
        address proxy = _getOrCreateProxy(msg.sender);

        IStrategyProxy(proxy).call(
            address(asset),
            abi.encodeWithSelector(IERC20(asset).transfer.selector, msg.sender, shares)
        );

        emit Claim(msg.sender, asset, shares);
    }

    /// @notice Initiates an exit from the strategy
    /// @param user The user to initiate the exit for
    /// @param assets The amount of assets to exit with
    function initiateExit(address user, uint256 assets) external override {
        // GGV strategy uses requestWithdraw mechanism
        // This could trigger the requestWithdraw flow for the specified assets
        revert("Not implemented - use requestWithdraw");
    }

    /// @notice Finalizes an exit from the strategy
    /// @param user The user to finalize the exit for
    /// @return assets The amount of assets returned
    function finalizeExit(address user) external override returns (uint256 assets) {
        // GGV strategy uses claim mechanism
        // This could trigger the claim flow and return the claimed amount
        revert("Not implemented - use claim");
    }

    /// @notice Returns borrow details for the strategy
    /// @return borrowAssets The amount of borrowed assets
    /// @return userAssets The amount of user assets
    /// @return totalAssets The total amount of assets
    function getBorrowDetails() external view override returns (uint256 borrowAssets, uint256 userAssets, uint256 totalAssets) {
        // GGV strategy doesn't involve borrowing in the traditional sense
        // Return zeros for now
        return (0, 0, 0);
    }

    /// @notice Returns whether the strategy is in an exiting state
    /// @return Whether the strategy is exiting
    function isExiting() external view override returns (bool) {
        // GGV strategy doesn't have a global exiting state
        return false;
    }
}
