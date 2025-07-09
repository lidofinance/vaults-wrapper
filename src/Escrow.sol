// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Wrapper} from "./Wrapper.sol";

contract Escrow {
    Wrapper public immutable wrapper;
    address public immutable vaultHub;
    IStrategy public immutable strategy;
    WithdrawalQueue public immutable withdrawalQueue;

    struct Position {
        address user;
        uint256 stvTokenShares;
        uint256 borrowedAssets;
        uint256 positionId;
        uint256 withdrawalRequestId;
        bool isActive;
        bool isExiting;
        uint256 timestamp;
    }

    mapping(address => uint256) public userStvShares;
    mapping(address => uint256) public userBorrowedAssets;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256) public userPositionId;

    uint256 public totalBorrowedAssets;
    uint256 public nextPositionId;

    mapping(address => bool) public authorizedStrategies;

    event PositionOpened(
        address indexed user,
        uint256 indexed positionId,
        uint256 stvTokenShares,
        uint256 borrowedAssets
    );
    event PositionClosing(
        address indexed user,
        uint256 indexed positionId,
        uint256 withdrawalRequestId
    );
    event PositionClaimed(
        address indexed user,
        uint256 indexed positionId,
        uint256 assets
    );

    constructor(
        address _wrapper,
        address _withdrawalQueue,
        address _strategy
    ) {
        wrapper = Wrapper(payable(_wrapper));
        withdrawalQueue = WithdrawalQueue(_withdrawalQueue);
        strategy = IStrategy(_strategy);
    }

    function openPosition(uint256 stvTokenShares) external returns (uint256 positionId) {
        require(stvTokenShares > 0, "Zero shares");
        require(userPositionId[msg.sender] == 0, "Position already exists");

        require(!IStrategy(strategy).isExiting(), "Strategy is exiting");

        // 1. Transfer stvToken to escrow
        wrapper.transferFrom(msg.sender, address(this), stvTokenShares);

        // 2. Remember shares for the user
        userStvShares[msg.sender] = stvTokenShares;

        // 3. Mint stETH through vaultHub
        uint256 mintedStETH = IVaultHub(vaultHub).mintShares(stvTokenShares);

        // 4. Execute strategy
        IStrategy(strategy).execute(msg.sender, mintedStETH);

        // 5. Get information about borrowed assets
        (uint256 borrowAssets, , ) = IStrategy(strategy).getBorrowDetails();

        // 6. Save position data
        positionId = nextPositionId++;
        positions[positionId] = Position({
            user: msg.sender,
            stvTokenShares: stvTokenShares,
            borrowedAssets: borrowAssets,
            positionId: positionId,
            withdrawalRequestId: 0,
            isActive: true,
            isExiting: false,
            timestamp: block.timestamp
        });

        userPositionId[msg.sender] = positionId;
        userBorrowedAssets[msg.sender] = borrowAssets;
        totalBorrowedAssets += borrowAssets;

        emit PositionOpened(msg.sender, positionId, stvTokenShares, borrowAssets);
        return positionId;
    }

    function closePosition(uint256 positionId) external returns (uint256 withdrawalRequestId) {
        Position storage position = positions[positionId];
        require(position.user == msg.sender, "Not position owner");
        require(position.isActive, "Position not active");
        require(!position.isExiting, "Already exiting");

        // 1. Mark strategy for exit
        position.isExiting = true;

        // 2. Initiate exit
        IStrategy(strategy).initiateExit(msg.sender, position.borrowedAssets);

        // 2. Initiate exit through withdrawal queue
        // Need to calculate how much ETH to withdraw
        uint256 totalAssets = position.stvTokenShares + position.borrowedAssets;

        // 3. Create withdrawal request
        withdrawalRequestId = withdrawalQueue.requestWithdrawal(
            msg.sender,
            position.stvTokenShares,
            totalAssets
        );

        position.withdrawalRequestId = withdrawalRequestId;

        emit PositionClosing(msg.sender, positionId, withdrawalRequestId);
        return withdrawalRequestId;
    }

    function claimPosition(uint256 positionId) external returns (uint256 assets) {
        Position storage position = positions[positionId];
        require(position.user == msg.sender, "Not position owner");
        require(position.isExiting, "Position not exiting");
        require(position.withdrawalRequestId > 0, "No withdrawal request");

        // 1. Check that withdrawal request is finalized
        require(
            withdrawalQueue.getRequest(position.withdrawalRequestId).isFinalized,
            "Withdrawal not finalized"
        );

        // 2. Claim withdrawal
        withdrawalQueue.claim(position.withdrawalRequestId);

        // 3. Close position in strategy
        IStrategy(strategy).finalizeExit(msg.sender);

        // 4. Return stvToken to user
        wrapper.transfer(msg.sender, position.stvTokenShares);

        // 5. Update global counters
        totalBorrowedAssets -= position.borrowedAssets;
        userBorrowedAssets[msg.sender] = 0;
        userStvShares[msg.sender] = 0;
        userPositionId[msg.sender] = 0;

        // 6. Close position
        position.isActive = false;

        emit PositionClaimed(msg.sender, positionId, assets);
        return assets;
    }

    // Getters
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getUserPosition(address user) external view returns (Position memory) {
        uint256 positionId = userPositionId[user];
        return positionId > 0 ? positions[positionId] : Position({
            user: address(0),
            stvTokenShares: 0,
            borrowedAssets: 0,
            positionId: 0,
            withdrawalRequestId: 0,
            isActive: false,
            isExiting: false,
            timestamp: 0
        });
    }

    function getTotalUserAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }

    function getTotalBorrowedAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }
}

interface IVaultHub {
    function mintShares(uint256 stvTokenShares) external returns (uint256 mintedStETH);
}