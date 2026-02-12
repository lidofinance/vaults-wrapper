// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AllowList} from "../AllowList.sol";
import {StvStETHPool} from "../StvStETHPool.sol";
import {WithdrawalQueue} from "../WithdrawalQueue.sol";

import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";

import {IDepositQueue} from "../interfaces/mellow/IDepositQueue.sol";

import {IQueue} from "../interfaces/mellow/IQueue.sol";
import {IRedeemQueue} from "../interfaces/mellow/IRedeemQueue.sol";
import {ISyncDepositQueue} from "../interfaces/mellow/ISyncDepositQueue.sol";

import {IFeeManager} from "../interfaces/mellow/IFeeManager.sol";
import {IOracle} from "../interfaces/mellow/IOracle.sol";
import {IShareManager} from "../interfaces/mellow/IShareManager.sol";
import {IVault} from "../interfaces/mellow/IVault.sol";

import {StrategyCallForwarderRegistry} from "../strategy/StrategyCallForwarderRegistry.sol";
import {FeaturePausable} from "../utils/FeaturePausable.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IWstETH} from "../interfaces/core/IWstETH.sol";

/**
 * @title MellowStrategy
 * @notice Strategy adapter that routes user supply/redeem flows through a Mellow Vault via deposit/redeem queues.
 * @dev Uses per-user StrategyCallForwarder to custody assets and perform calls on behalf of the user.
 *
 * High-level flow:
 * - Supply: (optional ETH -> stv) + mint wstETH in the Pool -> deposit wstETH into Mellow deposit queue -> user receives Mellow shares.
 * - Exit: redeem shares through Mellow redeem queue -> claim wstETH once ready -> strategy emits finalization event.
 *
 * Access control:
 * - DEFAULT_ADMIN_ROLE: manages roles.
 * - SUPPLY_PAUSE_ROLE / SUPPLY_RESUME_ROLE: control supply feature.
 * - REDEEM_PAUSE_ROLE / REDEEM_RESUME_ROLE: control redeem feature.
 */
