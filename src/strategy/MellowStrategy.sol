// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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

contract MellowStrategy is
    IStrategy,
    AccessControlEnumerableUpgradeable,
    FeaturePausable,
    StrategyCallForwarderRegistry
{
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct MellowSupplyParams {
        bool isSync;
        bytes32[] merkleProof;
    }

    // Constants
    // ACL
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    bytes32 public constant REDEEM_FEATURE = keccak256("REDEEM_FEATURE");
    bytes32 public constant REDEEM_PAUSE_ROLE = keccak256("REDEEM_PAUSE_ROLE");
    bytes32 public constant REDEEM_RESUME_ROLE = keccak256("REDEEM_RESUME_ROLE");

    // Immutables
    address public immutable POOL;
    IWstETH public immutable WSTETH;

    IVault public immutable MELLOW_VAULT;
    IFeeManager public immutable MELLOW_FEE_MANAGER;
    IOracle public immutable MELLOW_ORACLE;
    IShareManager public immutable MELLOW_SHARE_MANAGER;

    address public immutable MELLOW_SYNC_DEPOSIT_QUEUE;
    address public immutable MELLOW_ASYNC_DEPOSIT_QUEUE;
    address public immutable MELLOW_ASYNC_REDEEM_QUEUE;

    // Variables
    mapping(address => EnumerableSet.Bytes32Set) private _requests;

    // Events
    event MellowDeposited(
        address indexed recipient,
        address indexed referralAddress,
        uint256 wstethAmount,
        bool isSync,
        uint256 shares,
        bytes params
    );
    event MellowWithdrawalRequested(address indexed recipient, bytes32 requestId, uint256 shares);

    // Errors
    error ZeroArgument(string name);
    error InvalidQueue(string name);
    error SuspiciousReport();
    error InsufficientMellowShares();
    error WithdrawalFailed();
    error RedeemFailed();
    error SupplyFailed();
    error RequestIdNotFound();
    error ZeroShares();

    constructor(
        bytes32 strategyId_,
        address strategyCallForwarderImpl_,
        address pool_,
        IVault vault_,
        address syncDepositQueue_,
        address asyncDepositQueue_,
        address asyncRedeemQueue_
    ) StrategyCallForwarderRegistry(strategyId_, strategyCallForwarderImpl_) {
        address wsteth = address(StvStETHPool(payable(pool_)).WSTETH());
        if (asyncDepositQueue_ == address(0) && syncDepositQueue_ == address(0)) {
            revert ZeroArgument("depositQueue");
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
     * @inheritdoc IStrategy
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
     * @notice Pause supply
     */
    function pauseSupply() external onlyRole(SUPPLY_PAUSE_ROLE) {
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Resume supply
     */
    function resumeSupply() external onlyRole(SUPPLY_RESUME_ROLE) {
        _resumeFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Pause redeem
     */
    function pauseRedeem() external onlyRole(REDEEM_PAUSE_ROLE) {
        _pauseFeature(REDEEM_FEATURE);
    }

    /**
     * @notice Resume redeem
     */
    function resumeRedeem() external onlyRole(REDEEM_RESUME_ROLE) {
        _resumeFeature(REDEEM_FEATURE);
    }

    // =================================================================================
    // SUPPLY
    // =================================================================================

    function previewSupply(uint256 assets, MellowSupplyParams memory supplyParams)
        public
        view
        returns (bool success, uint256 shares)
    {
        if (isFeaturePaused(SUPPLY_FEATURE)) return (false, 0);
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

        uint256 depositFeeD6 = MELLOW_VAULT.feeManager().depositFeeD6();
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
        }
        if (shares == 0) {
            return (false, 0);
        }
        return (true, shares);
    }

    /**
     * @inheritdoc IStrategy
     */
    function supply(address referral, uint256 assets, bytes calldata params) external payable returns (uint256 stv) {
        MellowSupplyParams memory supplyParams = abi.decode(params, (MellowSupplyParams));
        (bool success, uint256 shares) = previewSupply(assets, supplyParams);
        if (!success) {
            revert SupplyFailed();
        }

        address msgSender = _msgSender();
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msgSender);
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

    function claimShares() external returns (bool success) {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        success = IDepositQueue(MELLOW_ASYNC_DEPOSIT_QUEUE).claim(address(callForwarder));
    }

    // =================================================================================
    // REQUEST EXIT FROM STRATEGY
    // =================================================================================

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
        uint256 redeemFeeD6 = MELLOW_VAULT.feeManager().redeemFeeD6();
        if (redeemFeeD6 != 0) {
            shares = Math.mulDiv(shares, 1e6, 1e6 - redeemFeeD6, Math.Rounding.Ceil);
        }
        if (shares == 0) return (false, 0);
        return (true, shares);
    }

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
        uint256 redeemFeeD6 = MELLOW_VAULT.feeManager().redeemFeeD6();
        if (redeemFeeD6 != 0) {
            assets = Math.mulDiv(assets, 1e6, 1e6 - redeemFeeD6);
        }
        if (assets == 0) return (false, 0);
        return (true, assets);
    }

    function requestExitByShares(uint256 shares, bytes calldata) external returns (bytes32 requestId) {
        (bool success, uint256 assets) = previewRedeem(shares);
        if (!success || assets == 0) revert RedeemFailed();
        return _requestExit(assets, shares);
    }

    /**
     * @inheritdoc IStrategy
     */
    function requestExitByWsteth(uint256 assets, bytes calldata) external returns (bytes32 requestId) {
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
        requestId = bytes32(bytes20(queue)) | bytes32(uint256(uint32(block.timestamp)));

        // ignore response in case of multiple requests in a single block
        _requests[msgSender].add(requestId);

        emit StrategyExitRequested(msgSender, requestId, assets, new bytes(0));
        emit MellowWithdrawalRequested(msgSender, requestId, shares);
    }

    /**
     * @inheritdoc IStrategy
     */
    function finalizeRequestExit(bytes32 requestId) external {
        address msgSender = _msgSender();
        if (!_requests[msgSender].remove(requestId)) {
            revert RequestIdNotFound();
        }
        address redeemQueue = address(bytes20(requestId));
        uint32 timestamp = uint32(uint256(requestId));

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(msgSender);
        uint32[] memory timestamps = new uint32[](1);
        timestamps[0] = timestamp;
        bytes memory response =
            callForwarder.doCall(redeemQueue, abi.encodeCall(IRedeemQueue.claim, (address(callForwarder), timestamps)));
        uint256 assets = abi.decode(response, (uint256));

        emit StrategyExitFinalized(_msgSender(), requestId, assets);
    }

    // =================================================================================
    // HELPERS
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function mintedStethSharesOf(address _user) external view returns (uint256 mintedStethShares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        mintedStethShares = StvStETHPool(payable(POOL)).mintedStethSharesOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
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
     * @inheritdoc IStrategy
     */
    function wstethOf(address _user) external view returns (uint256 wsteth) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        wsteth = WSTETH.balanceOf(address(callForwarder));
    }

    /**
     * @inheritdoc IStrategy
     */
    function stvOf(address _user) external view returns (uint256 stv) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        stv = StvStETHPool(payable(POOL)).balanceOf(address(callForwarder));
    }

    /**
     * @notice Returns the amount of shares of a user
     * @param _user The user to get the shares for
     * @return shares The amount of shares
     */
    function sharesOf(address _user) external view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.sharesOf(address(callForwarder));
    }

    /**
     * @notice Returns the amount of claimable shares of a user
     * @param _user The user to get the claimable shares for
     * @return shares The amount of claimable shares
     */
    function claimableSharesOf(address _user) public view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.claimableSharesOf(address(callForwarder));
    }

    /**
     * @notice Returns the amount of active shares of a user
     * @param _user The user to get the active shares for
     * @return shares The amount of active shares
     */
    function activeSharesOf(address _user) external view returns (uint256 shares) {
        IStrategyCallForwarder callForwarder = getStrategyCallForwarderAddress(_user);
        shares = MELLOW_SHARE_MANAGER.activeSharesOf(address(callForwarder));
    }

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

    function getUncheckedWstETHReport() public view returns (bool isSuspicious, uint256 priceD18, uint32 timestamp) {
        IOracle.DetailedReport memory report = MELLOW_ORACLE.getReport(address(WSTETH));
        return (report.isSuspicious, report.priceD18, report.timestamp);
    }

    function getRedeemRequestCount(address account) external view returns (uint256) {
        return _requests[account].length();
    }

    function getRedeemRequestAt(address account, uint256 index)
        external
        view
        returns (bytes32 requestId, address redeemQueue, uint32 timestamp)
    {
        EnumerableSet.Bytes32Set storage set = _requests[account];
        if (set.length() <= index) {
            revert RequestIdNotFound();
        }
        requestId = set.at(index);
        redeemQueue = address(bytes20(requestId));
        timestamp = uint32(uint256(requestId));
    }

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
     * @inheritdoc IStrategy
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
     * @notice Burns wstETH to reduce the user's minted stETH obligation
     * @param _wstethToBurn The amount of wstETH to burn
     */
    function burnWsteth(uint256 _wstethToBurn) external {
        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.doCall(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, POOL, _wstethToBurn));
        callForwarder.doCall(POOL, abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
    }

    /**
     * @notice Transfers ERC20 tokens from the call forwarder
     * @param _token The token to recover
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to recover
     */
    function safeTransferERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IStrategyCallForwarder callForwarder = _getOrCreateCallForwarder(_msgSender());
        callForwarder.safeTransferERC20(_token, _recipient, _amount);
    }
}
