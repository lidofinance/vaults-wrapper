// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Wrapper} from "./Wrapper.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

error NoETHAvailableForLeverage();


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

contract ExampleStrategy is IStrategy {
    IERC20 public immutable STV_TOKEN;
    IERC20 public immutable STETH;
    Wrapper public immutable WRAPPER;
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
        WRAPPER = Wrapper(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        LOOPS = _loops;

        // Deploy LenderMock and store it in immutable
        LENDER_MOCK = new LenderMock(_stETH);
    }

    function execute(address _user, uint256 /* _stETHAmount */) external override {
        uint256 totalBorrowedEth = 0;
        uint256 totalUserStvTokenShares = 0;
        uint256 currentStETHAmount = 0;

        // Strategy uses its own ETH balance to start the leverage loop
        uint256 initialEthAmount = address(this).balance;
        if (initialEthAmount == 0) revert NoETHAvailableForLeverage();

        // Execute the looping strategy
        for (uint256 i = 0; i < LOOPS; i++) {
            // Use mintStETHForStrategy to deposit ETH and get stETH for leveraging
            (uint256 userShares, uint256 stETHReceived) = WRAPPER.mintStETHForStrategy{value: initialEthAmount}(_user);

            totalUserStvTokenShares += userShares;
            currentStETHAmount += stETHReceived;

            // Borrow ETH against the stETH collateral
            uint256 borrowedEth = _borrowFromPool(stETHReceived);
            totalBorrowedEth += borrowedEth;

            // Use borrowed ETH for next iteration
            initialEthAmount = borrowedEth;

            // Break if no more ETH to leverage
            if (borrowedEth == 0) break;
        }

        // Save user position with loop information
        userPositions[_user] = UserPosition({
            user: _user,
            shares: 0, // Strategy doesn't hold stvToken shares anymore
            borrowAmount: totalBorrowedEth,
            isExiting: false,
            totalStvTokenShares: totalUserStvTokenShares
        });

        emit StrategyExecutedWithLoops(_user, 0, totalUserStvTokenShares, totalBorrowedEth);
    }

    function _borrowFromPool(uint256 _stethCollateral) public returns (uint256 borrowedEth) {
        // Use LenderMock to borrow ETH against stETH collateral
        STETH.approve(address(LENDER_MOCK), _stethCollateral);

        uint256 ethBefore = address(this).balance;
        LENDER_MOCK.borrow(_stethCollateral);

        borrowedEth = address(this).balance - ethBefore;
    }

    receive() external payable {}
}
