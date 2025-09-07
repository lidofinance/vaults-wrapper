// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStETH} from "../interfaces/IStETH.sol";
import {WrapperB} from "../WrapperB.sol";
import {IVaultHub} from "../interfaces/IVaultHub.sol";
import {IDashboard} from "../interfaces/IDashboard.sol";
import {LenderMock} from 'src/mock/LenderMock.sol';

error NoStETHAvailableForLeverage();


contract ExampleLoopStrategy is IStrategy {
    IERC20 public immutable STV_TOKEN;
    IStETH public immutable STETH;
    WrapperB public immutable WRAPPER;
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
        STETH = IStETH(_stETH);
        WRAPPER = WrapperB(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        LOOPS = _loops;

        // Deploy LenderMock and store it in immutable
        LENDER_MOCK = new LenderMock(_stETH);
    }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("ExampleStrategy");
    }

    function execute(address _user, uint256 _stvShares) external override {
        uint256 totalBorrowedEth = 0;
        uint256 totalUserStvTokenShares = 0;
        uint256 _stETHAmount = 0;
        // uint256 stShares = WRAPPER.mintStShares(_stvShares);
        uint256 stShares = WRAPPER.mintableStShares(_user);
        WRAPPER.mintStShares(stShares);
        uint256 currentStETHAmount = STETH.getPooledEthByShares(stShares);

        // Strategy uses the stETH minted to it to start the leverage loop
        if (stShares == 0) revert NoStETHAvailableForLeverage();

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

    receive() external payable {}

    function requestWithdraw(uint256 shares) external {}

    function claim(address asset, uint256 shares) external {}
}
