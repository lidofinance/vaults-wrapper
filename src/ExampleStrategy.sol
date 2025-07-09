// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ExampleStrategy is IStrategy {
    IERC20 public immutable STV_TOKEN;
    IERC20 public immutable STETH;
    address public immutable AAVE_POOL;

    struct UserPosition {
        uint256 shares;
        uint256 borrowAmount;
        bool isExiting;
    }

    UserPosition public userPosition;

    constructor(address _stETH, address _aavePool) {
        STETH = IERC20(_stETH);
        AAVE_POOL = _aavePool;
    }

    function execute(address user, uint256 shares) external override {

        // 1. Calculate how much can be borrowed based on shares
        uint256 borrowAmount = _calculateBorrowAmount(shares);

        // 2. Use stETH as collateral in Aave
        STETH.approve(AAVE_POOL, shares);
        // aavePool.supply(address(stETH), shares, address(this), 0);

        // 3. Borrow ETH
        // aavePool.borrow(address(weth), borrowAmount, 2, 0, address(this));

        // 4. Convert WETH to ETH
        // IWETH(weth).withdraw(borrowAmount);

        // 5. Put ETH in vault
        // vault.deposit{value: borrowAmount}();


        // Save user position
        // todo implement updatePosition
        userPosition = UserPosition({
            shares: shares,
            borrowAmount: borrowAmount,
            isExiting: false
        });

        emit StrategyExecuted(user, shares, borrowAmount);
    }

    function initiateExit(address user, uint256 assets) external {}

    function _calculateBorrowAmount(uint256 shares) internal view returns (uint256) {
        // Strategy determines how much can be borrowed
        // For example, based on LTV ratio and current prices
        return shares * 2; // Simplified example: 2x leverage
    }

    function getBorrowDetails() external view override returns (
        uint256 borrowAssets,
        uint256 userAssets,
        uint256 totalAssets
    ) {
        return (userPosition.borrowAmount, 0, 0);
    }

    function isExiting() external view override returns (bool) {
        return userPosition.isExiting;
    }

    function finalizeExit(address user) external override returns (uint256 assets) {
        UserPosition storage position = userPosition;
        require(position.isExiting, "Not exiting");

        // Logic for closing position in Aave
        // 1. Repay the loan
        // 2. Get back the collateral
        // 3. Return shares to the user

        assets = position.shares;
        delete userPosition;

        return assets;
    }

    event StrategyExecuted(address indexed user, uint256 shares, uint256 borrowAmount);
}