// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

error NoStETHAvailableForLeverage();


contract LenderMock {
    address public immutable STETH;
    uint256 public constant TOTAL_BASIS_POINTS = 10000;
    uint256 public constant BORROW_RATIO = 7500; // 0.75 in basis points

    constructor(address _steth) {
        STETH = _steth;
    }

    /// @notice Borrow ETH against stETH collateral
    /// @param _amount Amount of stETH to transfer in
    function borrow(uint256 _amount) external {
        uint256 ethAmount = (_amount * BORROW_RATIO) / TOTAL_BASIS_POINTS;
        require(address(this).balance >= ethAmount, "Insufficient ETH in contract");

        require(IERC20(STETH).transferFrom(msg.sender, address(this), _amount), "stETH transfer failed");

        (bool sent, ) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");
    }

    receive() external payable {}
}

contract ExampleLoopStrategy is IStrategy {
    IERC20 public immutable STV_TOKEN;
    IERC20 public immutable STETH;
    WrapperBase public immutable WRAPPER;
    LenderMock public immutable LENDER_MOCK;

    struct UserPosition {
        address user;
        uint256 shares;
        uint256 borrowAmount;
        bool isExiting;
        uint256 totalStvTokenShares;
    }

    mapping(address => UserPosition) public userPositions;

    // Configuration constants (these would be set by governance in production)
    uint256 public constant POOL_RR = 60_00;  // 60% = 0.6
    uint256 public constant PRECISION = 100;
    uint256 public immutable LOOPS;

    event StrategyExecuted(address indexed user, uint256 shares, uint256 borrowAmount);
    event StrategyExecutedWithLoops(address indexed user, uint256 initialShares, uint256 totalShares, uint256 totalBorrowed);

    constructor(address _stETH, address _wrapper, uint256 _loops) {
        STETH = IERC20(_stETH);
        WRAPPER = WrapperBase(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        LOOPS = _loops;

        // Deploy LenderMock and store it in immutable
        LENDER_MOCK = new LenderMock(_stETH);
    }

    function execute(address _user, uint256 _stETHAmount) external override {
        uint256 totalBorrowedEth = 0;
        uint256 totalUserStvTokenShares = 0;
        uint256 currentStETHAmount = _stETHAmount;

        // Strategy uses the stETH minted to it to start the leverage loop
        if (currentStETHAmount == 0) revert NoStETHAvailableForLeverage();

        // Execute the looping strategy
        for (uint256 i = 0; i < LOOPS; i++) {
            // Borrow ETH against the current stETH collateral
            uint256 borrowedEth = _borrowFromPool(currentStETHAmount);
            totalBorrowedEth += borrowedEth;

            // Break if no more ETH borrowed
            if (borrowedEth == 0) break;

            // Use borrowed ETH to get more stvToken shares and stETH for next loop
            // TODO: Update this to work with new wrapper architecture
            // (uint256 userShares, uint256 stETHReceived) = WRAPPER.mintStETHForStrategy{value: borrowedEth}(_user);

            // totalUserStvTokenShares += userShares;
            // currentStETHAmount = stETHReceived;

            // For now, break the loop to avoid compilation errors
            // break;

            // Break if no more stETH received
            if (currentStETHAmount == 0) break;
        }

        // Save user position with loop information
        userPositions[_user] = UserPosition({
            user: _user,
            shares: 0, // Strategy doesn't hold stvToken shares anymore
            borrowAmount: totalBorrowedEth,
            isExiting: false,
            totalStvTokenShares: totalUserStvTokenShares
        });

        emit StrategyExecutedWithLoops(_user, _stETHAmount, totalUserStvTokenShares, totalBorrowedEth);
    }

    function _borrowFromPool(uint256 _stethCollateral) internal returns (uint256 borrowedEth) {
        // Use LenderMock to borrow ETH against stETH collateral
        STETH.approve(address(LENDER_MOCK), _stethCollateral);

        uint256 ethBefore = address(this).balance;
        LENDER_MOCK.borrow(_stethCollateral);

        borrowedEth = address(this).balance - ethBefore;
    }

    // Additional required interface methods
    function initiateExit(address user, uint256 assets) external override {
        UserPosition storage position = userPositions[user];
        position.isExiting = true;
    }

    function finalizeExit(address user) external override returns (uint256 assets) {
        UserPosition storage position = userPositions[user];
        assets = position.borrowAmount;
        delete userPositions[user];
    }

    function getBorrowDetails() external view override returns (uint256 borrowAssets, uint256 userAssets, uint256 totalAssets) {
        borrowAssets = address(this).balance;
        userAssets = 0;
        totalAssets = borrowAssets;
    }

    function isExiting() external pure override returns (bool) {
        return false;
    }

    receive() external payable {}
}
