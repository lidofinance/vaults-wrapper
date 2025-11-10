// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {Strategy} from "src/strategy/Strategy.sol";

contract GGVStrategy is Strategy {
    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    // ==================== Events ====================

    event GGVDeposited(
        address indexed recipient, uint256 wstethAmount, uint256 ggvShares, address referralAddress, bytes data
    );
    event GGVWithdrawalRequested(address indexed recipient, bytes32 requestId, uint128 requestedGGV, bytes data);

    // ==================== Errors ====================

    error InvalidSender();
    error InvalidStethAmount();
    error AlreadyRequested();
    error InvalidRequestId();
    error NotImplemented();
    error InvalidGGVAmount();

    struct GGVParamsSupply {
        uint16 minimumMint;
    }

    struct GGVParamsRequestExit {
        uint16 discount;
        uint24 secondsToDeadline;
    }

    constructor(
        address _strategyCallForwarderImplementation,
        address _pool,
        address _stETH,
        address _wstETH,
        address _teller,
        address _boringQueue
    ) Strategy(_pool, _stETH, _wstETH, _strategyCallForwarderImplementation) {
        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);
    }

    /// @notice Supplies wstETH to the strategy
    /// @param _referral The referral address
    /// @param _wstethToMint The amount of wstETH to mint
    /// @param _params The parameters for the supply
    function supply(address _referral, uint256 _wstethToMint, bytes calldata _params) external payable {
        _requireNotPaused();

        address callForwarder = _getOrCreateCallForwarder(msg.sender);
        uint256 stv = POOL_.depositETH{value: msg.value}(callForwarder, _referral);

        if (_wstethToMint != 0) {
            IStrategyCallForwarder(callForwarder)
                .call(address(POOL_), abi.encodeWithSelector(POOL_.mintWsteth.selector, _wstethToMint));
        }

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

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _stethAmount The amount of stETH to withdraw
    /// @return requestId The request id
    function requestExitByStETH(uint256 _stethAmount, bytes calldata _params) external returns (bytes32 requestId) {
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        requestId = requestExitByStethShares(stethSharesToBurn, _params);
    }

    /// @notice Previews the amount of stETH shares that can be withdrawn by a given amount of GGV shares
    /// @param _user The user to preview the amount of stETH shares for
    /// @param _ggvShares The amount of GGV shares to preview the amount of stETH shares for
    /// @param _params The parameters for the withdrawal
    /// @return stethShares The amount of stETH shares that can be withdrawn
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

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _stethSharesToBurn The amount of steth shares to burn
    /// @param _params The parameters for the withdrawal
    /// @return requestId The request id
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

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelGgvRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        address callForwarder = getStrategyCallForwarderAddress(msg.sender);
        if (callForwarder != request.user) revert InvalidSender();

        IStrategyCallForwarder(callForwarder)
            .call(address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request));
    }

    /// @notice Replaces a withdrawal request
    /// @param request The request to replace
    /// @param discount The discount to use
    /// @param secondsToDeadline The deadline to use
    /// @return oldRequestId The old request id
    /// @return newRequestId The new request id
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

    /// @notice Finalizes a withdrawal from the strategy
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

    /// @notice Returns the amount of stETH shares of a user
    /// @param _user The user to get the stETH shares for
    /// @return stethShares The amount of stETH shares
    function proxyStethSharesOf(address _user) public view returns (uint256 stethShares) {
        address callForwarder = getStrategyCallForwarderAddress(_user);

        // simulate the unwrapping of wstETH to stETH with rounding issue
        uint256 wstethAmount = WSTETH.balanceOf(callForwarder);
        uint256 stETHAmount = STETH.getPooledEthByShares(wstethAmount);
        uint256 sharesAfterUnwrapping = STETH.getSharesByPooledEth(stETHAmount);

        // add the stETH shares of the call forwarder
        stethShares = sharesAfterUnwrapping + STETH.sharesOf(callForwarder);
    }

    /// @notice Calculates the amount of stETH shares to rebalance
    /// @param _user The user to calculate the amount of stETH shares to rebalance for
    /// @return stethShares The amount of stETH shares to rebalance
    function proxyStethSharesToRebalance(address _user) external view returns (uint256 stethShares) {
        address callForwarder = getStrategyCallForwarderAddress(_user);
        uint256 mintedStethShares = POOL_.mintedStethSharesOf(callForwarder);

        uint256 sharesAfterUnwrapping = proxyStethSharesOf(_user);

        if (mintedStethShares > sharesAfterUnwrapping) {
            stethShares = mintedStethShares - sharesAfterUnwrapping;
        }
    }

    /// @notice Calculates the amount of stv that can be withdrawn
    /// @param _user The user to calculate the amount of stv to withdraw for
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @return stv The amount of stv that can be withdrawn
    function proxyUnlockedStvOf(address _user, uint256 _stethSharesToBurn) external view returns (uint256 stv) {
        address callForwarder = getStrategyCallForwarderAddress(_user);
        stv = POOL_.unlockedStvOf(callForwarder, _stethSharesToBurn);
    }

    /// @notice Requests a withdrawal from the Withdrawal Queue
    /// @param _stvToWithdraw The amount of stv to withdraw
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @param _stethSharesToRebalance The amount of stETH shares to rebalance
    /// @param _receiver The address to receive the stv
    /// @return requestId The Withdrawal Queue request ID
    function requestWithdrawalFromPool(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToBurn,
        uint256 _stethSharesToRebalance,
        address _receiver
    ) external returns (uint256 requestId) {
        address callForwarder = _getOrCreateCallForwarder(msg.sender);

        IStrategyCallForwarder(callForwarder)
            .call(address(WSTETH), abi.encodeWithSelector(WSTETH.unwrap.selector, WSTETH.balanceOf(callForwarder)));

        IStrategyCallForwarder(callForwarder)
            .call(address(POOL_), abi.encodeWithSelector(StvStETHPool.burnStethShares.selector, _stethSharesToBurn));

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
}
