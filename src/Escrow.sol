// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {Wrapper} from "./Wrapper.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract Escrow {
    Wrapper public immutable WRAPPER;
    address public immutable VAULT_HUB;
    IStrategy public immutable STRATEGY;
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
        address _strategy,
        address _steth
    ) {
        WRAPPER = Wrapper(payable(_wrapper));
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
        stvShares = stvShares; // TODO
    }

    function maxMintableStETHAmount(uint256 stvShares) public view returns (uint256) {
        IDashboard dashboard = IDashboard(payable(address(WRAPPER.DASHBOARD())));

        uint256 remainingMintingCapacity = dashboard.remainingMintingCapacityShares(0);
        uint256 totalMintingCapacity = dashboard.totalMintingCapacityShares();
        assert(remainingMintingCapacity <= totalMintingCapacity);

        uint256 userEthInPool = WRAPPER.convertToAssets(stvShares);
        uint256 totalVaultAssets = WRAPPER.totalAssets();
        uint256 userTotalMintingCapacity = (userEthInPool * totalMintingCapacity) / totalVaultAssets;
    }

    function mintStETH(uint256 stvShares) external returns (uint256 mintedStethShares) {
        if (stvShares == 0) revert ZeroStvShares();

        IDashboard dashboard = IDashboard(payable(address(WRAPPER.DASHBOARD())));

        WRAPPER.transferFrom(msg.sender, address(this), stvShares);
        lockedStvSharesByUser[msg.sender] += stvShares;

        uint256 remainingMintingCapacity = dashboard.remainingMintingCapacityShares(0);
        uint256 totalMintingCapacity = dashboard.totalMintingCapacityShares();
        assert(remainingMintingCapacity <= totalMintingCapacity);

        uint256 userEthInPool = WRAPPER.convertToAssets(stvShares);
        uint256 totalVaultAssets = WRAPPER.totalAssets();
        uint256 userTotalMintingCapacity = (userEthInPool * totalMintingCapacity) / totalVaultAssets;

        // User can mint up to their fair share, limited by remaining capacity
        mintedStethShares = userTotalMintingCapacity < remainingMintingCapacity ? userTotalMintingCapacity : remainingMintingCapacity;

        if (mintedStethShares == 0) revert NoMintingCapacityAvailable();

        dashboard.mintShares(msg.sender, mintedStethShares);

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


    error NoMintingCapacityAvailable();
    error ZeroStvShares();

}
