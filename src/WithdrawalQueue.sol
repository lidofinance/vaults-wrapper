// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";

/// @title Withdrawal Queue V3 for Staking Vault Wrapper
/// @notice Handles withdrawal requests for stvToken holders
contract WithdrawalQueue is Initializable, AccessControlEnumerableUpgradeable, PausableUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev maximal length of the batch array provided for prefinalization. See `prefinalize()`
    uint256 public constant MAX_BATCHES_LENGTH = 36;

    // ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");
    bytes32 public constant FINALIZE_ROLE = keccak256("FINALIZE_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    /// @notice precision base for share rate
    uint256 public constant E27_PRECISION_BASE = 1e27;

    /// @notice minimal amount of stvToken that is possible to withdraw
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 100;
    uint256 public constant MAX_WITHDRAWAL_AMOUNT = 10_000 * 1e18;

    /// @dev return value for the `find...` methods in case of no result
    uint256 internal constant NOT_FOUND = 0;

    /// @notice max time for finalization of the withdrawal request
    uint256 public constant MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS = 60 days;

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

    /// @dev queue for withdrawal requests, indexes (requestId) start from 1
    mapping(uint256 => WithdrawalRequest) public requests;
    /// @dev last index in request queue
    uint256 public lastRequestId;
    /// @dev last index of finalized request in the queue
    uint256 public lastFinalizedRequestId;
    /// @dev finalization rate history, indexes start from 1
    mapping(uint256 => Checkpoint) public checkpoints;
    /// @dev last index in checkpoints array
    uint256 public lastCheckpointIndex;
    /// @dev amount of ETH locked on contract for further claiming
    uint256 public totalLockedAssets;
    /// @dev withdrawal requests mapped to the owners
    mapping(address => EnumerableSet.UintSet) private requestsByOwner;
    /// @dev timestamp of emergency exit activation
    uint256 public emergencyExitActivationTimestamp;

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
    event WithdrawalClaimed(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 amountOfETH
    );
    event EmergencyExitActivated(uint256 timestamp);

    error AdminZeroAddress();
    error RequestAmountTooSmall(uint256 amount);
    error RequestAmountTooLarge(uint256 amount);
    error InvalidRequestId(uint256 requestId);
    error RequestNotFinalized(uint256 requestId);
    error RequestAlreadyClaimed(uint256 requestId);
    error NotOwner(address caller, address owner);
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

    constructor(address _wrapper) {
        WRAPPER = WrapperBase(payable(_wrapper));

        _disableInitializers();
    }

    /// @notice Initialize the contract storage explicitly.
    /// @param _admin admin address that can change every role.
    /// @dev Reverts if `_admin` equals to `address(0)`
    /// @dev NB! It's initialized in paused state by default and should be resumed explicitly to start
    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert AdminZeroAddress();

        __AccessControlEnumerable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _pause();
        emit Initialized(_admin);
    }

    /// @notice Resume withdrawal requests placement and finalization
    /// Contract is deployed in paused state and should be resumed explicitly
    function resume() external {
        _checkRole(RESUME_ROLE, msg.sender);
        _unpause();
    }

    /// @notice Pause withdrawal requests placement and finalization. Claiming finalized requests will still be available
    /// @param _duration pause duration in seconds (use `type(uint256).max` for unlimited)
    /// @dev Reverts if contract is already paused
    /// @dev Reverts reason if sender has no `PAUSE_ROLE`
    function pauseFor(uint256 _duration) external onlyRole(PAUSE_ROLE) {
        _pause();
        _duration = _duration;
        require(false, "NOT IMPLEMENTED");
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

    /// @notice transient state that is used to pass intermediate results between several `calculateFinalizationBatches`
    //   invocations
    struct BatchesCalculationState {
        /// @notice amount of ether available in the protocol that can be used to finalize withdrawal requests
        ///  Will decrease on each call and will be equal to the remainder when calculation is finished
        ///  Should be set before the first call
        uint256 remainingEthBudget;
        /// @notice flag that is set to `true` if returned state is final and `false` if more calls are required
        bool finished;
        /// @notice static array to store last request id in each batch
        uint256[MAX_BATCHES_LENGTH] batches;
        /// @notice length of the filled part of `batches` array
        uint256 batchesLength;
    }

    /// @notice Offchain view for the oracle daemon that calculates how many requests can be finalized within
    /// the given budget, time period and share rate limits. Returned requests are split into batches.
    /// Each batch consist of the requests that all have the share rate below the `_maxShareRate` or above it.
    /// Below you can see an example how 14 requests with different share rates will be split into 5 batches by
    /// this method
    ///
    /// ^ share rate
    /// |
    /// |         • •
    /// |       •    •   • • •
    /// |----------------------•------ _maxShareRate
    /// |   •          •        • • •
    /// | •
    /// +-------------------------------> requestId
    ///  | 1st|  2nd  |3| 4th | 5th  |
    ///
    /// @param _maxRequestsPerCall max request number that can be processed per call.
    /// @param _state structure that accumulates the state across multiple invocations to overcome gas limits.
    ///  To start calculation you should pass `state.remainingEthBudget` and `state.finished == false` and then invoke
    ///  the function with returned `state` until it returns a state with `finished` flag set
    /// @return state that is changing on each call and should be passed to the next call until `state.finished` is true

    ///TODO: removed _maxTimestamp
    function calculateFinalizationBatches(
        uint256 _maxRequestsPerCall,
        BatchesCalculationState memory _state
    ) external view returns (BatchesCalculationState memory) {
        if (_state.finished || _state.remainingEthBudget == 0)
            revert InvalidState();
        uint256 _maxShareRate = calculateCurrentShareRate();

        uint256 currentId;
        WithdrawalRequest memory prevRequest;
        uint256 prevRequestShareRate;

        if (_state.batchesLength == 0) {
            currentId = getLastFinalizedRequestId() + 1;

            prevRequest = requests[currentId - 1];
        } else {
            uint256 lastHandledRequestId = _state.batches[_state.batchesLength - 1];
            currentId = lastHandledRequestId + 1;

            prevRequest = requests[lastHandledRequestId];
            (prevRequestShareRate,,) = _calcBatch(requests[lastHandledRequestId - 1], prevRequest);
        }

        uint256 nextCallRequestId = currentId + _maxRequestsPerCall;
        uint256 queueLength = getLastRequestId() + 1;

        while (currentId < queueLength && currentId < nextCallRequestId) {
            WithdrawalRequest memory request = requests[currentId];

            (uint256 requestShareRate, uint256 ethToFinalize, uint256 shares) = _calcBatch(prevRequest, request);

            if (requestShareRate > _maxShareRate) {
                // discounted
                ethToFinalize = (shares * _maxShareRate) / E27_PRECISION_BASE;
            }

            if (ethToFinalize > _state.remainingEthBudget) break; // budget break
            _state.remainingEthBudget -= ethToFinalize;

            if (_state.batchesLength != 0 && (
                // share rate of requests in the same batch can differ by 1-2 wei because of the rounding error
                // (issue: https://github.com/lidofinance/lido-dao/issues/442 )
                // so we're taking requests that are placed during the same report
                // as equal even if their actual share rate are different

                // both requests are below the line
                prevRequestShareRate <= _maxShareRate && requestShareRate <= _maxShareRate ||
                // both requests are above the line
                prevRequestShareRate > _maxShareRate && requestShareRate > _maxShareRate
            )) {
                _state.batches[_state.batchesLength - 1] = currentId; // extend the last batch
            } else {
                // to be able to check batches on-chain we need array to have limited length
                if (_state.batchesLength == MAX_BATCHES_LENGTH) break;

                // create a new batch
                _state.batches[_state.batchesLength] = currentId;
                ++_state.batchesLength;
            }

            prevRequestShareRate = requestShareRate;
            prevRequest = request;
            unchecked{ ++currentId; }
        }

        _state.finished = currentId == queueLength || currentId < nextCallRequestId;

        return _state;
    }

    /// @notice Checks finalization batches, calculates required ether and the amount of shares to burn
    /// @param _batches finalization batches calculated offchain using `calculateFinalizationBatches()`
    /// @param _maxShareRate max share rate that will be used for request finalization (1e27 precision)
    /// @return ethToLock amount of ether that should be sent with `finalize()` method
    /// @return sharesToBurn amount of shares that belongs to requests that will be finalized
    function prefinalize(uint256[] calldata _batches, uint256 _maxShareRate)
        external
        view
        returns (uint256 ethToLock, uint256 sharesToBurn)
    {
        if (_maxShareRate == 0) revert ZeroShareRate();
        if (_batches.length == 0) revert EmptyBatches();

        if (_batches[0] <= getLastFinalizedRequestId()) revert InvalidRequestId(_batches[0]);
        if (_batches[_batches.length - 1] > getLastRequestId()) revert InvalidRequestId(_batches[_batches.length - 1]);

        uint256 currentBatchIndex;
        uint256 prevBatchEndRequestId = getLastFinalizedRequestId();
        WithdrawalRequest memory prevBatchEnd = requests[prevBatchEndRequestId];
        while (currentBatchIndex < _batches.length) {
            uint256 batchEndRequestId = _batches[currentBatchIndex];
            if (batchEndRequestId <= prevBatchEndRequestId) revert BatchesAreNotSorted();

            WithdrawalRequest memory batchEnd = requests[batchEndRequestId];

            (uint256 batchShareRate, uint256 stETH, uint256 shares) = _calcBatch(prevBatchEnd, batchEnd);

            if (batchShareRate > _maxShareRate) {
                // discounted
                ethToLock += (shares * _maxShareRate) / E27_PRECISION_BASE;
            } else {
                // nominal
                ethToLock += stETH;
            }
            sharesToBurn += shares;

            prevBatchEndRequestId = batchEndRequestId;
            prevBatchEnd = batchEnd;
            unchecked{ ++currentBatchIndex; }
        }
    }

    /// @notice Request withdrawal for a user
    /// @param _owner address that will be able to claim the created request
    /// @param _assets amount of assets to withdraw
    /// @return requestId the created withdrawal request id
    function requestWithdrawal(address _owner, uint256 _assets)
        external
        returns (uint256 requestId)
    {
        _requireNotPaused();
        _checkWithdrawalRequestAmount(_assets);

        // Only the wrapper can call this function
        if (msg.sender != address(WRAPPER)) {
            revert("Only wrapper can request withdrawals");
        }

        IDashboard dashboard = IDashboard(WRAPPER.DASHBOARD());
        IVaultHub vaultHub = IVaultHub(dashboard.VAULT_HUB());
        if (!vaultHub.isReportFresh(WRAPPER.STAKING_VAULT())) revert ReportStale();

        uint256 shares = WRAPPER.previewWithdraw(_assets);

        uint256 lastRequestId_ = getLastRequestId();
        WithdrawalRequest memory lastRequest = requests[lastRequestId_];

        requestId = lastRequestId_ + 1;
        lastRequestId = requestId;

        uint256 cumulativeAssets = lastRequest.cumulativeAssets + _assets;
        uint256 cumulativeShares = lastRequest.cumulativeShares + shares;

        requests[requestId] = WithdrawalRequest({
            cumulativeAssets: uint128(cumulativeAssets),
            cumulativeShares: uint128(cumulativeShares),
            owner: _owner,
            timestamp: uint40(block.timestamp),
            claimed: false
        });

        assert(requestsByOwner[_owner].add(requestId));

        emit WithdrawalRequested(requestId, _owner, _assets, shares);
    }

    /// @notice Finalize withdrawal requests up to the specified request ID
    /// @param _lastRequestIdToFinalize the last request ID to finalize
    function finalize(uint256 _lastRequestIdToFinalize)
        external
        onlyRoleOrEmergencyExit(FINALIZE_ROLE)
    {
        require(_lastRequestIdToFinalize > getLastFinalizedRequestId(), "Invalid request ID");
        require(_lastRequestIdToFinalize <= getLastRequestId(), "Request not found");

        // check report freshness
        IDashboard dashboard = IDashboard(WRAPPER.DASHBOARD());
        IVaultHub vaultHub = IVaultHub(dashboard.VAULT_HUB());
        if (!vaultHub.isReportFresh(WRAPPER.STAKING_VAULT())) revert ReportStale();

        uint256 lastFinalizedRequestId_ = getLastFinalizedRequestId();
        uint256 firstRequestIdToFinalize = lastFinalizedRequestId_ + 1;
        uint256 currentShareRate = calculateCurrentShareRate();

        // Calculate total amount for finalization
        WithdrawalRequest memory lastFinalized = requests[lastFinalizedRequestId_];
        WithdrawalRequest memory toFinalize = requests[_lastRequestIdToFinalize];

        uint256 totalAssetsToFinalize = toFinalize.cumulativeAssets - lastFinalized.cumulativeAssets;
        uint256 totalSharesToFinalize = toFinalize.cumulativeShares - lastFinalized.cumulativeShares;

        uint256 withdrawableValue = dashboard.withdrawableValue();
        if (withdrawableValue < totalAssetsToFinalize) {
            revert NotEnoughETH(withdrawableValue, totalAssetsToFinalize);
        }

        uint256 _amountOfETH = totalAssetsToFinalize;
        dashboard.withdraw(address(this), _amountOfETH);

        // Finalize all requests in the range
        for (uint256 i = firstRequestIdToFinalize; i <= _lastRequestIdToFinalize; i++) {
            requests[i].claimed = false; // Reset claimed flag for finalization
        }

        // Create checkpoint with ShareRate
        lastCheckpointIndex++;
        checkpoints[lastCheckpointIndex] = Checkpoint({
            fromRequestId: firstRequestIdToFinalize,
            shareRate: currentShareRate
        });

        lastFinalizedRequestId = _lastRequestIdToFinalize;
        totalLockedAssets += _amountOfETH;

        emit WithdrawalsFinalized(firstRequestIdToFinalize, _lastRequestIdToFinalize, _amountOfETH, totalSharesToFinalize, block.timestamp);
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

    /// @notice Claim one `_requestId` request once finalized sending locked ether to the owner
    /// @param _requestId request id to claim
    /// @dev use unbounded loop to find a hint, which can lead to OOG
    /// @dev
    ///  Reverts if requestId or hint are not valid
    ///  Reverts if request is not finalized or already claimed
    ///  Reverts if msg sender is not an owner of request
    function claimWithdrawal(uint256 _requestId) external {
        uint256 checkpoint = _findCheckpointHint(_requestId, 1, getLastCheckpointIndex());
        _claim(_requestId, checkpoint, msg.sender);
    }

    /// @notice Claim a batch of withdrawal requests
    /// @param _requestIds array of request ids to claim
    /// @param _hints checkpoint hints for each request
    /// @param _recipient address where claimed ether will be sent to
    function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints, address _recipient) external {
        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        for (uint256 i = 0; i < _requestIds.length; ++i) {
            _claim(_requestIds[i], _hints[i], msg.sender);
        }

        _recipient = _recipient; // TODO
    }

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
        if (_requestId == 0 || _requestId > getLastRequestId()) revert InvalidRequestId(_requestId);

        uint256 lastCheckpointIndex_ = getLastCheckpointIndex();
        if (_start == 0 || _end > lastCheckpointIndex_) revert InvalidRequestIdRange(_start, _end);

        if (lastCheckpointIndex_ == 0 || _requestId > getLastFinalizedRequestId() || _start > _end) return NOT_FOUND;

        // Right boundary
        if (_requestId >= _getCheckpoints()[_end].fromRequestId) {
            // it's the last checkpoint, so it's valid
            if (_end == lastCheckpointIndex_) return _end;
            // it fits right before the next checkpoint
            if (_requestId < _getCheckpoints()[_end + 1].fromRequestId) return _end;

            return NOT_FOUND;
        }
        // Left boundary
        if (_requestId < _getCheckpoints()[_start].fromRequestId) {
            return NOT_FOUND;
        }

        // Binary search
        uint256 min = _start;
        uint256 max = _end - 1;

        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (_getCheckpoints()[mid].fromRequestId <= _requestId) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    function _getCheckpoints() internal view returns (mapping(uint256 => Checkpoint) storage) {
        return checkpoints;
    }

    function _claim(uint256 _requestId, uint256 _hint, address _recipient) internal {
        if (_requestId == 0) revert InvalidRequestId(_requestId);
        if (_requestId > getLastFinalizedRequestId()) revert RequestNotFoundOrNotFinalized(_requestId);

        WithdrawalRequest storage request = requests[_requestId];

        if (request.claimed) revert RequestAlreadyClaimed(_requestId);
        if (request.owner != msg.sender) revert NotOwner(msg.sender, request.owner);

        request.claimed = true;
        assert(requestsByOwner[request.owner].remove(_requestId));

        uint256 ethWithDiscount = _calculateClaimableEther(request, _requestId, _hint);
        // because of the stETH rounding issue
        // (issue: https://github.com/lidofinance/lido-dao/issues/442 )
        // some dust (1-2 wei per request) will be accumulated upon claiming
        totalLockedAssets -= ethWithDiscount;
        (bool success, ) = _recipient.call{value: ethWithDiscount}("");
        if (!success) revert CantSendValueRecipientMayHaveReverted();

        emit WithdrawalClaimed(_requestId, msg.sender, _recipient, ethWithDiscount);
    }

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return requestIds array of request ids
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        return requestsByOwner[_owner].values();
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
        return getLastRequestId() - getLastFinalizedRequestId();
    }

    /// @notice Returns the amount of assets in the queue yet to be finalized
    function unfinalizedAssets() external view returns (uint256) {
        return requests[getLastRequestId()].cumulativeAssets - requests[getLastFinalizedRequestId()].cumulativeAssets;
    }

    function unfinalizedShares() external view returns (uint256) {
        return requests[getLastRequestId()].cumulativeShares - requests[getLastFinalizedRequestId()].cumulativeShares;
    }

    function getLastRequestId() public view returns (uint256) {
        return lastRequestId;
    }

    function getLastFinalizedRequestId() public view returns (uint256) {
        return lastFinalizedRequestId;
    }

    function getLastCheckpointIndex() public view returns (uint256) {
        return lastCheckpointIndex;
    }

    /// @notice Check withdrawal request amount limits
    /// @param _amount amount to check
    function _checkWithdrawalRequestAmount(uint256 _amount) internal pure {
        if (_amount < MIN_WITHDRAWAL_AMOUNT) revert RequestAmountTooSmall(_amount);
        if (_amount > MAX_WITHDRAWAL_AMOUNT) revert RequestAmountTooLarge(_amount);
    }

    /// @notice Calculate claimable ether for a request
    /// @param _requestId request id
    /// @param _hint checkpoint hint
    /// @return amount of claimable ether
    function _getClaimableEther(uint256 _requestId, uint256 _hint) internal view returns (uint256) {
        if (_requestId == 0 || _requestId > getLastRequestId()) return 0;
        if (_requestId > getLastFinalizedRequestId()) return 0;

        WithdrawalRequest storage request = requests[_requestId];
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

        uint256 lastCheckpointIndex_ = getLastCheckpointIndex();
        if (_hint > lastCheckpointIndex_) revert InvalidHint(_hint);

        Checkpoint memory checkpoint = _getCheckpoints()[_hint];
        // Reverts if requestId is not in range [checkpoint[hint], checkpoint[hint+1])
        // ______(>______
        //    ^  hint
        if (_requestId < checkpoint.fromRequestId) revert InvalidHint(_hint);
        if (_hint < lastCheckpointIndex_) {
            // ______(>______(>________
            //       hint    hint+1  ^
            Checkpoint memory nextCheckpoint = _getCheckpoints()[_hint + 1];
            if (nextCheckpoint.fromRequestId <= _requestId) revert InvalidHint(_hint);
        }

        WithdrawalRequest memory prevRequest = requests[_requestId - 1];
        (uint256 batchShareRate, uint256 eth, uint256 shares) = _calcBatch(prevRequest, _request);

        if (batchShareRate > checkpoint.shareRate) {
            eth = (shares * checkpoint.shareRate) / E27_PRECISION_BASE;
        }

        return eth;
    }

    /// @dev calculate batch stats (shareRate, assets and shares) for the range of `(_preStartRequest, _endRequest]`
    function _calcBatch(WithdrawalRequest memory _preStartRequest, WithdrawalRequest memory _endRequest)
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
        if (_requestId == 0 || _requestId > getLastRequestId()) revert InvalidRequestId(_requestId);

        WithdrawalRequest storage request = requests[_requestId];
        WithdrawalRequest storage previousRequest = requests[_requestId - 1];

        return WithdrawalRequestStatus({
            amountOfAssets: request.cumulativeAssets - previousRequest.cumulativeAssets,
            amountOfShares: request.cumulativeShares - previousRequest.cumulativeShares,
            owner: request.owner,
            timestamp: request.timestamp,
            isFinalized: _requestId <= lastFinalizedRequestId,
            isClaimed: request.claimed
        });
    }

    /// @notice Receive ETH
    receive() external payable {}

    /// @notice Returns true if Emergency Exit is activated
    function isEmergencyExitActivated() public view returns (bool) {
        return emergencyExitActivationTimestamp > 0;
    }

    /// @notice Returns true if requests have not been finalized for a long time
    function isWithdrawalQueueStuck() public view returns (bool) {
        if (lastFinalizedRequestId >= lastRequestId) {
            return false;
        }

        uint256 firstPendingRequest = lastFinalizedRequestId + 1;

        if (firstPendingRequest > lastRequestId) {
            return false;
        }

        uint256 firstPendingRequestTimestamp = requests[firstPendingRequest].timestamp;
        uint256 maxAcceptableTime = firstPendingRequestTimestamp + MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS;

        return maxAcceptableTime <= block.timestamp;
    }

    /// @notice Permissionless method to activate Emergency Exit
    /// @dev can only be called if Withdrawal Queue is stuck
    function activateEmergencyExit() external {
        if (!isWithdrawalQueueStuck()) revert InvalidEmergencyExitActivation();

        emergencyExitActivationTimestamp = block.timestamp;

        emit EmergencyExitActivated(emergencyExitActivationTimestamp);
    }

    /// @notice Modifier to check role or Emergency Exit
    modifier onlyRoleOrEmergencyExit(bytes32 role) {
        if (!isEmergencyExitActivated()) {
            _checkRole(role, msg.sender);
        }
        _;
    }
}
