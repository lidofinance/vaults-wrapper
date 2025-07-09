// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Wrapper} from "./Wrapper.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Escrow {
    Wrapper public immutable WRAPPER;
    address public immutable VAULT_HUB;
    IStrategy public immutable STRATEGY;
    WithdrawalQueue public immutable WITHDRAWAL_QUEUE;
    IERC20 public immutable STETH;

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
        address _strategy,
        address _steth
    ) {
        WRAPPER = Wrapper(payable(_wrapper));
        WITHDRAWAL_QUEUE = WithdrawalQueue(_withdrawalQueue);
        STRATEGY = IStrategy(_strategy);
        STETH = IERC20(_steth);
    }

    function openPosition(uint256 stvTokenShares) external returns (uint256 positionId) {
        require(stvTokenShares > 0, "Zero shares");
        require(userPositionId[msg.sender] == 0, "Position already exists");

        require(!IStrategy(STRATEGY).isExiting(), "Strategy is exiting");

        // 1. Transfer stvToken to escrow
        WRAPPER.transferFrom(msg.sender, address(this), stvTokenShares);

        // 2. Remember shares for the user
        userStvShares[msg.sender] = stvTokenShares;

        // 3. Mint stETH through vaultHub
        address vault = WRAPPER.DASHBOARD().stakingVault();

        uint256 stethBeforeMint = STETH.balanceOf(address(this));
        IVaultHub(VAULT_HUB).mintShares(vault, address(this), stvTokenShares);
        uint256 stethAfterMint = STETH.balanceOf(address(this));
        uint256 mintedSteth = stethAfterMint - stethBeforeMint;

        // uint256 mintedStETH = IVaultHub(vaultHub).vaultConnection(vault).shareLimit;

        // 4. Execute strategy
        IStrategy(STRATEGY).execute(msg.sender, mintedSteth);

        // 5. Get information about borrowed assets
        (uint256 borrowAssets, , ) = IStrategy(STRATEGY).getBorrowDetails();

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
        IStrategy(STRATEGY).initiateExit(msg.sender, position.borrowedAssets);

        // 2. Initiate exit through withdrawal queue
        // Need to calculate how much ETH to withdraw
        uint256 totalAssets = position.stvTokenShares + position.borrowedAssets;

        // 3. Create withdrawal request
        withdrawalRequestId = WITHDRAWAL_QUEUE.requestWithdrawal(
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
            WITHDRAWAL_QUEUE.getRequest(position.withdrawalRequestId).isFinalized,
            "Withdrawal not finalized"
        );

        // 2. Claim withdrawal
        WITHDRAWAL_QUEUE.claim(position.withdrawalRequestId);

        // 3. Close position in strategy
        IStrategy(STRATEGY).finalizeExit(msg.sender);

        // 4. Return stvToken to user
        WRAPPER.transfer(msg.sender, position.stvTokenShares);

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
