// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Wrapper} from "./Wrapper.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Escrow {
    Wrapper public immutable WRAPPER;
    address public immutable VAULT_HUB;
    IStrategy public immutable STRATEGY;
    WithdrawalQueue public immutable WITHDRAWAL_QUEUE;
    IERC20 public immutable STETH;
    IERC20 public immutable STV_TOKEN;

    struct Position {
        address user;
        uint256 stvTokenShares;
        uint256 borrowedAssets;
        uint256 positionId;
        uint256 withdrawalRequestId;
        bool isActive;
        bool isExiting;
        uint256 timestamp;
        uint256 totalStvTokenShares; // Total stvToken shares
    }

    mapping(address => uint256) public lockedStvSharesByUser;

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

    event AllowanceSet(address indexed owner, address indexed spender, uint256 amount);

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
        STV_TOKEN = IERC20(_wrapper);
        VAULT_HUB = address(WRAPPER.VAULT_HUB());
    }

    function openPosition(uint256 stvShares) external {
        WRAPPER.transferFrom(msg.sender, address(this), stvShares);

        WRAPPER.approve(address(STRATEGY), stvShares);
        STRATEGY.execute(msg.sender, stvShares);
    }

    function closePosition(uint256 stvShares) external {
        STRATEGY.finalizeExit(msg.sender);
    }


    function mintStETH(uint256 stvShares) external returns (uint256 mintedStethShares) {
        WRAPPER.transferFrom(msg.sender, address(this), stvShares);
        lockedStvSharesByUser[msg.sender] += stvShares;

        uint256 remainingMintingCapacity = IDashboard(payable(address(WRAPPER.DASHBOARD()))).remainingMintingCapacityShares(0);

        // TODO: fix
        // uint256 userEthInPool = WRAPPER.convertToAssets(stvShares);
        // require(userEthInPool <= remainingMintingCapacity, "Insufficient minting capacity");
        mintedStethShares = remainingMintingCapacity;

        IDashboard(payable(address(WRAPPER.DASHBOARD()))).mintShares(msg.sender, mintedStethShares);
    }

    function getUserStvShares(address _user) external view returns (uint256) {
        return lockedStvSharesByUser[_user];
    }

    function getTotalUserAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }

    function getTotalBorrowedAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }

}
