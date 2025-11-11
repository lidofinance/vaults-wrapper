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
import {CallForwarder} from "src/strategy/libraries/CallForwarder.sol";
import {FeaturePausable} from "src/utils/FeaturePausable.sol";

import {IStETH} from "src/interfaces/IStETH.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";

contract GGVStrategy is IStrategy, AccessControlEnumerableUpgradeable, FeaturePausable, CallForwarder {
    
    StvStETHPool private immutable POOL_;
    IStETH public immutable STETH;
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

    error InvalidSender();
    error InvalidStethAmount();
    error NotImplemented();
    error InvalidGGVAmount();
    error ZeroArgument(string name);

    constructor(
        bytes32 _strategyId,
        address _strategyCallForwarderImpl,
        address _pool,
        address _stETH,
        address _wstETH,
        address _teller,
        address _boringQueue
    ) CallForwarder(_strategyId, _strategyCallForwarderImpl) {

        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        POOL_ = StvStETHPool(payable(_pool));

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

        address callForwarder = _getOrCreateCallForwarder(msg.sender);
        uint256 stv;
        
        if (msg.value > 0) {
            POOL_.depositETH{value: msg.value}(callForwarder, _referral);
        }

        IStrategyCallForwarder(callForwarder)
            .call(address(STETH), abi.encodeWithSelector(STETH.approve.selector, address(POOL_), type(uint256).max));
        IStrategyCallForwarder(callForwarder)
            .call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), type(uint256).max));

        IStrategyCallForwarder(callForwarder)
            .call(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, _wstethToMint));

        IStrategyCallForwarder(callForwarder)
            .call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, TELLER.vault(), _wstethToMint));

        GGVParamsSupply memory params = abi.decode(_params, (GGVParamsSupply));

        bytes memory data = IStrategyCallForwarder(callForwarder)
            .call(
                address(TELLER),
                abi.encodeWithSelector(
                    TELLER.deposit.selector, address(WSTETH), _wstethToMint, params.minimumMint, _referral
                )
            );
        uint256 ggvShares = abi.decode(data, (uint256));

        uint256 stethAmount = STETH.getPooledEthByShares(_wstethToMint);

        emit StrategySupplied(msg.sender, stv, _wstethToMint, stethAmount, _params);
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
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        requestId = requestExitByStethShares(stethSharesToBurn, _params);
    }

    /**
     * @notice Previews the amount of stETH shares that can be withdrawn by a given amount of GGV shares
     * @param _user The user to preview the amount of stETH shares for
     * @param _ggvShares The amount of GGV shares to preview the amount of stETH shares for
     * @param _params The parameters for the withdrawal
     * @return stethShares The amount of stETH shares that can be withdrawn
     */
    function previewStethSharesByGGV(address _user, uint256 _ggvShares, bytes calldata _params)
        external
        view
        returns (uint256 stethShares)
    {
        address callForwarder = getStrategyCallForwarderAddress(_user);

        GGVParamsRequestExit memory params = abi.decode(_params, (GGVParamsRequestExit));

        IERC20 boringVault = IERC20(TELLER.vault());
        uint256 totalGGV = boringVault.balanceOf(callForwarder);

        if (totalGGV == 0) return 0;
        if (_ggvShares > totalGGV) revert InvalidGGVAmount();

        uint256 totalStethSharesFromGgv =
            BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        stethShares = Math.mulDiv(_ggvShares, totalStethSharesFromGgv, totalGGV);
    }

    /**
     * @notice Requests a withdrawal of ggv shares from the strategy
     * @param _stethSharesToBurn The amount of steth shares to burn
     * @param _params The parameters for the withdrawal
     * @return requestId The request id
     */
    function requestExitByStethShares(uint256 _stethSharesToBurn, bytes calldata _params)
        public
        returns (bytes32 requestId)
    {
        GGVParamsRequestExit memory params = abi.decode(_params, (GGVParamsRequestExit));

        address callForwarder = _getOrCreateCallForwarder(msg.sender);
        IERC20 boringVault = IERC20(TELLER.vault());

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 totalGGV = boringVault.balanceOf(callForwarder);
        uint256 totalStethSharesFromGgv =
            BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        if (totalStethSharesFromGgv == 0) revert InvalidStethAmount();
        if (_stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        // Approve GGV shares
        uint256 ggvShares = Math.mulDiv(totalGGV, _stethSharesToBurn, totalStethSharesFromGgv);
        IStrategyCallForwarder(callForwarder)
            .call(
                address(boringVault),
                abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
            );

        uint128 requestedGGV = uint128(ggvShares);

        // Withdrawal request from GGV
        bytes memory data = IStrategyCallForwarder(callForwarder)
            .call(
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

        emit StrategyExitRequested(msg.sender, requestId, _stethSharesToBurn, _params);
        emit GGVWithdrawalRequested(msg.sender, requestId, requestedGGV, _params);
    }

    /**
     * @notice Finalizes a withdrawal from the strategy
     */
    function finalizeRequestExit(
        address,
        /*_receiver*/
        bytes32 /*_requestId*/
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
        address callForwarder = getStrategyCallForwarderAddress(msg.sender);
        if (callForwarder != request.user) revert InvalidSender();

        IStrategyCallForwarder(callForwarder)
            .call(address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request));
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
        address callForwarder = getStrategyCallForwarderAddress(msg.sender);
        if (callForwarder != request.user) revert InvalidSender();

        bytes memory data = IStrategyCallForwarder(callForwarder)
            .call(
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
    function requestWithdrawalFromPool(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToRebalance,
        address _receiver
    ) external returns (uint256 requestId) {
        address callForwarder = _getOrCreateCallForwarder(msg.sender);

        // request withdrawal from pool
        bytes memory withdrawalData = IStrategyCallForwarder(callForwarder)
            .call(
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
        address callForwarder = getStrategyCallForwarderAddress(msg.sender);
        IStrategyCallForwarder(callForwarder)
            .call(address(WSTETH), abi.encodeWithSelector(WSTETH.approve.selector, address(POOL_), _wstethToBurn));
        IStrategyCallForwarder(callForwarder)
            .call(address(POOL_), abi.encodeWithSelector(StvStETHPool.burnWsteth.selector, _wstethToBurn));
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

        address proxy = getStrategyCallForwarderAddress(msg.sender);

        IStrategyCallForwarder(proxy)
            .call(address(STETH), abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }
}
