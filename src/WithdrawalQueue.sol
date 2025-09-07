// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {console} from "forge-std/console.sol";

/// @title Withdrawal Queue V3 for Staking Vault Wrapper
/// @notice Handles withdrawal requests for stvToken holders
contract WithdrawalQueue is AccessControlEnumerableUpgradeable, PausableUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice max time for finalization of the withdrawal request
    uint256 public immutable MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS;

    // ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");
    bytes32 public constant FINALIZE_ROLE = keccak256("FINALIZE_ROLE");

    /// @notice precision base for share rate
    uint256 public constant E27_PRECISION_BASE = 1e27;

    /// @notice minimal amount of stvToken that is possible to withdraw
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 100;
    uint256 public constant MAX_WITHDRAWAL_AMOUNT = 10_000 * 1e18;

    /// @dev return value for the `find...` methods in case of no result
    uint256 internal constant NOT_FOUND = 0;

    /// @notice structure representing a request for withdrawal
    struct WithdrawalRequest {
        /// @notice sum of all assets submitted for withdrawals including this request
        uint128 cumulativeAssets;
        /// @notice sum of all shares locked for withdrawal including this request
        uint128 cumulativeShares;
        /// @notice address that can claim the request
        address owner;
        /// @notice block.timestamp when the request was created
        uint40 timestamp;
        /// @notice flag if the request was claimed
        bool claimed;
    }

    /// @notice structure to store share rates for finalized requests
    struct Checkpoint {
        uint256 fromRequestId;
        uint256 shareRate;
    }

    /// @notice output format struct for `getWithdrawalStatus()` method
    struct WithdrawalRequestStatus {
        /// @notice asset amount that was locked for this request
        uint256 amountOfAssets;
        /// @notice amount of shares locked for this request
        uint256 amountOfShares;
        /// @notice address that can claim this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    WrapperBase public immutable WRAPPER;

    /// @custom:storage-location erc7201:wrapper.storage.WithdrawalQueue
    struct WithdrawalQueueStorage {
        /// @dev queue for withdrawal requests, indexes (requestId) start from 1
        mapping(uint256 => WithdrawalRequest) requests;
        /// @dev last index in request queue
        uint256 lastRequestId;
        /// @dev last index of finalized request in the queue
        uint256 lastFinalizedRequestId;
        /// @dev finalization rate history, indexes start from 1
        mapping(uint256 => Checkpoint) checkpoints;
        /// @dev last index in checkpoints array
        uint256 lastCheckpointIndex;
        /// @dev amount of ETH locked on contract for further claiming
        uint256 totalLockedAssets;
        /// @dev withdrawal requests mapped to the owners
        mapping(address => EnumerableSet.UintSet) requestsByOwner;
        /// @dev timestamp of emergency exit activation
        uint256 emergencyExitActivationTimestamp;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.storage.WithdrawalQueue")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WithdrawalQueueStorageLocation = 0xff0bcb2d6a043ff95a84af574799a6cec022695552f02c53d70e4e5aa1e06100;

    event Initialized(address indexed admin);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        uint256 amountOfAssets,
        uint256 amountOfShares
    );
    event WithdrawalsFinalized(
        uint256 indexed from,
        uint256 indexed to,
        uint256 amountOfETHLocked,
        uint256 sharesToBurn,
        uint256 timestamp
    );
    event EmergencyExitActivated(uint256 timestamp);

    error AdminZeroAddress();
    error OnlyWrapperCan();
    error RequestAmountTooSmall(uint256 amount);
    error RequestAmountTooLarge(uint256 amount);
    error InvalidRequestId(uint256 requestId);
    error RequestNotFinalized(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error NotEnoughETH(uint256 available, uint256 required);
    error InvalidShareRate(uint256 shareRate);
    error TooMuchEtherToFinalize(
        uint256 amountOfETH,
        uint256 totalAssetsToFinalize
    );
    error ZeroRecipient();
    error ArraysLengthMismatch(
        uint256 firstArrayLength,
        uint256 secondArrayLength
    );
    error ReportStale();
    error InvalidRequestIdRange(uint256 start, uint256 end);
    error RequestNotFoundOrNotFinalized(uint256 requestId);
    error CantSendValueRecipientMayHaveReverted();
    error InvalidHint(uint256 hint);
    error InvalidState();
    error ZeroShareRate();
    error EmptyBatches();
    error BatchesAreNotSorted();
    error RequestIdsNotSorted();
    error InvalidEmergencyExitActivation();
    error ZeroAddress();

    /// @notice Modifier to check role or Emergency Exit
    modifier onlyRoleOrEmergencyExit(bytes32 role) {
        if (!isEmergencyExitActivated()) {
            _checkRole(role, msg.sender);
        }
        _;
    }

    constructor(WrapperBase _wrapper, uint256 _maxAcceptableWQFinalizationTimeInSeconds) {
        WRAPPER = _wrapper;
        MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS = _maxAcceptableWQFinalizationTimeInSeconds;

        _disableInitializers();
    }

    /// @notice Initialize the contract storage explicitly.
    /// @param _admin admin address that can change every role.
    /// @dev Reverts if `_admin` equals to `address(0)`
    /// @dev NB! It's initialized in paused state by default and should be resumed explicitly to start
    function initialize(address _admin, address _finalizeRoleHolder) external initializer {
        if (_admin == address(0)) revert AdminZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FINALIZE_ROLE, _finalizeRoleHolder);

        _getWithdrawalQueueStorage().requests[0] = WithdrawalRequest({
            cumulativeAssets: 0,
            cumulativeShares: 0,
            owner: address(this),
            timestamp: uint40(block.timestamp),
            claimed: true
        });

        emit Initialized(_admin);
    }

    function test() external view {
        console.logBytes32(DEFAULT_ADMIN_ROLE);
        console.log(hasRole(DEFAULT_ADMIN_ROLE, msg.sender));
    }

    /// @notice Resume withdrawal requests placement and finalization
    /// Contract is deployed in paused state and should be resumed explicitly
    function resume() external {
        _checkRole(RESUME_ROLE, msg.sender);
        _unpause();
    }

    //
    // FINALIZATION FLOW
    //
    // Process when protocol is fixing the withdrawal request value and lock the required amount of ETH.
    // The value of a request after finalization can be:
    //  - nominal (when the amount of eth locked for this request are equal to the request's stETH)
    //  - discounted (when the amount of eth will be lower, because the protocol share rate dropped
    //   before request is finalized, so it will be equal to `request's shares` * `protocol share rate`)
    // The parameters that are required for finalization are:
    //  - current share rate of the protocol
    //  - id of the last request that can be finalized
    //  - the amount of eth that must be locked for these requests
    // To calculate the eth amount we'll need to know which requests in the queue will be finalized as nominal
    // and which as discounted and the exact value of the discount. It's impossible to calculate without the unbounded
    // loop over the unfinalized part of the queue. So, we need to extract a part of the algorithm off-chain, bring the
    // result with oracle report and check it later and check the result later.
    // So, we came to this solution:
    // Off-chain
    // 1. Oracle iterates over the queue off-chain and calculate the id of the latest finalizable request
    // in the queue. Then it splits all the requests that will be finalized into batches the way,
    // that requests in a batch are all nominal or all discounted.
    // And passes them in the report as the array of the ending ids of these batches. So it can be reconstructed like
    // `[lastFinalizedRequestId+1, batches[0]], [batches[0]+1, batches[1]] ... [batches[n-2], batches[n-1]]`
    // 2. Contract checks the validity of the batches on-chain and calculate the amount of eth required to
    //  finalize them. It can be done without unbounded loop using partial sums that are calculated on request enqueueing.
    // 3. Contract marks the request's as finalized and locks the eth for claiming. It also,
    //  set's the discount checkpoint for these request's if required that will be applied on claim for each request's
    // individually depending on request's share rate.

    /// @notice Request multiple withdrawals for a user
    /// @param _assets amount of ETH to withdraw
    /// @param _owner address that will be able to claim the created request
    /// @return requestIds the created withdrawal request ids
    function requestWithdrawals(uint256[] calldata _assets, address _owner)
        external
        returns (uint256[] memory requestIds)
    {
        // TODO: update to match requestWithdrawal
        _requireNotPaused();

        IDashboard dashboard = IDashboard(WRAPPER.DASHBOARD());
        IVaultHub vaultHub = IVaultHub(dashboard.VAULT_HUB());
        if (!vaultHub.isReportFresh(WRAPPER.STAKING_VAULT())) revert ReportStale();

        if (_owner == address(0)) _owner = msg.sender;

        requestIds = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; ++i) {
            requestIds[i] = requestWithdrawal(_assets[i], _owner);
        }
    }

    function requestWithdrawal(uint256 _stvShares, address _owner)
        public
        returns (uint256 requestId)
    {
        _requireNotPaused();
        if (msg.sender != address(WRAPPER)) revert OnlyWrapperCan();

        uint256 assets = WRAPPER.previewRedeem(_stvShares);

        if (assets < MIN_WITHDRAWAL_AMOUNT) revert RequestAmountTooSmall(assets);
        if (assets > MAX_WITHDRAWAL_AMOUNT) revert RequestAmountTooLarge(assets);

        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();

        uint256 lastRequestId = $.lastRequestId;
        WithdrawalRequest memory lastRequest = $.requests[lastRequestId];

        requestId = lastRequestId + 1;
        $.lastRequestId = requestId;

        uint256 cumulativeAssets = lastRequest.cumulativeAssets + assets;
        uint256 cumulativeShares = lastRequest.cumulativeShares + _stvShares;

        $.requests[requestId] = WithdrawalRequest({
            cumulativeAssets: uint128(cumulativeAssets),
            cumulativeShares: uint128(cumulativeShares),
            owner: _owner,
            timestamp: uint40(block.timestamp),
            claimed: false
        });

        assert($.requestsByOwner[_owner].add(requestId));

        emit WithdrawalRequested(requestId, _owner, assets, _stvShares);
    }

    /// @notice Finalize withdrawal requests up to the specified request ID
    /// @param _maxRequests the last request ID to finalize
    function finalize(uint256 _maxRequests)
        external
        onlyRoleOrEmergencyExit(FINALIZE_ROLE)
        returns (uint256 finalizedRequests)
    {
        // check report freshness
        IDashboard dashboard = IDashboard(WRAPPER.DASHBOARD());
        IVaultHub vaultHub = IVaultHub(dashboard.VAULT_HUB());
        if (!vaultHub.isReportFresh(WRAPPER.STAKING_VAULT())) revert ReportStale();

        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();

        uint256 lastFinalizedRequestId = wqStorage.lastFinalizedRequestId;
        uint256 firstRequestIdToFinalize = lastFinalizedRequestId + 1;
        uint256 lastRequestIdToFinalize = lastFinalizedRequestId + _maxRequests;

        // Validate that _maxRequests is within valid range
        if (lastRequestIdToFinalize > wqStorage.lastRequestId) {
            revert InvalidRequestIdRange(lastFinalizedRequestId, _maxRequests);
        }

        uint256 currentShareRate = calculateCurrentShareRate();
        uint256 withdrawableValue = dashboard.withdrawableValue();

        uint256 totalEthToFinalize;
        uint256 totalSharesToBurn;

        // Finalize all requests in the range
        for (uint256 i = firstRequestIdToFinalize; i <= lastRequestIdToFinalize; i++) {
            WithdrawalRequest memory request = wqStorage.requests[i];
            WithdrawalRequest memory prevRequest = wqStorage.requests[i - 1];
            (uint256 requestShareRate, uint256 eth, uint256 shares) = _calcStats(prevRequest, request);

            // Apply discount if the request share rate is above the current share rate
            if (requestShareRate > currentShareRate) {
                eth = (shares * currentShareRate) / E27_PRECISION_BASE;
            }

            // Stop if insufficient ETH to cover this request
            if (eth > withdrawableValue) {
                break;
            }

            withdrawableValue -= eth;
            totalEthToFinalize += eth;
            totalSharesToBurn += shares;
            finalizedRequests++;
        }

        WRAPPER.burnSharesForWithdrawalQueue(totalSharesToBurn);

        if (finalizedRequests == 0) {
            return 0;
        }

        lastFinalizedRequestId = lastFinalizedRequestId + finalizedRequests;

        // Create checkpoint with ShareRate
        uint256 lastCheckpointIndex = wqStorage.lastCheckpointIndex + 1;
        wqStorage.checkpoints[lastCheckpointIndex] = Checkpoint({
            fromRequestId: firstRequestIdToFinalize,
            shareRate: currentShareRate
        });

        wqStorage.lastCheckpointIndex = lastCheckpointIndex;
        wqStorage.lastFinalizedRequestId = lastFinalizedRequestId;
        wqStorage.totalLockedAssets += totalEthToFinalize;

        emit WithdrawalsFinalized(firstRequestIdToFinalize, lastFinalizedRequestId, totalEthToFinalize, totalSharesToBurn, block.timestamp);
    }

    /// @notice Calculate current share rate of the vault
    /// @return current share rate of the vault (1e27 precision)
    function calculateCurrentShareRate() public view returns (uint256) {
        uint256 totalStvToken = WRAPPER.totalSupply();
        uint256 totalEthInVault = WRAPPER.totalAssets();

        if (totalStvToken == 0) {
            return E27_PRECISION_BASE;
        }

        return (totalEthInVault * E27_PRECISION_BASE) / totalStvToken;
    }

    /// @notice Claim one`_requestId` request once finalized sending locked ether to the owner
    /// @param _requestId request id to claim
    /// @dev use unbounded loop to find a hint, which can lead to OOG
    /// @dev
    ///  Reverts if requestId or hint are not valid
    ///  Reverts if request is not finalized or already claimed
    ///  Reverts if msg sender is not an owner of request
    function claimWithdrawal(uint256 _requestId, address _recipient) external returns (uint256) {
        uint256 checkpoint = _findCheckpointHint(_requestId, 1, getLastCheckpointIndex());
        // address recipient = _recipient == address(0) ? msg.sender : _recipient;
        _recipient = _recipient == address(0) ? msg.sender : _recipient;


        if (_requestId == 0) revert InvalidRequestId(_requestId);
        if (msg.sender != address(WRAPPER)) revert OnlyWrapperCan();

        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (_requestId > wqStorage.lastFinalizedRequestId) revert RequestNotFoundOrNotFinalized(_requestId);

        WithdrawalRequest storage request = wqStorage.requests[_requestId];

        if (request.claimed) revert RequestAlreadyClaimed(_requestId);
        // if (request.owner != msg.sender) revert NotOwner(msg.sender, request.owner);

        request.claimed = true;
        assert(wqStorage.requestsByOwner[request.owner].remove(_requestId));

        uint256 ethWithDiscount = _calculateClaimableEther(request, _requestId, checkpoint);
        // because of the stETH rounding issue
        // (issue: https://github.com/lidofinance/lido-dao/issues/442 )
        // some dust (1-2 wei per request) will be accumulated upon claiming
        wqStorage.totalLockedAssets -= ethWithDiscount;

        (bool success, ) = _recipient.call{value: ethWithDiscount}("");
        if (!success) revert CantSendValueRecipientMayHaveReverted();

        return ethWithDiscount;


        // return _claim(_requestId, checkpoint, recipient);
    }

    // TODO: restore in Wrapper or somehow
    // /// @notice Claim a batch of withdrawal requests
    // /// @param _requestIds array of request ids to claim
    // /// @param _hints checkpoint hints for each request
    // /// @param _recipient address where claimed ether will be sent to
    // function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints, address _recipient) external {
    //     if (_requestIds.length != _hints.length) {
    //         revert ArraysLengthMismatch(_requestIds.length, _hints.length);
    //     }

    //     address recipient = _recipient == address(0) ? msg.sender : _recipient;
    //     for (uint256 i = 0; i < _requestIds.length; ++i) {
    //         _claim(_requestIds[i], _hints[i], recipient);
    //     }
    // }

    /// @notice Finds the list of hints for the given `_requestIds` searching among the checkpoints with indices
    ///  in the range  `[_firstIndex, _lastIndex]`.
    ///  NB! Array of request ids should be sorted
    ///  NB! `_firstIndex` should be greater than 0, because checkpoint list is 1-based array
    ///  Usage: findCheckpointHints(_requestIds, 1, getLastCheckpointIndex())
    /// @param _requestIds ids of the requests sorted in the ascending order to get hints for
    /// @param _firstIndex left boundary of the search range. Should be greater than 0
    /// @param _lastIndex right boundary of the search range. Should be less than or equal to getLastCheckpointIndex()
    /// @return hintIds array of hints used to find required checkpoint for the request
    function findCheckpointHints(uint256[] calldata _requestIds, uint256 _firstIndex, uint256 _lastIndex)
        external
        view
        returns (uint256[] memory hintIds)
    {
        hintIds = new uint256[](_requestIds.length);
        uint256 prevRequestId = 0;
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            if (_requestIds[i] < prevRequestId) revert RequestIdsNotSorted();
            hintIds[i] = _findCheckpointHint(_requestIds[i], _firstIndex, _lastIndex);
            _firstIndex = hintIds[i];
            prevRequestId = _requestIds[i];
        }
    }

    /// @dev View function to find a checkpoint hint to use in `claimWithdrawal()` and `getClaimableEther()`
    ///  Search will be performed in the range of `[_firstIndex, _lastIndex]`
    ///
    /// @param _requestId request id to search the checkpoint for
    /// @param _start index of the left boundary of the search range, should be greater than 0
    /// @param _end index of the right boundary of the search range, should be less than or equal
    ///  to `getLastCheckpointIndex()`
    ///
    /// @return hint for later use in other methods or 0 if hint not found in the range
    function _findCheckpointHint(uint256 _requestId, uint256 _start, uint256 _end) internal view returns (uint256) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > wqStorage.lastRequestId) revert InvalidRequestId(_requestId);

        uint256 lastCheckpointIndex_ = wqStorage.lastCheckpointIndex;
        if (_start == 0 || _end > lastCheckpointIndex_) revert InvalidRequestIdRange(_start, _end);

        if (lastCheckpointIndex_ == 0 || _requestId > wqStorage.lastFinalizedRequestId || _start > _end) return NOT_FOUND;

        // Right boundary
        if (_requestId >= wqStorage.checkpoints[_end].fromRequestId) {
            // it's the last checkpoint, so it's valid
            if (_end == lastCheckpointIndex_) return _end;
            // it fits right before the next checkpoint
            if (_requestId < wqStorage.checkpoints[_end + 1].fromRequestId) return _end;

            return NOT_FOUND;
        }
        // Left boundary
        if (_requestId < wqStorage.checkpoints[_start].fromRequestId) {
            return NOT_FOUND;
        }

        // Binary search
        uint256 min = _start;
        uint256 max = _end - 1;

        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (wqStorage.checkpoints[mid].fromRequestId <= _requestId) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    // function _claim(uint256 _requestId, uint256 _hint, address _recipient) internal returns (uint256) {
    //     if (_requestId == 0) revert InvalidRequestId(_requestId);
    //     if (msg.sender != address(WRAPPER)) revert OnlyWrapperCan();

    //     WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
    //     if (_requestId > wqStorage.lastFinalizedRequestId) revert RequestNotFoundOrNotFinalized(_requestId);

    //     WithdrawalRequest storage request = wqStorage.requests[_requestId];

    //     if (request.claimed) revert RequestAlreadyClaimed(_requestId);
    //     // if (request.owner != msg.sender) revert NotOwner(msg.sender, request.owner);

    //     request.claimed = true;
    //     assert(wqStorage.requestsByOwner[request.owner].remove(_requestId));

    //     uint256 ethWithDiscount = _calculateClaimableEther(request, _requestId, _hint);
    //     // because of the stETH rounding issue
    //     // (issue: https://github.com/lidofinance/lido-dao/issues/442 )
    //     // some dust (1-2 wei per request) will be accumulated upon claiming
    //     wqStorage.totalLockedAssets -= ethWithDiscount;
    //     console.log("_recipient", _recipient);
    //     (bool success, ) = _recipient.call{value: ethWithDiscount}("");

    //     // TODO: restore - for some reason it fails in wrapper b test upon setting USER1 as recipient
    //     // if (!success) revert CantSendValueRecipientMayHaveReverted();

    //     return ethWithDiscount;
    // }

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return requestIds array of request ids
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        return _getWithdrawalQueueStorage().requestsByOwner[_owner].values();
    }

    /// @notice Returns status for requests with provided ids
    /// @param _requestIds array of withdrawal request ids
    /// @return statuses array of withdrawal request statuses
    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new WithdrawalRequestStatus[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            statuses[i] = _getStatus(_requestIds[i]);
        }
    }

    /// @notice Returns status for a single request
    /// @param _requestId request id
    /// @return status withdrawal request status
    function getWithdrawalStatus(uint256 _requestId) external view returns (WithdrawalRequestStatus memory status) {
        return _getStatus(_requestId);
    }

    /// @notice Returns amount of ether available for claim for each provided request id
    /// @param _requestIds array of request ids
    /// @param _hints checkpoint hints. can be found with `findCheckpointHints(_requestIds, 1, getLastCheckpointIndex())`
    /// @return claimableEthValues amount of claimable ether for each request, amount is equal to 0 if request
    ///  is not finalized or already claimed
    function getClaimableEther(uint256[] calldata _requestIds, uint256[] calldata _hints)
        external
        view
        returns (uint256[] memory claimableEthValues)
    {
        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        claimableEthValues = new uint256[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            claimableEthValues[i] = _getClaimableEther(_requestIds[i], _hints[i]);
        }
    }

    /// @notice return the number of unfinalized requests in the queue
    function unfinalizedRequestNumber() external view returns (uint256) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        return wqStorage.lastRequestId - wqStorage.lastFinalizedRequestId;
    }

    /// @notice Returns the amount of assets in the queue yet to be finalized
    function unfinalizedAssets() external view returns (uint256) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        return wqStorage.requests[wqStorage.lastRequestId].cumulativeAssets - wqStorage.requests[wqStorage.lastFinalizedRequestId].cumulativeAssets;
    }

    /// @notice Returns the amount of shares in the queue yet to be finalized
    function unfinalizedShares() external view returns (uint256) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        return wqStorage.requests[wqStorage.lastRequestId].cumulativeShares - wqStorage.requests[wqStorage.lastFinalizedRequestId].cumulativeShares;
    }

    /// @notice Returns the last request id
    function getLastRequestId() public view returns (uint256) {
        return _getWithdrawalQueueStorage().lastRequestId;
    }

    /// @notice Returns the last finalized request id
    function getLastFinalizedRequestId() public view returns (uint256) {
        return _getWithdrawalQueueStorage().lastFinalizedRequestId;
    }

    /// @notice Returns the last checkpoint index
    function getLastCheckpointIndex() public view returns (uint256) {
        return _getWithdrawalQueueStorage().lastCheckpointIndex;
    }

    /// @notice Receive ETH
    receive() external payable {}

    /// @notice Returns true if Emergency Exit is activated
    function isEmergencyExitActivated() public view returns (bool) {
        return _getWithdrawalQueueStorage().emergencyExitActivationTimestamp > 0;
    }

    /// @notice Returns true if requests have not been finalized for a long time
    function isWithdrawalQueueStuck() public view returns (bool) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (wqStorage.lastFinalizedRequestId >= wqStorage.lastRequestId) {
            return false;
        }

        uint256 firstPendingRequest = wqStorage.lastFinalizedRequestId + 1;

        uint256 firstPendingRequestTimestamp = wqStorage.requests[firstPendingRequest].timestamp;
        uint256 maxAcceptableTime = firstPendingRequestTimestamp + MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS;

        return maxAcceptableTime < block.timestamp;
    }

    /// @notice Permissionless method to activate Emergency Exit
    /// @dev can only be called if Withdrawal Queue is stuck
    function activateEmergencyExit() external {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (wqStorage.emergencyExitActivationTimestamp > 0 || !isWithdrawalQueueStuck()) revert InvalidEmergencyExitActivation();

        wqStorage.emergencyExitActivationTimestamp = block.timestamp;

        emit EmergencyExitActivated(wqStorage.emergencyExitActivationTimestamp);
    }

    /// @notice Get the queue
    function _getQueue() internal view returns (mapping(uint256 => WithdrawalRequest) storage queue) {
        return _getWithdrawalQueueStorage().requests;
    }

    /// @notice Calculate claimable ether for a request
    /// @param _requestId request id
    /// @param _hint checkpoint hint
    /// @return amount of claimable ether
    function _getClaimableEther(uint256 _requestId, uint256 _hint) internal view returns (uint256) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > wqStorage.lastRequestId) return 0;
        if (_requestId > wqStorage.lastFinalizedRequestId) return 0;

        WithdrawalRequest storage request = wqStorage.requests[_requestId];
        if (request.claimed) return 0;

        return _calculateClaimableEther(request, _requestId, _hint);
    }

    /// @notice Calculate claimable ether for a request using checkpoint
    /// @param _request the withdrawal request
    /// @param _requestId request id
    /// @param _hint checkpoint hint
    /// @return amount of claimable ether
    function _calculateClaimableEther(WithdrawalRequest storage _request, uint256 _requestId, uint256 _hint) internal view returns (uint256) {
        if (_hint == 0) revert InvalidHint(_hint);

        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();

        uint256 lastCheckpointIndex_ = wqStorage.lastCheckpointIndex;
        if (_hint > lastCheckpointIndex_) revert InvalidHint(_hint);

        Checkpoint memory checkpoint = wqStorage.checkpoints[_hint];
        // Reverts if requestId is not in range [checkpoint[hint], checkpoint[hint+1])
        // ______(>______
        //    ^  hint
        if (_requestId < checkpoint.fromRequestId) revert InvalidHint(_hint);
        if (_hint < lastCheckpointIndex_) {
            // ______(>______(>________
            //       hint    hint+1  ^
            Checkpoint memory nextCheckpoint = wqStorage.checkpoints[_hint + 1];
            if (nextCheckpoint.fromRequestId <= _requestId) revert InvalidHint(_hint);
        }

        WithdrawalRequest memory prevRequest = wqStorage.requests[_requestId - 1];
        (uint256 batchShareRate, uint256 eth, uint256 shares) = _calcStats(prevRequest, _request);

        console.log("batchShareRate", batchShareRate);
        console.log("checkpoint.shareRate", checkpoint.shareRate);
        console.log("shares", shares);
        console.log("eth", eth);

        if (batchShareRate > checkpoint.shareRate) {
            eth = (shares * checkpoint.shareRate) / E27_PRECISION_BASE;
        }

        return eth;
    }

    /// @dev calculate request stats (shareRate, assets and shares) for the range of `(_preStartRequest, _endRequest]`
    function _calcStats(WithdrawalRequest memory _preStartRequest, WithdrawalRequest memory _endRequest)
        internal
        pure
        returns (uint256 shareRate, uint256 assets, uint256 shares)
    {
        assets = _endRequest.cumulativeAssets - _preStartRequest.cumulativeAssets;
        shares = _endRequest.cumulativeShares - _preStartRequest.cumulativeShares;

        shareRate = assets * E27_PRECISION_BASE / shares;
    }

    /// @notice Get status for a single request
    /// @param _requestId request id
    /// @return status withdrawal request status
    function _getStatus(uint256 _requestId) internal view returns (WithdrawalRequestStatus memory) {
        WithdrawalQueueStorage storage wqStorage = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > wqStorage.lastRequestId) revert InvalidRequestId(_requestId);

        WithdrawalRequest storage request = wqStorage.requests[_requestId];
        WithdrawalRequest storage previousRequest = wqStorage.requests[_requestId - 1];

        return WithdrawalRequestStatus({
            amountOfAssets: request.cumulativeAssets - previousRequest.cumulativeAssets,
            amountOfShares: request.cumulativeShares - previousRequest.cumulativeShares,
            owner: request.owner,
            timestamp: request.timestamp,
            isFinalized: _requestId <= wqStorage.lastFinalizedRequestId,
            isClaimed: request.claimed
        });
    }

    function _getWithdrawalQueueStorage() private pure returns (WithdrawalQueueStorage storage $) {
        assembly {
            $.slot := WithdrawalQueueStorageLocation
        }
    }
}
