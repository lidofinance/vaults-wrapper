// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ExampleStrategy is IStrategy {
    IERC20 public immutable stvToken;
    IERC20 public immutable stETH;
    address public immutable aavePool;
    
    struct UserPosition {
        uint256 shares;
        uint256 borrowAmount;
        bool isExiting;
    }
    
    UserPosition public userPosition;
    
    constructor(address _stETH, address _aavePool) {
        stETH = IERC20(_stETH);
        aavePool = _aavePool;
    }
    
    function execute(address user, uint256 shares) external override {
        
        // 1. Рассчитываем сколько можно занять на основе shares
        uint256 borrowAmount = _calculateBorrowAmount(shares);
        
        // 2. Используем stETH как коллатерал в Aave
        stETH.approve(aavePool, shares);
        // aavePool.supply(address(stETH), shares, address(this), 0);
        
        // 3. Берем заем в ETH
        // aavePool.borrow(address(weth), borrowAmount, 2, 0, address(this));
        
        // 4. Конвертируем WETH в ETH
        // IWETH(weth).withdraw(borrowAmount);
        
        // 5. Кладим ETH в vault
        // vault.deposit{value: borrowAmount}();
        
        
        // Сохраняем позицию пользователя
        // todo делаем updatePosition
        userPosition = UserPosition({
            shares: shares,
            borrowAmount: borrowAmount,
            isExiting: false
        });
        
        emit StrategyExecuted(user, shares, borrowAmount);
    }

    function initiateExit(address user, uint256 assets) external {}
    
    function _calculateBorrowAmount(uint256 shares) internal view returns (uint256) {
        // Стратегия сама определяет сколько можно занять
        // Например, на основе LTV ratio и текущих цен
        return shares * 2; // Упрощенный пример: 2x leverage
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
        
        // Логика закрытия позиции в Aave
        // 1. Возвращаем заем
        // 2. Получаем обратно коллатерал
        // 3. Возвращаем shares пользователю
        
        assets = position.shares;
        delete userPosition;
        
        return assets;
    }
    
    event StrategyExecuted(address indexed user, uint256 shares, uint256 borrowAmount);
}