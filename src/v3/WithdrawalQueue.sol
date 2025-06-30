// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IDashboard {
    function withdrawableValue() external view returns (uint256);
    function withdraw(address recipient, uint256 etherAmount) external;
}

contract WithdrawalQueue is Ownable {

    uint256 public constant E27_PRECISION_BASE = 1e27;

    struct WithdrawalRequest {
        uint256 cumulativeAssets;
        uint256 cumulativeShares;
        address user;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    struct Checkpoint {
        uint256 fromRequestId;
        uint256 shareRate;
    }

    IDashboard public immutable dashboard;

    mapping(uint256 => WithdrawalRequest) public requests;
    mapping(uint256 => Checkpoint) public checkpoints;
    mapping(address => uint256[]) public requestsByOwner;

    uint256 public nextRequestId;
    uint256 public lastFinalizedRequestId;
    uint256 public lastCheckpointIndex;
    uint256 public totalLockedAssets;

    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 shares, uint256 assets);
    event WithdrawalProcessed(uint256 indexed requestId, address indexed user, uint256 shares, uint256 assets);
    event WithdrawalClaimed(uint256 indexed requestId, address indexed user, uint256 assets);
    event WithdrawalsFinalized(uint256 firstRequestId, uint256 lastRequestId, uint256 totalAssets, uint256 totalShares);

    error InvalidRequestId(uint256 requestId);
    error RequestNotFinalized(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error NotOwner(address caller, address owner);
    error NotEnoughETH(uint256 available, uint256 required);
    error InvalidShareRate(uint256 shareRate);
    error TooMuchEtherToFinalize(uint256 amountOfETH, uint256 totalAssetsToFinalize);

    constructor(address _dashboard) Ownable(msg.sender) {
        dashboard = IDashboard(_dashboard);
    }

    function requestWithdrawal(address user, uint256 shares, uint256 assets) 
        external 
        onlyOwner 
        returns (uint256) 
    {

        uint256 availableAssets = dashboard.withdrawableValue();
        
        // If enough assets - immediate withdrawal
        // requestId = 0 means immediate withdrawal
        if (availableAssets >= assets) {
            dashboard.withdraw(user, assets);
            return 0; 
        }

        // if not enough assets - withdraw from the vault to the queue and create a request
        dashboard.withdraw(address(this), availableAssets);
        
        uint256 requestId = nextRequestId++;

        uint256 cumulativeAssets = requestId == 1 ? assets : requests[requestId - 1].cumulativeAssets + assets;
        uint256 cumulativeShares = requestId == 1 ? shares : requests[requestId - 1].cumulativeShares + shares;

        requests[requestId] = WithdrawalRequest({
            cumulativeAssets: uint128(cumulativeAssets),
            cumulativeShares: uint128(cumulativeShares),
            user: user,
            timestamp: block.timestamp,
            isFinalized: false,
            isClaimed: false
        });
        
        requestsByOwner[user].push(requestId);
        
        emit WithdrawalRequested(requestId, user, shares, assets);
        return requestId;
    }

    function finalize(uint256 lastRequestIdToFinalize, uint256 amountOfETH, uint256 shareRate) external onlyOwner {
        require(lastRequestIdToFinalize > lastFinalizedRequestId, "Invalid request ID");
        require(lastRequestIdToFinalize <= nextRequestId - 1, "Request not found");
        
        uint256 firstRequestIdToFinalize = lastFinalizedRequestId + 1;
        
        // Вычисляем общую сумму для финализации
        WithdrawalRequest memory lastFinalized = requests[lastFinalizedRequestId];
        WithdrawalRequest memory toFinalize = requests[lastRequestIdToFinalize];
        
        uint256 totalAssetsToFinalize = toFinalize.cumulativeAssets - lastFinalized.cumulativeAssets;
        uint256 totalSharesToFinalize = toFinalize.cumulativeShares - lastFinalized.cumulativeShares;

        if (amountOfETH > totalAssetsToFinalize) {
            revert TooMuchEtherToFinalize(amountOfETH, totalAssetsToFinalize);
        }
        
        // Финализируем все запросы в диапазоне
        for (uint256 i = firstRequestIdToFinalize; i <= lastRequestIdToFinalize; i++) {
            requests[i].isFinalized = true;
        }

         // Создаем checkpoint с ShareRate
        lastCheckpointIndex++;
        checkpoints[lastCheckpointIndex] = Checkpoint({
            fromRequestId: firstRequestIdToFinalize,
            shareRate: shareRate
        });
        
        lastFinalizedRequestId = lastRequestIdToFinalize;
        totalLockedAssets += totalAssetsToFinalize;
        
        emit WithdrawalsFinalized(firstRequestIdToFinalize, lastRequestIdToFinalize, totalAssetsToFinalize, totalSharesToFinalize);
    }
    
    function claim(uint256 requestId) external {
        require(requestId > 0 && requestId <= nextRequestId - 1, "Invalid request ID");
        require(requestId <= lastFinalizedRequestId, "Request not finalized");
        
        WithdrawalRequest storage request = requests[requestId];
        require(request.user == msg.sender, "Not owner");
        require(!request.isClaimed, "Already claimed");
        
        request.isClaimed = true;
        
        uint256 assets = requestId == 1 
            ? request.cumulativeAssets 
            : request.cumulativeAssets - requests[requestId - 1].cumulativeAssets;
        
        totalLockedAssets -= assets;
        
        (bool success, ) = msg.sender.call{value: assets}("");
        require(success, "Transfer failed");
        
        emit WithdrawalClaimed(requestId, msg.sender, assets);
    }

    //todo: add hint
    function calculateClaimableAssets(uint256 requestId) external view returns (uint256) {
        if (requestId == 0 || requestId > nextRequestId - 1) return 0;
        if (requestId > lastFinalizedRequestId) return 0;
        
        WithdrawalRequest storage request = requests[requestId];
        if (request.isClaimed) return 0;
        
        // Вычисляем assets для этого конкретного запроса
        uint256 baseAssets = requestId == 1 ? request.cumulativeAssets : 
                            request.cumulativeAssets - requests[requestId - 1].cumulativeAssets;
        
        // Находим соответствующий checkpoint для этого запроса
        for (uint256 i = lastCheckpointIndex; i > 0; i--) {
            if (checkpoints[i].fromRequestId <= requestId) {
                // Применяем ShareRate из checkpoint
                return (baseAssets * checkpoints[i].shareRate) / E27_PRECISION_BASE;
            }
        }
        
        return 0; // Checkpoint not found
    }
    
    function getPendingRequests(address user) external view returns (uint256[] memory) {
        return requestsByOwner[user];
    }
    
    function getRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return requests[requestId];
    }

    function getCheckpoint(uint256 checkpointIndex) external view returns (Checkpoint memory) {
        return checkpoints[checkpointIndex];
    }

}