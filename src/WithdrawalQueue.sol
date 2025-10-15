// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {ILazyOracle} from "./interfaces/ILazyOracle.sol";
import {IWrapper} from "./interfaces/IWrapper.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";

/// @title Withdrawal Queue V3 for Staking Vault Wrapper
/// @notice Handles withdrawal requests for stvToken holders
contract WithdrawalQueue is AccessControlEnumerableUpgradeable, PausableUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @notice max time for finalization of the withdrawal request
    uint256 public immutable MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS;

    /// @notice min delay between withdrawal request and finalization
    uint256 public immutable MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS;

    // ACL
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    bytes32 public constant RESUME_ROLE = keccak256("RESUME_ROLE");
    bytes32 public constant FINALIZE_ROLE = keccak256("FINALIZE_ROLE");

    /// @notice precision base for stv and steth share rates
    uint256 public constant E27_PRECISION_BASE = 1e27;
    uint256 public constant E36_PRECISION_BASE = 1e36;

    /// @notice minimal amount of assets that is possible to withdraw
    /// @dev should be big enough to prevent DoS attacks by placing many small requests
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 1 * 10 ** 14; // 0.0001 ETH
    uint256 public constant MAX_WITHDRAWAL_AMOUNT = 10_000 * 10 ** 18; // 10,000 ETH

    /// @dev return value for the `_findCheckpointHint` method in case of no result
    uint256 internal constant NOT_FOUND = 0;

    IWrapper public immutable WRAPPER;
    IVaultHub public immutable VAULT_HUB;
    IDashboard public immutable DASHBOARD;
    IStETH public immutable STETH;
    ILazyOracle public immutable LAZY_ORACLE;
    IStakingVault public immutable STAKING_VAULT;

    /// @notice structure representing a request for withdrawal
    struct WithdrawalRequest {
        /// @notice sum of all stv locked for withdrawal including this request
        uint256 cumulativeStv;
        /// @notice sum of all steth shares to rebalance including this request
        uint128 cumulativeStethShares;
        /// @notice sum of all assets submitted for withdrawals including this request
        uint128 cumulativeAssets;
        /// @notice address that can claim the request
        address owner;
        /// @notice block.timestamp when the request was created
        uint40 timestamp;
        /// @notice flag if the request was claimed
        bool claimed;
    }

    /// @notice structure to store stv rates for finalized requests
    struct Checkpoint {
        uint256 fromRequestId;
        uint256 stvRate;
        uint256 stethShareRate;
    }

    /// @notice output format struct for `getWithdrawalStatus()` method
    struct WithdrawalRequestStatus {
        /// @notice amount of stv locked for this request
        uint256 amountOfStv;
        /// @notice amount of steth shares to rebalance for this request
        uint256 amountOfStethShares;
        /// @notice asset amount that was locked for this request
        uint256 amountOfAssets;
        /// @notice address that can claim this request
        address owner;
        /// @notice timestamp of when the request was created, in seconds
        uint256 timestamp;
        /// @notice true, if request is finalized
        bool isFinalized;
        /// @notice true, if request is claimed. Request is claimable if (isFinalized && !isClaimed)
        bool isClaimed;
    }

    /// @custom:storage-location erc7201:wrapper.storage.WithdrawalQueue
    struct WithdrawalQueueStorage {
        // ### 1st slot
        /// @dev queue for withdrawal requests, indexes (requestId) start from 1
        mapping(uint256 => WithdrawalRequest) requests;
        // ### 2nd slot
        /// @dev withdrawal requests mapped to the owners
        mapping(address => EnumerableSet.UintSet) requestsByOwner;
        // ### 3rd slot
        /// @dev finalization rate history, indexes start from 1
        mapping(uint256 => Checkpoint) checkpoints;
        // ### 4th slot
        /// @dev last index in request queue
        uint96 lastRequestId;
        /// @dev last index of finalized request in the queue
        uint96 lastFinalizedRequestId;
        /// @dev timestamp of emergency exit activation
        uint40 emergencyExitActivationTimestamp;
        // ### 5th slot
        /// @dev last index in checkpoints array
        uint96 lastCheckpointIndex;
        /// @dev amount of ETH locked on contract for further claiming
        uint96 totalLockedAssets;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.storage.WithdrawalQueue")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WithdrawalQueueStorageLocation =
        0xff0bcb2d6a043ff95a84af574799a6cec022695552f02c53d70e4e5aa1e06100;

    function _getWithdrawalQueueStorage() private pure returns (WithdrawalQueueStorage storage $) {
        assembly {
            $.slot := WithdrawalQueueStorageLocation
        }
    }

    event Initialized(address indexed admin);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        uint256 amountOfStv,
        uint256 amountOfStethShares,
        uint256 amountOfAssets
    );
    event WithdrawalsFinalized(
        uint256 indexed from,
        uint256 indexed to,
        uint256 ethLocked,
        uint256 stvBurned,
        uint256 stvRebalanced,
        uint256 stethSharesRebalanced,
        uint256 timestamp
    );

    event EmergencyExitActivated(uint256 timestamp);
    event ImplementationUpgraded(address newImplementation);

    error ZeroAddress();
    error OnlyWrapperCan();
    error RequestAmountTooSmall(uint256 amount);
    error RequestAmountTooLarge(uint256 amount);
    error InvalidRequestId(uint256 requestId);
    error InvalidRange(uint256 start, uint256 end);
    error RequestAlreadyClaimed(uint256 requestId);
    error RequestNotFoundOrNotFinalized(uint256 requestId);
    error RequestIdsNotSorted();
    error ArraysLengthMismatch(uint256 firstArrayLength, uint256 secondArrayLength);
    error VaultReportStale();
    error CantSendValueRecipientMayHaveReverted();
    error InvalidHint(uint256 hint);
    error InvalidEmergencyExitActivation();
    error NoRequestsToFinalize();
    error NotOwner(address _requestor, address _owner);

    constructor(
        address _wrapper,
        address _dashboard,
        address _vaultHub,
        address _steth,
        address _vault,
        address _lazyOracle,
        uint256 _maxAcceptableWQFinalizationTimeInSeconds,
        uint256 _minWithdrawalDelayTimeInSeconds
    ) {
        WRAPPER = IWrapper(payable(_wrapper));
        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(_vaultHub);
        STETH = IStETH(_steth);
        LAZY_ORACLE = ILazyOracle(_lazyOracle);
        STAKING_VAULT = IStakingVault(_vault);

        MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS = _maxAcceptableWQFinalizationTimeInSeconds;
        MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS = _minWithdrawalDelayTimeInSeconds;

        _disableInitializers();
        _pause();
    }

    /// @notice Initialize the contract storage explicitly.
    /// @param _admin admin address that can change every role.
    /// @dev Reverts if `_admin` equals to `address(0)`
    /// @dev NB! It's initialized in paused state by default and should be resumed explicitly to start
    function initialize(address _admin, address _finalizeRoleHolder) external initializer {
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FINALIZE_ROLE, _finalizeRoleHolder);

        _getWithdrawalQueueStorage().requests[0] = WithdrawalRequest({
            cumulativeStv: 0,
            cumulativeStethShares: 0,
            cumulativeAssets: 0,
            owner: address(0),
            timestamp: uint40(block.timestamp),
            claimed: true
        });

        emit Initialized(_admin);
    }

    // =================================================================================
    // PAUSE / RESUME
    // =================================================================================

    /**
     * @notice Pause withdrawal requests placement and finalization
     * @dev Does not affect claiming of already finalized requests
     */
    function pause() external {
        _checkRole(PAUSE_ROLE, msg.sender);
        _pause();
    }

    /**
     * @notice Resume withdrawal requests placement and finalization
     * @dev Contract is deployed in paused state and should be resumed explicitly
     */
    function resume() external {
        _checkRole(RESUME_ROLE, msg.sender);
        _unpause();
    }

    // =================================================================================
    // REQUESTS
    // =================================================================================

    /**
     * @notice Request multiple withdrawals for a user
     * @param _stvToWithdraw array of amounts of stv to withdraw
     * @param _stethSharesToRebalance array of amounts of stETH shares to rebalance
     * @param _owner address that will be able to claim the created request
     * @return requestIds the created withdrawal request ids
     * @dev Can be called only by the Wrapper contract
     */
    function requestWithdrawals(
        uint256[] calldata _stvToWithdraw,
        uint256[] calldata _stethSharesToRebalance,
        address _owner
    ) external returns (uint256[] memory requestIds) {
        _checkResumedOrEmergencyExit();
        _checkOnlyWrapper();

        if (_stvToWithdraw.length != _stethSharesToRebalance.length) {
            revert ArraysLengthMismatch(_stvToWithdraw.length, _stethSharesToRebalance.length);
        }

        requestIds = new uint256[](_stvToWithdraw.length);

        for (uint256 i = 0; i < _stvToWithdraw.length; ++i) {
            requestIds[i] = _requestWithdrawal(_stvToWithdraw[i], _stethSharesToRebalance[i], _owner);
        }
    }

    /**
     * @notice Request a withdrawal for a user
     * @param _stvToWithdraw amount of stv to withdraw
     * @param _stethSharesToRebalance amount of steth shares to rebalance
     * @param _owner address that will be able to claim the created request
     * @return requestId the created withdrawal request id
     * @dev Can be called only by the Wrapper contract
     */
    function requestWithdrawal(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToRebalance,
        address _owner
    ) public returns (uint256 requestId) {
        _checkResumedOrEmergencyExit();
        _checkOnlyWrapper();

        requestId = _requestWithdrawal(_stvToWithdraw, _stethSharesToRebalance, _owner);
    }

    function _requestWithdrawal(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToRebalance,
        address _owner
    ) internal returns (uint256 requestId) {
        _checkResumedOrEmergencyExit();
        _checkOnlyWrapper();

        uint256 assets = WRAPPER.previewRedeem(_stvToWithdraw);

        if (assets < MIN_WITHDRAWAL_AMOUNT) revert RequestAmountTooSmall(assets);
        if (assets > MAX_WITHDRAWAL_AMOUNT) revert RequestAmountTooLarge(assets);

        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();

        uint256 lastRequestId = $.lastRequestId;
        WithdrawalRequest memory lastRequest = $.requests[lastRequestId];

        requestId = lastRequestId + 1;
        $.lastRequestId = uint96(requestId);

        uint256 cumulativeStv = lastRequest.cumulativeStv + _stvToWithdraw;
        uint256 cumulativeStethShares = lastRequest.cumulativeStethShares + _stethSharesToRebalance;
        uint256 cumulativeAssets = lastRequest.cumulativeAssets + assets;

        $.requests[requestId] = WithdrawalRequest({
            cumulativeStv: cumulativeStv,
            cumulativeStethShares: uint128(cumulativeStethShares),
            cumulativeAssets: uint128(cumulativeAssets),
            owner: _owner,
            timestamp: uint40(block.timestamp),
            claimed: false
        });

        assert($.requestsByOwner[_owner].add(requestId));

        emit WithdrawalRequested(requestId, _owner, _stvToWithdraw, _stethSharesToRebalance, assets);
    }

    // =================================================================================
    // FINALIZATION
    // =================================================================================

    /**
     * @notice Receive ETH for claims
     */
    receive() external payable {}

    /**
     * @notice Finalize withdrawal requests
     * @param _maxRequests the maximum number of requests to finalize
     * @return finalizedRequests the number of requests that were finalized
     * @dev MIN_WITHDRAWAL_AMOUNT is used to prevent DoS attacks by placing many small requests
     */
    function finalize(uint256 _maxRequests) external returns (uint256 finalizedRequests) {
        if (!isEmergencyExitActivated()) {
            _requireNotPaused();
            _checkRole(FINALIZE_ROLE, msg.sender);
        }

        _checkFreshReport();

        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();

        uint256 lastFinalizedRequestId = $.lastFinalizedRequestId;
        uint256 firstRequestIdToFinalize = lastFinalizedRequestId + 1;
        uint256 lastRequestIdToFinalize = Math.min(lastFinalizedRequestId + _maxRequests, $.lastRequestId);

        if (firstRequestIdToFinalize > lastRequestIdToFinalize) revert NoRequestsToFinalize();

        uint256 currentStvRate = calculateCurrentStvRate();
        uint256 currentStethShareRate = calculateCurrentStethShareRate();
        uint256 withdrawableValue = DASHBOARD.withdrawableValue();
        uint256 availableBalance = STAKING_VAULT.availableBalance();
        uint256 exceedingSteth = WRAPPER.totalExceedingMintedSteth();
        uint256 latestReportTimestamp = LAZY_ORACLE.latestReportTimestamp();

        uint256 totalStvToBurn;
        uint256 totalStethShares;
        uint256 totalEthToClaim;
        uint256 maxStvToRebalance;

        // Finalize all requests in the range
        for (uint256 i = firstRequestIdToFinalize; i <= lastRequestIdToFinalize; ++i) {
            WithdrawalRequest memory request = $.requests[i];
            WithdrawalRequest memory prevRequest = $.requests[i - 1];
            (uint256 stv, uint256 ethToClaim, uint256 stethSharesToRebalance, uint256 stethToRebalance) = _calcStats(
                prevRequest,
                request,
                currentStvRate,
                currentStethShareRate
            );

            uint256 stvToRebalance = Math.mulDiv(
                stethToRebalance,
                E36_PRECISION_BASE,
                currentStvRate,
                Math.Rounding.Ceil
            );

            // Cap stvToRebalance to stv in the request, the rest will be socialized to users
            if (stvToRebalance > stv) {
                stvToRebalance = stv;
            }

            uint256 ethToRebalance;

            // Exceeding stETH (if any) are used to cover rebalancing need without withdrawing ETH from the vault
            if (exceedingSteth > stethToRebalance) {
                exceedingSteth -= stethToRebalance;
            } else {
                exceedingSteth = 0;
                ethToRebalance = stethToRebalance - exceedingSteth;
            }

            if (
                // stop if insufficient ETH to cover this request
                // stop if not enough time has passed since the request was created
                // stop if the request was created after the latest report was published, at least one oracle report is required
                ethToClaim > withdrawableValue ||
                ethToClaim + ethToRebalance > availableBalance ||
                request.timestamp + MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS > block.timestamp ||
                request.timestamp > latestReportTimestamp
            ) {
                break;
            }

            withdrawableValue -= ethToClaim;
            availableBalance -= (ethToClaim + ethToRebalance);
            totalEthToClaim += ethToClaim;
            totalStvToBurn += (stv - stvToRebalance);
            totalStethShares += stethSharesToRebalance;
            maxStvToRebalance += stvToRebalance;
            finalizedRequests++;
        }

        if (finalizedRequests == 0) return 0;

        // 1. Withdraw ETH from the vault to cover finalized requests and burn associated stv
        // Eth to claim or stv to burn could be 0 if all requests are going to be rebalanced
        // Rebalance cannot be done first because it will withdraw eth without unlocking it
        if (totalEthToClaim > 0) DASHBOARD.withdraw(address(this), totalEthToClaim);
        if (totalStvToBurn > 0) WRAPPER.burnStvForWithdrawalQueue(totalStvToBurn);

        // 2. Rebalance steth shares by burning corresponding amount stv. Or socialize the losses if not enough stv
        // At this point stv rate may change because of the operation above
        // So it may burn less stv than maxStvToRebalance because of new stv rate
        uint256 totalStvRebalanced;
        if (totalStethShares > 0) {
            // Stv burning is limited at this point by maxStvToRebalance calculated above
            // to make sure that only stv of finalized requests is used for rebalancing
            totalStvRebalanced = WRAPPER.rebalanceMintedStethShares(totalStethShares, maxStvToRebalance);
        }

        // 3. Burn any remaining stv that was not used for rebalancing
        // The rebalancing may burn less stv than maxStvToRebalance because of:
        //   - the changed stv rate after the first step
        //   - accumulated rounding errors in maxStvToRebalance
        // It's guaranteed that maxStvToRebalance >= totalStvRebalanced
        uint256 remainingStvForRebalance = maxStvToRebalance - totalStvRebalanced;
        if (remainingStvForRebalance > 0) {
            WRAPPER.burnStvForWithdrawalQueue(remainingStvForRebalance);
            totalStvToBurn += remainingStvForRebalance;
        }

        lastFinalizedRequestId = lastFinalizedRequestId + finalizedRequests;

        // Create checkpoint with stvRate and stethShareRate
        uint256 lastCheckpointIndex = $.lastCheckpointIndex + 1;
        $.checkpoints[lastCheckpointIndex] = Checkpoint({
            fromRequestId: firstRequestIdToFinalize,
            stvRate: currentStvRate,
            stethShareRate: currentStethShareRate
        });

        $.lastCheckpointIndex = uint96(lastCheckpointIndex);
        $.lastFinalizedRequestId = uint96(lastFinalizedRequestId);
        $.totalLockedAssets += uint96(totalEthToClaim);

        emit WithdrawalsFinalized(
            firstRequestIdToFinalize,
            lastFinalizedRequestId,
            totalEthToClaim,
            totalStvToBurn,
            totalStvRebalanced,
            totalStethShares,
            block.timestamp
        );
    }

    /**
     * @notice Calculate current stv rate of the vault
     * @return stvRate Current stv rate of the vault (1e27 precision)
     */
    function calculateCurrentStvRate() public view returns (uint256 stvRate) {
        uint256 totalStv = WRAPPER.totalSupply(); // e27 precision
        uint256 totalAssets = WRAPPER.totalEffectiveAssets(); // e18 precision

        if (totalStv == 0) return E27_PRECISION_BASE;
        stvRate = (totalAssets * E36_PRECISION_BASE) / totalStv;
    }

    /**
     * @notice Calculate current stETH share rate
     * @return stethShareRate Current stETH share rate (1e27 precision)
     */
    function calculateCurrentStethShareRate() public view returns (uint256 stethShareRate) {
        stethShareRate = STETH.getPooledEthBySharesRoundUp(E27_PRECISION_BASE);
    }

    // =================================================================================
    // CLAIMING
    // =================================================================================

    /**
     * @notice Claim one `_requestId` request once finalized sending locked ether to the owner
     * @param _requestId request id to claim
     * @param _requestor address of the request owner, should be equal to msg.sender on Wrapper side
     * @param _recipient address where claimed ether will be sent to
     * @dev use unbounded loop to find a hint, which can lead to OOG
     * @dev
     *  Reverts if requestId or hint are not valid
     *  Reverts if request is not finalized or already claimed
     *  Reverts if msg sender is not an owner of request
     */
    function claimWithdrawal(
        uint256 _requestId,
        address _requestor,
        address _recipient
    ) external returns (uint256 claimedEth) {
        _checkOnlyWrapper();
        uint256 checkpoint = _findCheckpointHint(_requestId, 1, getLastCheckpointIndex());
        claimedEth = _claim(_requestId, checkpoint, _requestor, _recipient);
    }

    /**
     * @notice Claim a batch of withdrawal requests
     * @param _requestIds array of request ids to claim
     * @param _hints checkpoint hints for each request
     * @param _requestor address of the request owner, should be equal to msg.sender on Wrapper side
     * @param _recipient address where claimed ether will be sent to
     * @return claimedAmounts array of claimed amounts for each request
     */
    function claimWithdrawals(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints,
        address _requestor,
        address _recipient
    ) external returns (uint256[] memory claimedAmounts) {
        _checkOnlyWrapper();

        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        claimedAmounts = new uint256[](_requestIds.length);

        for (uint256 i = 0; i < _requestIds.length; ++i) {
            claimedAmounts[i] = _claim(_requestIds[i], _hints[i], _requestor, _recipient);
        }
    }

    function _claim(
        uint256 _requestId,
        uint256 _hint,
        address _requestor,
        address _recipient
    ) internal returns (uint256) {
        if (_requestId == 0) revert InvalidRequestId(_requestId);

        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if (_requestId > $.lastFinalizedRequestId) revert RequestNotFoundOrNotFinalized(_requestId);

        WithdrawalRequest storage request = $.requests[_requestId];

        if (request.claimed) revert RequestAlreadyClaimed(_requestId);
        if (request.owner != _requestor) revert NotOwner(_requestor, request.owner);

        request.claimed = true;
        assert($.requestsByOwner[request.owner].remove(_requestId));

        uint256 ethWithDiscount = _calculateClaimableEther(request, _requestId, _hint);
        // because of the rounding issue
        // some dust (1-2 wei per request) will be accumulated upon claiming
        $.totalLockedAssets -= uint96(ethWithDiscount);

        (bool success, ) = _recipient.call{value: ethWithDiscount}("");
        if (!success) revert CantSendValueRecipientMayHaveReverted();

        return ethWithDiscount;
    }

    /**
     * @notice Calculate claimable ether for a request
     * @param _requestId request id
     * @param _hint checkpoint hint
     * @return claimableEth amount of claimable ether
     */
    function _getClaimableEther(uint256 _requestId, uint256 _hint) internal view returns (uint256 claimableEth) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > $.lastRequestId) return 0;
        if (_requestId > $.lastFinalizedRequestId) return 0;

        WithdrawalRequest storage request = $.requests[_requestId];
        if (request.claimed) return 0;

        claimableEth = _calculateClaimableEther(request, _requestId, _hint);
    }

    /**
     * @notice Calculate claimable ether for a request using checkpoint
     * @param _request the withdrawal request
     * @param _requestId request id
     * @param _hint checkpoint hint
     * @return claimableEth amount of claimable ether
     */
    function _calculateClaimableEther(
        WithdrawalRequest storage _request,
        uint256 _requestId,
        uint256 _hint
    ) internal view returns (uint256 claimableEth) {
        if (_hint == 0) revert InvalidHint(_hint);

        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();

        uint256 lastCheckpointIndex_ = $.lastCheckpointIndex;
        if (_hint > lastCheckpointIndex_) revert InvalidHint(_hint);

        Checkpoint memory checkpoint = $.checkpoints[_hint];
        // Reverts if requestId is not in range [checkpoint[hint], checkpoint[hint+1])
        // ______(>______
        //    ^  hint
        if (_requestId < checkpoint.fromRequestId) revert InvalidHint(_hint);
        if (_hint < lastCheckpointIndex_) {
            // ______(>______(>________
            //       hint    hint+1  ^
            Checkpoint memory nextCheckpoint = $.checkpoints[_hint + 1];
            if (nextCheckpoint.fromRequestId <= _requestId) revert InvalidHint(_hint);
        }

        WithdrawalRequest memory prevRequest = $.requests[_requestId - 1];
        (, claimableEth, , ) = _calcStats(prevRequest, _request, checkpoint.stvRate, checkpoint.stethShareRate);
    }

    /**
     * @dev Calculate request stats (stv, assetsToClaim, stethSharesToRebalance and assetsToRebalance) for the request
     */
    function _calcStats(
        WithdrawalRequest memory _prevRequest,
        WithdrawalRequest memory _request,
        uint256 finalizationStvRate,
        uint256 stethShareRate
    )
        internal
        pure
        returns (uint256 stv, uint256 assetsToClaim, uint256 stethSharesToRebalance, uint256 assetsToRebalance)
    {
        stv = _request.cumulativeStv - _prevRequest.cumulativeStv;
        stethSharesToRebalance = _request.cumulativeStethShares - _prevRequest.cumulativeStethShares;
        assetsToClaim = _request.cumulativeAssets - _prevRequest.cumulativeAssets;

        uint256 requestStvRate = (assetsToClaim * E36_PRECISION_BASE) / stv;

        // Apply discount if the request stv rate is above the finalization stv rate
        if (requestStvRate > finalizationStvRate) {
            assetsToClaim = Math.mulDiv(stv, finalizationStvRate, E36_PRECISION_BASE, Math.Rounding.Floor);
        }

        if (stethSharesToRebalance > 0) {
            assetsToRebalance = Math.mulDiv(
                stethSharesToRebalance,
                stethShareRate,
                E27_PRECISION_BASE,
                Math.Rounding.Ceil
            );

            // Decrease assets to claim by the amount of assets to rebalance
            assetsToClaim = Math.saturatingSub(assetsToClaim, assetsToRebalance);
        }
    }

    // =================================================================================
    // CHECKPOINTS
    // =================================================================================

    /**
     * @notice Finds the list of hints for the given `_requestIds` searching among the checkpoints with indices
     *  in the range  `[_firstIndex, _lastIndex]`.
     *  NB! Array of request ids should be sorted
     *  NB! `_firstIndex` should be greater than 0, because checkpoint list is 1-based array
     *  Usage: findCheckpointHints(_requestIds, 1, getLastCheckpointIndex())
     * @param _requestIds ids of the requests sorted in the ascending order to get hints for
     * @param _firstIndex left boundary of the search range. Should be greater than 0
     * @param _lastIndex right boundary of the search range. Should be less than or equal to getLastCheckpointIndex()
     * @return hintIds array of hints used to find required checkpoint for the request
     */
    function findCheckpointHints(
        uint256[] calldata _requestIds,
        uint256 _firstIndex,
        uint256 _lastIndex
    ) external view returns (uint256[] memory hintIds) {
        hintIds = new uint256[](_requestIds.length);
        uint256 prevRequestId = 0;
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            if (_requestIds[i] < prevRequestId) revert RequestIdsNotSorted();
            hintIds[i] = _findCheckpointHint(_requestIds[i], _firstIndex, _lastIndex);
            _firstIndex = hintIds[i];
            prevRequestId = _requestIds[i];
        }
    }

    /**
     * @dev View function to find a checkpoint hint to use in `claimWithdrawal()` and `getClaimableEther()`
     *  Search will be performed in the range of `[_firstIndex, _lastIndex]`
     *
     * @param _requestId request id to search the checkpoint for
     * @param _start index of the left boundary of the search range, should be greater than 0
     * @param _end index of the right boundary of the search range, should be less than or equal to `getLastCheckpointIndex()`
     * @return hint for later use in other methods or 0 if hint not found in the range
     */
    function _findCheckpointHint(uint256 _requestId, uint256 _start, uint256 _end) internal view returns (uint256) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > $.lastRequestId) revert InvalidRequestId(_requestId);

        uint256 lastCheckpointIndex_ = $.lastCheckpointIndex;
        if (_start == 0 || _end > lastCheckpointIndex_) revert InvalidRange(_start, _end);

        if (lastCheckpointIndex_ == 0 || _requestId > $.lastFinalizedRequestId || _start > _end) return NOT_FOUND;

        // Right boundary
        if (_requestId >= $.checkpoints[_end].fromRequestId) {
            // it's the last checkpoint, so it's valid
            if (_end == lastCheckpointIndex_) return _end;
            // it fits right before the next checkpoint
            if (_requestId < $.checkpoints[_end + 1].fromRequestId) return _end;

            return NOT_FOUND;
        }
        // Left boundary
        if (_requestId < $.checkpoints[_start].fromRequestId) {
            return NOT_FOUND;
        }

        // Binary search
        uint256 min = _start;
        uint256 max = _end - 1;

        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if ($.checkpoints[mid].fromRequestId <= _requestId) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    // =================================================================================
    // REQUEST STATUS
    // =================================================================================

    /**
     * @notice Returns all withdrawal requests that belong to the `_owner` address
     * @param _owner address to get requests for
     * @return requestIds array of request ids
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        return _getWithdrawalQueueStorage().requestsByOwner[_owner].values();
    }

    /**
     * @notice Returns all withdrawal requests that belong to the `_owner` address
     * @param _owner address to get requests for
     * @param _start start index
     * @param _end end index
     * @return requestIds array of request ids
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function getWithdrawalRequests(
        address _owner,
        uint256 _start,
        uint256 _end
    ) external view returns (uint256[] memory requestIds) {
        requestIds = _getWithdrawalQueueStorage().requestsByOwner[_owner].values(_start, _end);
    }

    /**
     * @notice Returns the length of the withdrawal requests that belong to the `_owner` address.
     * @param _owner address to get requests for
     * @return length length of the requests array
     */
    function getWithdrawalRequestsLength(address _owner) external view returns (uint256 length) {
        length = _getWithdrawalQueueStorage().requestsByOwner[_owner].length();
    }

    /**
     * @notice Returns status for requests with provided ids
     * @param _requestIds array of withdrawal request ids
     * @return statuses array of withdrawal request statuses
     */
    function getWithdrawalStatus(
        uint256[] calldata _requestIds
    ) external view returns (WithdrawalRequestStatus[] memory statuses) {
        statuses = new WithdrawalRequestStatus[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            statuses[i] = _getStatus(_requestIds[i]);
        }
    }

    /**
     * @notice Returns status for a single request
     * @param _requestId request id
     * @return status withdrawal request status
     */
    function getWithdrawalStatus(uint256 _requestId) external view returns (WithdrawalRequestStatus memory status) {
        status = _getStatus(_requestId);
    }

    /**
     * @notice Returns the claimable ether for a request
     * @param _requestId request id to get claimable ether for
     * @return claimableEth claimable ether
     */
    function getClaimableEther(uint256 _requestId) external view returns (uint256 claimableEth) {
        uint256 checkpoint = _findCheckpointHint(_requestId, 1, getLastCheckpointIndex());
        claimableEth = _getClaimableEther(_requestId, checkpoint);
    }

    /**
     * @notice Returns amount of ether available for claim for each provided request id
     * @param _requestIds array of request ids to get claimable ether for
     * @param _hints checkpoint hints. can be found with `findCheckpointHints(_requestIds, 1, getLastCheckpointIndex())`
     * @return claimableEthValues amount of claimable ether for each request, amount is equal to 0 if request
     *  is not finalized or already claimed
     */
    function getClaimableEther(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external view returns (uint256[] memory claimableEthValues) {
        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        claimableEthValues = new uint256[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            claimableEthValues[i] = _getClaimableEther(_requestIds[i], _hints[i]);
        }
    }

    /**
     * @notice Get status for a single request
     * @param _requestId request id
     * @return requestStatus withdrawal request status
     */
    function _getStatus(uint256 _requestId) internal view returns (WithdrawalRequestStatus memory requestStatus) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if (_requestId == 0 || _requestId > $.lastRequestId) revert InvalidRequestId(_requestId);

        WithdrawalRequest storage request = $.requests[_requestId];
        WithdrawalRequest storage previousRequest = $.requests[_requestId - 1];

        requestStatus = WithdrawalRequestStatus({
            amountOfStv: request.cumulativeStv - previousRequest.cumulativeStv,
            amountOfStethShares: request.cumulativeStethShares - previousRequest.cumulativeStethShares,
            amountOfAssets: request.cumulativeAssets - previousRequest.cumulativeAssets,
            owner: request.owner,
            timestamp: request.timestamp,
            isFinalized: _requestId <= $.lastFinalizedRequestId,
            isClaimed: request.claimed
        });
    }

    // =================================================================================
    // QUEUE STATS
    // =================================================================================

    /**
     * @notice Return the number of unfinalized requests in the queue
     * @return requestNumber number of unfinalized requests
     */
    function unfinalizedRequestNumber() external view returns (uint256 requestNumber) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        requestNumber = $.lastRequestId - $.lastFinalizedRequestId;
    }

    /**
     * @notice Returns the amount of assets in the queue yet to be finalized
     * @dev NOTE: This returns the nominal amount. Actual ETH needed may be less due to discounts
     * @return assets amount of assets yet to be finalized
     */
    function unfinalizedAssets() external view returns (uint256 assets) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        assets = $.requests[$.lastRequestId].cumulativeAssets - $.requests[$.lastFinalizedRequestId].cumulativeAssets;
    }

    /**
     * @notice Returns the amount of stv in the queue yet to be finalized
     * @return stv amount of stv yet to be finalized
     */
    function unfinalizedStv() external view returns (uint256 stv) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        stv = $.requests[$.lastRequestId].cumulativeStv - $.requests[$.lastFinalizedRequestId].cumulativeStv;
    }

    /**
     * @notice Returns the last request id
     * @return requestId last request id
     */
    function getLastRequestId() public view returns (uint256 requestId) {
        requestId = _getWithdrawalQueueStorage().lastRequestId;
    }

    /**
     * @notice Returns the last finalized request id
     * @return requestId last finalized request id
     */
    function getLastFinalizedRequestId() public view returns (uint256 requestId) {
        requestId = _getWithdrawalQueueStorage().lastFinalizedRequestId;
    }

    /**
     * @notice Returns the last checkpoint index
     * @return index last checkpoint index
     */
    function getLastCheckpointIndex() public view returns (uint256 index) {
        index = _getWithdrawalQueueStorage().lastCheckpointIndex;
    }

    // =================================================================================
    // UPGRADABILITY
    // =================================================================================

    /**
     * @notice Enacts implementation upgrade
     * @param newImplementation address of the new implementation contract
     * @dev can only be called by the WRAPPER
     */
    function upgradeTo(address newImplementation) external {
        _checkOnlyWrapper();
        ERC1967Utils.upgradeToAndCall(newImplementation, new bytes(0));
        emit ImplementationUpgraded(newImplementation);
    }

    // =================================================================================
    // EMERGENCY EXIT
    // =================================================================================

    /**
     * @notice Returns true if Emergency Exit is activated
     * @return isActivate true if Emergency Exit is activated
     */
    function isEmergencyExitActivated() public view returns (bool isActivate) {
        isActivate = _getWithdrawalQueueStorage().emergencyExitActivationTimestamp > 0;
    }

    /**
     * @notice Returns true if requests have not been finalized for a long time
     * @return isStuck true if Withdrawal Queue is stuck
     */
    function isWithdrawalQueueStuck() public view returns (bool isStuck) {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if ($.lastFinalizedRequestId >= $.lastRequestId) return false;

        uint256 firstPendingRequest = $.lastFinalizedRequestId + 1;
        uint256 firstPendingRequestTimestamp = $.requests[firstPendingRequest].timestamp;
        uint256 maxAcceptableTime = firstPendingRequestTimestamp + MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS;

        isStuck = maxAcceptableTime < block.timestamp;
    }

    /**
     * @notice Permissionless method to activate Emergency Exit
     * @dev Can only be called if Withdrawal Queue is stuck
     */
    function activateEmergencyExit() external {
        WithdrawalQueueStorage storage $ = _getWithdrawalQueueStorage();
        if ($.emergencyExitActivationTimestamp > 0 || !isWithdrawalQueueStuck()) {
            revert InvalidEmergencyExitActivation();
        }

        $.emergencyExitActivationTimestamp = uint40(block.timestamp);

        emit EmergencyExitActivated($.emergencyExitActivationTimestamp);
    }

    // =================================================================================
    // CHECKS
    // =================================================================================

    function _checkOnlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert OnlyWrapperCan();
    }

    function _checkResumedOrEmergencyExit() internal view {
        if (!isEmergencyExitActivated()) _requireNotPaused();
    }

    function _checkFreshReport() internal view {
        if (!VAULT_HUB.isReportFresh(address(STAKING_VAULT))) revert VaultReportStale();
    }
}