contract MellowStrategy is IStrategy, AllowList, FeaturePausable, StrategyCallForwarderRegistry {
    using SafeCast for uint256;

    /**
     * @notice Parameters used for supply into Mellow.
     * @param isSync Whether to use the sync deposit queue (true) or async deposit queue (false).
     * @param merkleProof Merkle proof for allowlist-enabled queues (if applicable).
     */
    struct MellowSupplyParams {
        bool isSync;
        bytes32[] merkleProof;
    }

    // ================================================================================
    // CONSTANTS / ROLES
    // ================================================================================

    /// @notice Feature flag id used by FeaturePausable to gate supply operations.
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    /// @notice Role that can pause supply operations.
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    /// @notice Role that can resume supply operations.
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    /// @notice Feature flag id used by FeaturePausable to gate redeem/withdraw operations.
    bytes32 public constant REDEEM_FEATURE = keccak256("REDEEM_FEATURE");
    /// @notice Role that can pause redeem operations.
    bytes32 public constant REDEEM_PAUSE_ROLE = keccak256("REDEEM_PAUSE_ROLE");
    /// @notice Role that can resume redeem operations.
    bytes32 public constant REDEEM_RESUME_ROLE = keccak256("REDEEM_RESUME_ROLE");

    // ================================================================================
    // IMMUTABLES
    // ================================================================================

    address public immutable POOL;
    IWstETH public immutable WSTETH;

    IVault public immutable MELLOW_VAULT;
    IFeeManager public immutable MELLOW_FEE_MANAGER;
    IOracle public immutable MELLOW_ORACLE;
    IShareManager public immutable MELLOW_SHARE_MANAGER;
    address public immutable MELLOW_SYNC_DEPOSIT_QUEUE;
    address public immutable MELLOW_ASYNC_DEPOSIT_QUEUE;
    address public immutable MELLOW_ASYNC_REDEEM_QUEUE;

    // ================================================================================
    // EVENTS
    // ================================================================================

    /**
     * @notice Emitted after a successful Mellow deposit request.
     * @param recipient Original user who initiated the supply.
     * @param referralAddress Referral address passed through to deposit queue.
     * @param wstethAmount Amount of wstETH deposited into the Mellow queue.
     * @param isSync Whether the sync deposit queue path was used.
     * @param shares Estimated shares for this deposit based on current oracle report and fees.
     * @param params ABI-encoded MellowSupplyParams provided by the user.
     */
    event MellowDeposited(
        address indexed recipient,
        address indexed referralAddress,
        uint256 wstethAmount,
        bool isSync,
        uint256 shares,
        bytes params
    );

    /**
     * @notice Emitted when a user creates an async redeem request in the Mellow redeem queue.
     * @param recipient Original user who initiated the exit request.
     * @param requestId Encoded request id used to later finalize the claim.
     * @param shares Amount of shares redeemed (burned) in the redeem queue.
     */
    event MellowWithdrawalRequested(address indexed recipient, bytes32 requestId, uint256 shares);

    // ================================================================================
    // ERRORS
    // ================================================================================

    error ZeroArgument(string name);
    error InvalidQueue(string name);
    error InsufficientMellowShares();
    error WithdrawalFailed();
    error RedeemFailed();
    error SupplyFailed();
    error NoAsyncDepositQueue();

    // ================================================================================
    // CONSTRUCTOR / INITIALIZER
    // ================================================================================

    /**
     * @notice Creates the strategy and validates all provided queue addresses against the Mellow vault.
     * @param strategyId_ Strategy id used by StrategyCallForwarderRegistry.
     * @param strategyCallForwarderImpl_ Implementation address for user call-forwarders.
     * @param pool_ StvStETHPool address used for minting wstETH / tracking stv shares.
     * @param vault_ Mellow vault instance this strategy integrates with.
     * @param syncDepositQueue_ Optional sync deposit queue (0x0 if unused).
     * @param asyncDepositQueue_ Optional async deposit queue (0x0 if unused).
     * @param asyncRedeemQueue_ Required async redeem queue.
     */
    constructor(
        bytes32 strategyId_,
        address strategyCallForwarderImpl_,
        address pool_,
        IVault vault_,
        address syncDepositQueue_,
        address asyncDepositQueue_,
        address asyncRedeemQueue_,
        bool allowListEnabled_
    ) StrategyCallForwarderRegistry(strategyId_, strategyCallForwarderImpl_) AllowList(allowListEnabled_) {
        address wsteth = address(StvStETHPool(payable(pool_)).WSTETH());
        if (address(vault_) == address(0)) {
            revert ZeroArgument("vault");
        }
        if (asyncDepositQueue_ == address(0) && syncDepositQueue_ == address(0)) {
            revert ZeroArgument("depositQueues");
        }

        if (syncDepositQueue_ != address(0)) {
            if (
                !vault_.hasQueue(syncDepositQueue_) || !vault_.isDepositQueue(syncDepositQueue_)
                    || IQueue(syncDepositQueue_).asset() != address(wsteth)
                    || !Strings.equal(ISyncDepositQueue(syncDepositQueue_).name(), "SyncDepositQueue")
            ) {
                revert InvalidQueue("syncDeposit");
            }
        }

        if (asyncDepositQueue_ != address(0)) {
            if (
                !vault_.hasQueue(asyncDepositQueue_) || !vault_.isDepositQueue(asyncDepositQueue_)
                    || IQueue(asyncDepositQueue_).asset() != address(wsteth)
            ) {
                revert InvalidQueue("asyncDeposit");
            } else {
                (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositQueue_).requestOf(address(this));
                if (assets != 0 || timestamp != 0) {
                    revert InvalidQueue("asyncDeposit");
                }
            }
        }

        if (asyncRedeemQueue_ == address(0)) {
            revert ZeroArgument("asyncRedeemQueue");
        }
        if (
            !vault_.hasQueue(asyncRedeemQueue_) || vault_.isDepositQueue(asyncRedeemQueue_)
                || IQueue(asyncRedeemQueue_).asset() != address(wsteth)
        ) {
            revert InvalidQueue("asyncRedeem");
        } else {
            IRedeemQueue.Request[] memory requests =
                IRedeemQueue(asyncRedeemQueue_).requestsOf(address(this), 0, type(uint256).max);
            if (requests.length != 0) {
                revert InvalidQueue("asyncRedeem");
            }
        }

        POOL = pool_;
        WSTETH = IWstETH(wsteth);

        MELLOW_VAULT = vault_;
        MELLOW_FEE_MANAGER = vault_.feeManager();
        MELLOW_ORACLE = vault_.oracle();
        MELLOW_SHARE_MANAGER = vault_.shareManager();

        MELLOW_SYNC_DEPOSIT_QUEUE = syncDepositQueue_;
        MELLOW_ASYNC_DEPOSIT_QUEUE = asyncDepositQueue_;
        MELLOW_ASYNC_REDEEM_QUEUE = asyncRedeemQueue_;

        _disableInitializers();
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Initializes roles and AccessControl state.
     * @dev Must be called once after deployment (upgradeable pattern).
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param supplyPauser_ Optional address receiving SUPPLY_PAUSE_ROLE (0x0 if none).
     */
    function initialize(address admin_, address supplyPauser_) external initializer {
        if (admin_ == address(0)) revert ZeroArgument("_admin");

        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        if (address(0) != supplyPauser_) {
            _grantRole(SUPPLY_PAUSE_ROLE, supplyPauser_);
        }
    }

    // =================================================================================
    // PAUSE / RESUME
    // =================================================================================

    /**
     * @notice Pause supply operations (previewSupply will return false; supply will revert).
     * @dev Requires SUPPLY_PAUSE_ROLE.
     */
    function pauseSupply() external onlyRole(SUPPLY_PAUSE_ROLE) {
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Resume supply operations.
     * @dev Requires SUPPLY_RESUME_ROLE.
     */
    function resumeSupply() external onlyRole(SUPPLY_RESUME_ROLE) {
        _resumeFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Pause redeem/withdraw operations (previewWithdraw/previewRedeem will return false; exits will revert).
     * @dev Requires REDEEM_PAUSE_ROLE.
     */
    function pauseRedeem() external onlyRole(REDEEM_PAUSE_ROLE) {
        _pauseFeature(REDEEM_FEATURE);
    }

    /**
     * @notice Resume redeem/withdraw operations.
     * @dev Requires REDEEM_RESUME_ROLE.
     */
    function resumeRedeem() external onlyRole(REDEEM_RESUME_ROLE) {
        _resumeFeature(REDEEM_FEATURE);
    }

    // =================================================================================
    // SUPPLY
    // =================================================================================

    /**
     * @notice Previews supply into Mellow by converting assets (wstETH) into shares using the current oracle report,
     * applying vault deposit fee and (for sync queue) sync penalty/maxAge constraints.
     * @dev Returns (false, 0) if supply is paused, queue is missing/paused, oracle report is suspicious/expired,
     * async queue requires claim-first, or computed shares are zero.
     *
     * @param assets Amount of wstETH to deposit into Mellow.
     * @param msgSender User address.
     * @param callForwarder User-specific forwarder address whose queue state may affect async behavior.
     * @param supplyParams ABI-decoded params controlling queue selection and allowlist proof.
     * @return success Whether the operation is currently expected to succeed.
     * @return shares Estimated shares minted/credited for the deposit (net of fees/penalties).
     */
    function previewSupply(
        uint256 assets,
        address msgSender,
        address callForwarder,
        MellowSupplyParams memory supplyParams
    ) public view returns (bool success, uint256 shares) {
        if (isFeaturePaused(SUPPLY_FEATURE)) return (false, 0);
        if (isAllowListed(msgSender)) return (false, 0);
        address queue = supplyParams.isSync ? MELLOW_SYNC_DEPOSIT_QUEUE : MELLOW_ASYNC_DEPOSIT_QUEUE;
        if (queue == address(0)) {
            return (false, 0);
        }
        if (MELLOW_VAULT.isPausedQueue(queue) || !MELLOW_VAULT.hasQueue(queue)) {
            return (false, 0);
        }
        (bool isSuspicious, uint256 priceD18, uint32 timestamp) = getUncheckedWstETHReport();
        if (isSuspicious || priceD18 == 0) return (false, 0);

        shares = Math.mulDiv(assets, priceD18, 1 ether);

        uint256 depositFeeD6 = MELLOW_FEE_MANAGER.depositFeeD6();
        if (depositFeeD6 != 0) {
            shares = Math.mulDiv(shares, 1e6 - depositFeeD6, 1e6);
        }

        if (supplyParams.isSync) {
            (uint256 penaltyD6, uint32 maxAge) = ISyncDepositQueue(queue).syncDepositParams();
            if (uint256(maxAge) + timestamp < block.timestamp) {
                return (false, 0);
            }
            if (penaltyD6 != 0) {
                shares = Math.mulDiv(shares, 1e6 - penaltyD6, 1e6);
            }
        } else {
            IDepositQueue depositQueue = IDepositQueue(queue);
            (uint256 requestTimestamp,) = depositQueue.requestOf(callForwarder);
            if (requestTimestamp != 0) {
                // NOTE: This check does not cover the edge case where `claimableShares == 0` due to rounding.
                // In that scenario, the user is expected to call `claimShares()` first.
                if (depositQueue.claimableOf(callForwarder) == 0) {
                    return (false, 0);
                }
            }
        }
        if (shares == 0) {
            return (false, 0);
        }
        return (true, shares);
    }

    /**
     * @notice Supplies assets to the strategy and deposits wstETH into the configured Mellow deposit queue.
     * @dev Workflow:
     * - Decode params (sync/async, optional whitelist proof)
     * - Ensure previewSupply is successful
     * - If msg.value > 0: deposit ETH to pool (mint stv to the user forwarder)
     * - Mint/obtain wstETH in pool for `assets`
     * - Approve queue and deposit into Mellow queue (via call forwarder)
     *
     * @param referral Referral address forwarded to the Mellow deposit queue.
     * @param assets Amount of wstETH to deposit (minted via pool).
     * @param params ABI-encoded MellowSupplyParams.
     * @return stv Amount of stv minted if ETH was supplied (0 if msg.value == 0).
     */
    function supply(address referral, uint256 assets, bytes calldata params) external payable returns (uint256 stv) {
        MellowSupplyParams memory supplyParams = abi.decode(params, (MellowSupplyParams));
        address msgSender = _msgSender();
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msgSender);

        (bool success, uint256 shares) = previewSupply(assets, msgSender, address(callForwarder), supplyParams);
        if (!success) {
            revert SupplyFailed();
        }

        if (msg.value > 0) {
            stv = StvStETHPool(payable(POOL)).depositETH{value: msg.value}(address(callForwarder), referral);
        }

        callForwarder.doCall(POOL, abi.encodeWithSelector(StvStETHPool.mintWsteth.selector, assets));

        address queue = supplyParams.isSync ? MELLOW_SYNC_DEPOSIT_QUEUE : MELLOW_ASYNC_DEPOSIT_QUEUE;
        callForwarder.doCall(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, queue, assets));
        callForwarder.doCall(
            queue, abi.encodeCall(IDepositQueue.deposit, (assets.toUint224(), referral, supplyParams.merkleProof))
        );

        emit StrategySupplied(msgSender, referral, msg.value, stv, assets, params);
        emit MellowDeposited(msgSender, referral, assets, supplyParams.isSync, shares, params);
    }

    /**
     * @notice Claims shares from the async deposit queue.
     * @dev Reverts if async deposit queue is not configured.
     * @return success True if the queue claim call succeeded.
     */
    function claimShares() external returns (bool success) {
        if (MELLOW_ASYNC_DEPOSIT_QUEUE == address(0)) {
            revert NoAsyncDepositQueue();
        }
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        success = IDepositQueue(MELLOW_ASYNC_DEPOSIT_QUEUE).claim(address(callForwarder));
    }

    // =================================================================================
    // REQUEST EXIT FROM STRATEGY
    // =================================================================================

    /**
     * @notice Previews how many shares are required to withdraw a given amount of assets (wstETH).
     * @dev Uses oracle price and applies redeem fee; rounds up to ensure sufficient shares.
     * @param assets Amount of wstETH desired to withdraw.
     * @return success Whether preview conditions are satisfied (feature not paused, queue active, oracle ok).
     * @return shares Estimated shares required (net of fees).
     */
    function previewWithdraw(uint256 assets) public view returns (bool success, uint256 shares) {
        if (isFeaturePaused(REDEEM_FEATURE)) return (false, 0);
        address queue = MELLOW_ASYNC_REDEEM_QUEUE;
        if (MELLOW_VAULT.isPausedQueue(queue) || !MELLOW_VAULT.hasQueue(queue)) {
            return (false, 0);
        }
        (bool isSuspicious, uint256 priceD18,) = getUncheckedWstETHReport();
        if (isSuspicious || priceD18 == 0) {
            return (false, 0);
        }

        shares = Math.mulDiv(assets, priceD18, 1 ether, Math.Rounding.Ceil);
        uint256 redeemFeeD6 = MELLOW_FEE_MANAGER.redeemFeeD6();
        if (redeemFeeD6 != 0) {
            shares = Math.mulDiv(shares, 1e6, 1e6 - redeemFeeD6, Math.Rounding.Ceil);
        }
        if (shares == 0) return (false, 0);
        return (true, shares);
    }

    /**
     * @notice Previews how many assets (wstETH) will be received for redeeming a given amount of shares.
     * @dev Uses oracle price and applies redeem fee.
     * @param shares Amount of Mellow shares to redeem.
     * @return success Whether preview conditions are satisfied (feature not paused, queue active, oracle ok).
     * @return assets Estimated wstETH received (net of fees).
     */
    function previewRedeem(uint256 shares) public view returns (bool success, uint256 assets) {
        if (isFeaturePaused(REDEEM_FEATURE)) return (false, 0);
        address queue = MELLOW_ASYNC_REDEEM_QUEUE;
        if (MELLOW_VAULT.isPausedQueue(queue) || !MELLOW_VAULT.hasQueue(queue)) {
            return (false, 0);
        }
        (bool isSuspicious, uint256 priceD18,) = getUncheckedWstETHReport();
        if (isSuspicious || priceD18 == 0) {
            return (false, 0);
        }

        assets = Math.mulDiv(shares, 1 ether, priceD18);
        uint256 redeemFeeD6 = MELLOW_FEE_MANAGER.redeemFeeD6();
        if (redeemFeeD6 != 0) {
            assets = Math.mulDiv(assets, 1e6 - redeemFeeD6, 1e6);
        }
        if (assets == 0) return (false, 0);
        return (true, assets);
    }

    /**
     * @notice Requests exit using a share amount.
     * @dev Computes expected assets via previewRedeem and then creates a redeem request.
     * @param shares Amount of Mellow shares to redeem.
     * @return requestId Encoded request id used for finalization.
     */
    function requestExitByShares(uint256 shares, bytes calldata) external returns (bytes32 requestId) {
        if (shares == 0) revert ZeroArgument("shares");
        (bool success, uint256 assets) = previewRedeem(shares);
        if (!success || assets == 0) revert RedeemFailed();
        return _requestExit(assets, shares);
    }

    /**
     * @notice Requests exit using a target wstETH amount.
     * @dev Computes required shares via previewWithdraw and then creates a redeem request.
     * @param assets Amount of wstETH desired to withdraw.
     * @return requestId Encoded request id used for finalization.
     */
    function requestExitByWsteth(uint256 assets, bytes calldata) external returns (bytes32 requestId) {
        if (assets == 0) revert ZeroArgument("assets");
        (bool success, uint256 shares) = previewWithdraw(assets);
        if (!success) revert WithdrawalFailed();
        return _requestExit(assets, shares);
    }

    function _requestExit(uint256 assets, uint256 shares) internal returns (bytes32 requestId) {
        address msgSender = _msgSender();
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msgSender);
        uint256 userShares = MELLOW_SHARE_MANAGER.sharesOf(address(callForwarder));
        if (shares > userShares) revert InsufficientMellowShares();

        address queue = MELLOW_ASYNC_REDEEM_QUEUE;
        callForwarder.doCall(queue, abi.encodeCall(IRedeemQueue.redeem, (shares)));
        // - If multiple exit requests are created within the same timestamp for the same user, they will be
        //   merged by the queue into one underlying request.
        // - This means there may be multiple `MellowWithdrawalRequested` (and `StrategyExitRequested`) events
        //   that share the same `requestId`, while a single `finalizeRequestExit(requestId)` can finalize
        //   the aggregated position and emit only one `StrategyExitFinalized`.
        requestId = bytes32(block.timestamp);

        emit StrategyExitRequested(msgSender, requestId, assets, new bytes(0));
        emit MellowWithdrawalRequested(msgSender, requestId, shares);
    }

    /**
     * @notice Finalizes an outstanding exit request by claiming assets from the Mellow redeem queue.
     * @dev Calls redeemQueue.claim() via forwarder. Emits StrategyExitFinalized with claimed assets.
     * @param requestId Encoded request id returned by requestExit*().
     */
    function finalizeRequestExit(bytes32 requestId) external {
        address msgSender = _msgSender();
        uint32 timestamp = uint32(uint256(requestId));

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msgSender);
        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = timestamp;
        bytes memory response = callForwarder.doCall(
            MELLOW_ASYNC_REDEEM_QUEUE, abi.encodeCall(IRedeemQueue.claim, (address(callForwarder), timestamps))
        );
        uint256 assets = abi.decode(response, (uint256));

        emit StrategyExitFinalized(_msgSender(), requestId, assets);
    }

    // =================================================================================
    // HELPERS
    // =================================================================================

    /**
     * @notice Returns the amount of minted stETH shares obligation for a user in the Pool.
     * @param _user User address.
     * @return mintedStethShares Minted stETH shares tracked by the pool for the user's call forwarder.
     */
    function mintedStethSharesOf(address _user) external view returns (uint256 mintedStethShares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        mintedStethShares = StvStETHPool(payable(POOL)).mintedStethSharesOf(address(callForwarder));
    }

    /**
     * @notice Returns remaining minting capacity in stETH shares for a user given ETH funding amount.
     * @param _user User address.
     * @param _ethToFund ETH amount intended to fund minting capacity calculation.
     * @return stethShares Remaining capacity measured in stETH shares.
     */
    function remainingMintingCapacitySharesOf(address _user, uint256 _ethToFund)
        external
        view
        returns (uint256 stethShares)
    {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        stethShares = StvStETHPool(payable(POOL)).remainingMintingCapacitySharesOf(address(callForwarder), _ethToFund);
    }

    /**
     * @notice Returns wstETH balance held by the user's call forwarder.
     * @param _user User address.
     * @return wsteth wstETH token balance.
     */
    function wstethOf(address _user) external view returns (uint256 wsteth) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        wsteth = WSTETH.balanceOf(address(callForwarder));
    }

    /**
     * @notice Returns stv balance held by the user's call forwarder in the Pool.
     * @param _user User address.
     * @return stv stv token balance.
     */
    function stvOf(address _user) external view returns (uint256 stv) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        stv = StvStETHPool(payable(POOL)).balanceOf(address(callForwarder));
    }

    /**
     * @notice Returns total shares (active + claimable) for a user.
     * @param _user The user to get the shares for.
     * @return shares The amount of shares.
     */
    function sharesOf(address _user) external view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.sharesOf(address(callForwarder));
    }

    /**
     * @notice Returns claimable shares for a user.
     * @param _user The user to get the claimable shares for.
     * @return shares The amount of claimable shares.
     */
    function claimableSharesOf(address _user) public view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.claimableSharesOf(address(callForwarder));
    }

    /**
     * @notice Returns active shares for a user.
     * @param _user The user to get the active shares for.
     * @return shares The amount of active shares.
     */
    function activeSharesOf(address _user) external view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.activeSharesOf(address(callForwarder));
    }

    /**
     * @notice Returns async deposit request state for a user (if async deposit queue is configured).
     * @param _user User address.
     * @return assets Requested assets amount.
     * @return timestamp Request timestamp as stored in the queue.
     * @return isClaimable True if the request is claimable (queue reports non-zero claimable shares).
     */
    function pendingDepositRequests(address _user)
        external
        view
        returns (uint256 assets, uint256 timestamp, bool isClaimable)
    {
        if (MELLOW_ASYNC_DEPOSIT_QUEUE == address(0)) return (0, 0, false);
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        (timestamp, assets) = IDepositQueue(MELLOW_ASYNC_DEPOSIT_QUEUE).requestOf(address(callForwarder));
        if (assets > 0 && IDepositQueue(MELLOW_ASYNC_DEPOSIT_QUEUE).claimableOf(address(callForwarder)) != 0) {
            isClaimable = true;
        }
    }

    /**
     * @notice Returns the current oracle report for wstETH without performing extra validation.
     * @dev Consumers typically check isSuspicious and priceD18 != 0.
     * @return isSuspicious Whether the oracle report is flagged as suspicious.
     * @return priceD18 Price in 1e18 precision.
     * @return timestamp Report timestamp.
     */
    function getUncheckedWstETHReport() public view returns (bool isSuspicious, uint256 priceD18, uint32 timestamp) {
        IOracle.DetailedReport memory report = MELLOW_ORACLE.getReport(address(WSTETH));
        return (report.isSuspicious, report.priceD18, report.timestamp);
    }

    /**
     * @notice Returns redeem queue requests stored on the Mellow redeem queue for the user's call forwarder.
     * @param account User address.
     * @param offset Pagination offset.
     * @param limit Pagination limit.
     * @return Array of redeem queue request structs.
     */
    function getRedeemQueueRequests(address account, uint256 offset, uint256 limit)
        external
        view
        returns (IRedeemQueue.Request[] memory)
    {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(account);
        return IRedeemQueue(MELLOW_ASYNC_REDEEM_QUEUE).requestsOf(address(callForwarder), offset, limit);
    }

    // =================================================================================
    // REQUEST WITHDRAWAL FROM POOL
    // =================================================================================

    /**
     * @notice Requests withdrawal from the underlying Pool WithdrawalQueue.
     * @dev Call is executed via the caller's StrategyCallForwarder.
     * @param _recipient Recipient that will receive withdrawal proceeds (as defined by WithdrawalQueue semantics).
     * @param _stvToWithdraw Amount of stv to withdraw.
     * @param _stethSharesToRebalance Amount of stETH shares to rebalance in the pool during withdrawal.
     * @return requestId Withdrawal request id returned by WithdrawalQueue.
     */
    function requestWithdrawalFromPool(address _recipient, uint256 _stvToWithdraw, uint256 _stethSharesToRebalance)
        external
        returns (uint256 requestId)
    {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());

        // request withdrawal from pool
        bytes memory withdrawalData = callForwarder.doCall(
            address(StvStETHPool(payable(POOL)).WITHDRAWAL_QUEUE()),
            abi.encodeWithSelector(
                WithdrawalQueue.requestWithdrawal.selector, _recipient, _stvToWithdraw, _stethSharesToRebalance
            )
        );
        requestId = abi.decode(withdrawalData, (uint256));
    }

    /**
     * @notice Burns wstETH to reduce the user's minted stETH obligation in the Pool.
     * @dev Call is executed via the caller's StrategyCallForwarder.
     * @param _wstethToBurn The amount of wstETH to burn.
     */
    function burnWsteth(uint256 _wstethToBurn) external {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.doCall(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, POOL, _wstethToBurn));
        callForwarder.doCall(POOL, abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
    }

    /**
     * @notice Transfers ERC20 tokens from the caller's StrategyCallForwarder to a recipient.
     * @dev Intended as a recovery method for tokens stuck on the forwarder (adminless per-user action).
     * @param _token The token to transfer (must be non-zero).
     * @param _recipient The recipient of the tokens (must be non-zero).
     * @param _amount The amount of tokens to transfer (must be non-zero).
     */
    function safeTransferERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.safeTransferERC20(_token, _recipient, _amount);
    }
}
