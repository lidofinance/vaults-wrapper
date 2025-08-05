// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Wrapper} from "./Wrapper.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";


contract LenderMock {
    address public immutable STETH;
    uint256 public constant TOTAL_BASIS_POINTS = 10000;
    uint256 public constant BORROW_RATIO = 7500; // 0.75 in basis points

    constructor(address _steth) {
        STETH = _steth;
    }

    /// @notice Borrow ETH against stETH collateral
    /// @param amount Amount of stETH to transfer in
    function borrow(uint256 amount) external {
        uint256 ethAmount = (amount * BORROW_RATIO) / TOTAL_BASIS_POINTS;
        require(address(this).balance >= ethAmount, "Insufficient ETH in contract");

        require(IERC20(STETH).transferFrom(msg.sender, address(this), amount), "stETH transfer failed");

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
    event DebugLoop(uint256 loop, uint256 currentStvTokenShares, uint256 borrowedEth, uint256 newStvTokenShares);

    constructor(address _stETH, address _wrapper, uint256 _loops) {
        STETH = IERC20(_stETH);
        WRAPPER = Wrapper(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        LOOPS = _loops;

        // Deploy LenderMock and store it in immutable
        LENDER_MOCK = new LenderMock(_stETH);
    }

    function execute(address user, uint256 stvTokenShares) external override {
        uint256 currentStvTokenShares = stvTokenShares;
        uint256 totalBorrowedEth = 0;
        uint256 totalStvTokenShares = 0;

        // Tokens should already be transferred to this contract by the caller

        // Execute the looping strategy
        for (uint256 i = 0; i < LOOPS; i++) {
            emit DebugLoop(i, currentStvTokenShares, 0, 0);

            uint256 mintedSteth = _mintStETH(currentStvTokenShares);

            uint256 borrowedEth = _borrowFromPool(mintedSteth);

            totalBorrowedEth += borrowedEth;

            uint256 newStvTokenShares = WRAPPER.depositETH{value: borrowedEth}(address(this));
            totalStvTokenShares += newStvTokenShares;

            emit DebugLoop(i, currentStvTokenShares, borrowedEth, newStvTokenShares);

            currentStvTokenShares = newStvTokenShares;
        }

        // Save user position with loop information
        userPositions[user] = UserPosition({
            user: user,
            shares: stvTokenShares, // TODO: increase but set
            borrowAmount: totalBorrowedEth,
            isExiting: false,
            totalStvTokenShares: totalStvTokenShares
        });

        emit StrategyExecutedWithLoops(user, stvTokenShares, userPositions[user].totalStvTokenShares, totalBorrowedEth);
    }

    function initiateExit(address user, uint256 assets) external override {
        UserPosition storage position = userPositions[user];
        require(position.user == user, "Position not found");
        position.isExiting = true;

        assets = assets; // TODO
    }

    function _mintStETH(uint256 stvShares) internal returns (uint256 mintedStethShares) {
        STV_TOKEN.approve(address(WRAPPER), stvShares);
        mintedStethShares = WRAPPER.mintStETH(stvShares);
    }

    function _borrowFromPool(uint256 _stethCollateral) public returns (uint256 borrowedEth) {
        // Use LenderMock to borrow ETH against stETH collateral
        STETH.approve(address(LENDER_MOCK), _stethCollateral);

        uint256 ethBefore = address(this).balance;
        LENDER_MOCK.borrow(_stethCollateral);

        borrowedEth = address(this).balance - ethBefore;
    }

    /**
     * @notice Return borrowed ETH to the Wrapper for vault funding
     * @dev This function is called by the Wrapper during the looping process
     * @param amount Amount of ETH to return
     */
    function returnBorrowedETH(uint256 amount) external {
        require(msg.sender == address(WRAPPER), "Only wrapper can call");
        require(amount <= address(this).balance, "Insufficient ETH balance");

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function getBorrowDetails() external view override returns (
        uint256 borrowAssets,
        uint256 userAssets,
        uint256 totalAssets
    ) {
        UserPosition storage position = userPositions[msg.sender];
        return (position.borrowAmount, position.totalStvTokenShares, position.totalStvTokenShares + position.borrowAmount);
    }

    function isExiting() external view override returns (bool) {
        UserPosition storage position = userPositions[msg.sender];
        return position.isExiting;
    }

    function finalizeExit(address user) external override returns (uint256 assets) {
        UserPosition storage position = userPositions[user];
        require(position.isExiting, "Not exiting");

        // Logic for closing position in Aave
        // 1. Repay the loan
        // 2. Get back the collateral
        // 3. Return shares to the user

        assets = position.totalStvTokenShares;
        delete userPositions[user];

        return assets;
    }

    // Allow contract to receive ETH from LenderMock
    receive() external payable {}
}
