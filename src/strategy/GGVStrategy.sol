// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {StrategyCallForwarderRegistry} from "src/strategy/StrategyCallForwarderRegistry.sol";
import {FeaturePausable} from "src/utils/FeaturePausable.sol";

import {IStETH} from "src/interfaces/IStETH.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";

contract GGVStrategy is IStrategy, AccessControlEnumerableUpgradeable, FeaturePausable, StrategyCallForwarderRegistry {
    StvStETHPool private immutable POOL_;
    IWstETH public immutable WSTETH;

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    // ACL
    bytes32 public constant SUPPLY_FEATURE = keccak256("SUPPLY_FEATURE");
    bytes32 public constant SUPPLY_PAUSE_ROLE = keccak256("SUPPLY_PAUSE_ROLE");
    bytes32 public constant SUPPLY_RESUME_ROLE = keccak256("SUPPLY_RESUME_ROLE");

    struct GGVParamsSupply {
        uint16 minimumMint;
    }

    struct GGVParamsRequestExit {
        uint16 discount;
        uint24 secondsToDeadline;
    }

    event GGVDeposited(
        address indexed recipient, uint256 wstethAmount, uint256 ggvShares, address referralAddress, bytes data
    );
    event GGVWithdrawalRequested(address indexed recipient, bytes32 requestId, uint128 requestedGGV, bytes data);

    error ZeroArgument(string name);
    error InvalidSender();
    error InvalidWstethAmount();
    error InvalidGGVAmount();
    error NotImplemented();

    constructor(
        bytes32 _strategyId,
        address _strategyCallForwarderImpl,
        address _pool,
        address _teller,
        address _boringQueue
    ) StrategyCallForwarderRegistry(_strategyId, _strategyCallForwarderImpl) {
        POOL_ = StvStETHPool(payable(_pool));
        WSTETH = IWstETH(POOL_.WSTETH());

        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);

        _disableInitializers();
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Initialize the contract storage explicitly
     * @param _admin Admin address that can change every role
     * @dev Reverts if `_admin` equals to `address(0)`
     */
    function initialize(address _admin) external initializer {
        if (_admin == address(0)) revert ZeroArgument("_admin");

        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @inheritdoc IStrategy
     */
    function POOL() external view returns (address) {
        return address(POOL_);
    }

    // =================================================================================
    // PAUSE / RESUME
    // =================================================================================

    /**
     * @notice Pause withdrawal requests placement and finalization
     * @dev Does not affect claiming of already finalized requests
     */
    function pause() external {
        _checkRole(SUPPLY_PAUSE_ROLE, msg.sender);
        _pauseFeature(SUPPLY_FEATURE);
    }

    /**
     * @notice Resume withdrawal requests placement and finalization
     */
    function resume() external {
        _checkRole(SUPPLY_RESUME_ROLE, msg.sender);
        _resumeFeature(SUPPLY_FEATURE);
    }

    // =================================================================================
    // SUPPLY
    // =================================================================================

    /**
     * @notice Supplies wstETH to the strategy
     * @param _referral The referral address
     * @param _wstethToMint The amount of wstETH to mint
     * @param _params The parameters for the supply
     */
    function supply(address _referral, uint256 _wstethToMint, bytes calldata _params) external payable {
        _checkFeatureNotPaused(SUPPLY_FEATURE);

        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(_getOrCreateCallForwarder(msg.sender));
        uint256 stv;

        if (msg.value > 0) {
            POOL_.depositETH{value: msg.value}(address(callForwarder), _referral);
        }

        callForwarder.call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), type(uint256).max));
        callForwarder.call(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, _wstethToMint));
        callForwarder.call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, TELLER.vault(), _wstethToMint));

        GGVParamsSupply memory params = abi.decode(_params, (GGVParamsSupply));

        bytes memory data = callForwarder.call(
                address(TELLER),
                abi.encodeWithSelector(
                    TELLER.deposit.selector, address(WSTETH), _wstethToMint, params.minimumMint, _referral
                )
            );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit StrategySupplied(msg.sender, msg.value, stv, _wstethToMint, _params);
        emit GGVDeposited(msg.sender, _wstethToMint, ggvShares, _referral, _params);
    }

    // =================================================================================
    // REQUEST EXIT FROM STRATEGY
    // =================================================================================

    /**
     * @notice Requests a withdrawal of ggv shares from the strategy
     * @param _stethAmount The amount of stETH to withdraw
     * @param _params The parameters for the withdrawal
     * @return requestId The request id
     */
    function requestExitByStETH(uint256 _stethAmount, bytes calldata _params) external returns (bytes32 requestId) {
        uint256 wstethToBurn = WSTETH.getWstETHByStETH(_stethAmount);
        requestId = requestExitByWsteth(wstethToBurn, _params);
    }

    /**
     * @notice Previews the amount of wstETH that can be withdrawn by a given amount of GGV shares
     * @param _user The user to preview the amount of wstETH for
     * @param _ggvShares The amount of GGV shares to preview the amount of wstETH for
     * @param _params The parameters for the withdrawal
     * @return wsteth The amount of wstETH that can be withdrawn
     */
    function previewWstethByGGV(address _user, uint256 _ggvShares, bytes calldata _params)
        external
        view
        returns (uint256 wsteth)
    {
        address callForwarder = getStrategyCallForwarderAddress(_user);

        GGVParamsRequestExit memory params = abi.decode(_params, (GGVParamsRequestExit));

        IERC20 boringVault = IERC20(TELLER.vault());
        uint256 totalGGV = boringVault.balanceOf(callForwarder);

        if (totalGGV == 0) return 0;
        if (_ggvShares > totalGGV) revert InvalidGGVAmount();

        uint256 totalWstethFromGgv =
            BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        wsteth = Math.mulDiv(_ggvShares, totalWstethFromGgv, totalGGV);
    }

    /**
     * @notice Requests a withdrawal of ggv shares from the strategy
     * @param _wstethToBurn The amount of wsteth to burn
     * @param _params The parameters for the withdrawal
     * @return requestId The request id
     */
    function requestExitByWsteth(uint256 _wstethToBurn, bytes calldata _params)
        public
        returns (bytes32 requestId)
    {
        GGVParamsRequestExit memory params = abi.decode(_params, (GGVParamsRequestExit));

        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(_getOrCreateCallForwarder(msg.sender));
        IERC20 boringVault = IERC20(TELLER.vault());

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 totalGGV = boringVault.balanceOf(address(callForwarder));
        uint256 totalWstethFromGgv =
            BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        if (totalWstethFromGgv == 0) revert InvalidWstethAmount();
        if (_wstethToBurn > totalWstethFromGgv) revert InvalidWstethAmount();

        // Approve GGV shares
        uint256 ggvShares = Math.mulDiv(totalGGV, _wstethToBurn, totalWstethFromGgv);
        callForwarder.call(
                address(boringVault),
                abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
            );

        uint128 requestedGGV = uint128(ggvShares);

        // Withdrawal request from GGV
        bytes memory data = callForwarder.call(
                address(BORING_QUEUE),
                abi.encodeWithSelector(
                    BORING_QUEUE.requestOnChainWithdraw.selector,
                    address(WSTETH),
                    requestedGGV,
                    params.discount,
                    params.secondsToDeadline
                )
            );
        requestId = abi.decode(data, (bytes32));

        emit StrategyExitRequested(msg.sender, requestId, _wstethToBurn, _params);
        emit GGVWithdrawalRequested(msg.sender, requestId, requestedGGV, _params);
    }

    /**
     * @notice Finalizes a withdrawal from the strategy
     */
    function finalizeRequestExit(
        address /* _receiver */,
        bytes32 /* _requestId */
    )
        external
        pure
    {
        // GGV does not provide a way to check request status, so we cannot verify if the request
        // was actually finalized in GGV Queue. Additionally, GGV allows multiple withdrawal requests,
        // so it's possible to have request->finalize->request sequence where 2 unfinalised requests
        // exist in GGV at the same time.
        revert NotImplemented();
    }

    // =================================================================================
    // CANCEL / REPLACE GGV REQUEST
    // =================================================================================

    /**
     * @notice Cancels a withdrawal request
     * @param request The request to cancel
     */
    function cancelGgvRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(getStrategyCallForwarderAddress(msg.sender));
        if (address(callForwarder) != request.user) revert InvalidSender();

        callForwarder.call(address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request));
    }

    /**
     * @notice Replaces a withdrawal request
     * @param request The request to replace
     * @param discount The discount to use
     * @param secondsToDeadline The deadline to use
     * @return oldRequestId The old request id
     * @return newRequestId The new request id
     */
    function replaceGgvOnChainWithdraw(
        IBoringOnChainQueue.OnChainWithdraw memory request,
        uint16 discount,
        uint24 secondsToDeadline
    ) external returns (bytes32 oldRequestId, bytes32 newRequestId) {
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(getStrategyCallForwarderAddress(msg.sender));
        if (address(callForwarder) != request.user) revert InvalidSender();

        bytes memory data = callForwarder.call(
                address(BORING_QUEUE),
                abi.encodeWithSelector(
                    BORING_QUEUE.replaceOnChainWithdraw.selector, request, discount, secondsToDeadline
                )
            );
        (oldRequestId, newRequestId) = abi.decode(data, (bytes32, bytes32));
    }

    // =================================================================================
    // HELPERS
    // =================================================================================

    /**
     * @inheritdoc IStrategy
     */
    function mintedStethSharesOf(address _user) external view returns (uint256 mintedStethShares) {
        address callForwarder = getStrategyCallForwarderAddress(_user);
        mintedStethShares = POOL_.mintedStethSharesOf(callForwarder);
    }

    /**
     * @inheritdoc IStrategy
     */
    function wstethOf(address _user) external view returns (uint256 wsteth) {
        address callForwarder = getStrategyCallForwarderAddress(_user);
        wsteth = WSTETH.balanceOf(callForwarder);
    }

    /**
     * @inheritdoc IStrategy
     */
    function stvOf(address _user) external view returns (uint256 stv) {
        address callForwarder = getStrategyCallForwarderAddress(_user);
        stv = POOL_.balanceOf(callForwarder);
    }

    // =================================================================================
    // REQUEST WITHDRAWAL FROM POOL
    // =================================================================================

    /**
     * @notice Requests a withdrawal from the Withdrawal Queue
     * @param _stvToWithdraw The amount of stv to withdraw
     * @param _stethSharesToRebalance The amount of stETH shares to rebalance
     * @param _receiver The address to receive the stv
     * @return requestId The Withdrawal Queue request ID
     */
    function requestWithdrawalFromPool(uint256 _stvToWithdraw, uint256 _stethSharesToRebalance, address _receiver)
        external
        returns (uint256 requestId)
    {
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(_getOrCreateCallForwarder(msg.sender));

        // request withdrawal from pool
        bytes memory withdrawalData = callForwarder.call(
                address(POOL_.WITHDRAWAL_QUEUE()),
                abi.encodeWithSelector(
                    WithdrawalQueue.requestWithdrawal.selector, _receiver, _stvToWithdraw, _stethSharesToRebalance
                )
            );
        requestId = abi.decode(withdrawalData, (uint256));
    }

    /**
     * @notice Burns wstETH to reduce the user's minted stETH obligation
     * @param _wstethToBurn The amount of wstETH to burn
     */
    function burnWsteth(uint256 _wstethToBurn) external {
        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(getStrategyCallForwarderAddress(msg.sender));
        callForwarder.call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), _wstethToBurn));
        callForwarder.call(address(POOL_), abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
    }

    // =================================================================================
    // RECOVERY
    // =================================================================================

    /**
     * @notice Recovers ERC20 tokens from the call forwarder
     * @param _token The token to recover
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to recover
     */
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        IStrategyCallForwarder callForwarder = IStrategyCallForwarder(getStrategyCallForwarderAddress(msg.sender));
        callForwarder.call(_token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }
}
