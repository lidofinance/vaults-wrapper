// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";
import {WrapperB} from "src/WrapperB.sol";

import {IWstETH} from "src/interfaces/IWstETH.sol";

contract GGVStrategy is Strategy {
    using EnumerableSet for EnumerableSet.UintSet;

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    uint16 public constant MINIMUM_MINT = 0;

    // ==================== Errors ====================

    error InvalidWrapper();
    error InvalidStrategyRequestId();
    error InvalidSender();
    error InvalidStethAmount();
    error AlreadyRequested();

    struct GGVParams {
        uint16 discount;
        uint16 minimumMint;
        uint24 secondsToDeadline;
    }

    mapping(address user => bytes32 requestId) private withdrawalRequest;
    mapping(bytes32 requestId => IBoringOnChainQueue.OnChainWithdraw) internal onChainWithdraws;

    constructor(
        address _strategyProxyImplementation,
        address _wrapper,
        address _stETH,
        address _wstETH,
        address _teller,
        address _boringQueue
    ) Strategy(_wrapper, _stETH, _wstETH, _strategyProxyImplementation) {
        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);
    }

    /// @notice Executes the strategy
    /// @param _user The user to execute the strategy for
    /// @param _stv The number of stv shares to execute
    /// @param _stethShares The number of steth shares to execute
    function execute(address _user, uint256 _stv, uint256 _stethShares, bytes calldata _params) external {
        _onlyWrapper();

        address proxy = _getOrCreateProxy(_user);
        uint256 stethAmount = STETH.getPooledEthByShares(_stethShares);

        WRAPPER.transfer(proxy, _stv);

        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.mintStethShares.selector, _stethShares)
        );
        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stethAmount)
        );

        // Decode the parameters or use default values if no parameters are provided
        GGVParams memory params = _params.length > 0 
            ? abi.decode(_params, (GGVParams))
            : GGVParams(0, MINIMUM_MINT, 0);

        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER),    
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stethAmount, params.minimumMint)
        );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit StrategyExecuted(_user, _stv, _stethShares, stethAmount, _params);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _user The user to request a withdrawal for
    /// @param _stethAmount The amount of stETH to withdraw
    /// @return requestId The request id
    function requestExitByStETH(address _user, uint256 _stethAmount, bytes calldata _params)
    external
    returns (bytes32 requestId)
    {
        _onlyWrapper();

        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        requestId = requestExitByStethShares(_user, stethSharesToBurn, _params);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _user The user to request a withdrawal for
    /// @param _stethSharesToBurn The amount of steth shares to burn
    /// @param _params The parameters for the withdrawal
    /// @return requestId The request id
    function requestExitByStethShares(address _user, uint256 _stethSharesToBurn, bytes calldata _params) 
        public 
        returns (bytes32 requestId) 
    {
        _onlyWrapper();

        bytes32 withdrawalRequestId = withdrawalRequest[_user];
        if (withdrawalRequestId != bytes32(0)) revert AlreadyRequested();

        GGVParams memory params = abi.decode(_params, (GGVParams));

        address proxy = _getOrCreateProxy(_user);
        IERC20 boringVault = IERC20(TELLER.vault());
        address assetOut = address(WSTETH);

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 totalGGV = boringVault.balanceOf(proxy);
        uint256 totalStethSharesFromGgv = BORING_QUEUE.previewAssetsOut(assetOut, uint128(totalGGV), params.discount);
        if (_stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        // Approve GGV shares
        uint256 ggvShares = Math.mulDiv(totalGGV, _stethSharesToBurn, totalStethSharesFromGgv);
        IStrategyProxy(proxy).call(
            address(boringVault), abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

        uint128 amountOfShares = uint128(ggvShares);
        IBoringOnChainQueue.WithdrawAsset memory withdrawAsset = BORING_QUEUE.withdrawAssets(assetOut);
        uint128 amountOfAssets128 = BORING_QUEUE.previewAssetsOut(assetOut, amountOfShares, params.discount);
        uint40 timeNow = uint40(block.timestamp);

        IBoringOnChainQueue.OnChainWithdraw memory request = IBoringOnChainQueue.OnChainWithdraw({
            nonce: BORING_QUEUE.nonce(),
            user: proxy,
            assetOut: assetOut,
            amountOfShares: amountOfShares,
            amountOfAssets: amountOfAssets128,
            creationTime: timeNow,
            secondsToMaturity: withdrawAsset.secondsToMaturity,
            secondsToDeadline: params.secondsToDeadline
        });

        // Withdrawal request from GGV
        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(
                BORING_QUEUE.requestOnChainWithdraw.selector,
                request.assetOut,
                request.amountOfShares,
                params.discount,
                request.secondsToDeadline
            )
        );
        requestId = abi.decode(data, (bytes32));
        withdrawalRequest[_user] = requestId;
        onChainWithdraws[requestId] = request;

        emit WithdrawalRequested(_user, requestId, _stethSharesToBurn, _params);
    }

    function cancelExitRequest(address _user, bytes32 _requestId) external {
        // cancelGgvRequest()
    }
    function processExitRequest(address _user, bytes32 _requestId) external {}

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelGgvRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        address proxy = getStrategyProxyAddress(msg.sender);
        if (proxy != request.user) revert InvalidSender();

        bytes32 withdrawalRequestId = withdrawalRequest[msg.sender];
        withdrawalRequest[msg.sender] = 0;

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request)
        );
        bytes32 requestId = abi.decode(data, (bytes32));
        assert(requestId == withdrawalRequestId);
    }

    /// @notice Finalizes a withdrawal of stETH from the strategy
    function finalizeExit(address _user, address _receiver, bytes32 _requestId) external {
        _onlyWrapper();

    }

    /// @notice Returns the amount of stETH shares of a user
    /// @param _user The user to get the stETH shares for
    /// @return stethShares The amount of stETH shares
    function stethSharesOf(address _user) public view returns(uint256 stethShares) {
        address proxy = getStrategyProxyAddress(_user);

        // simulate the unwrapping of wstETH to stETH with rounding issue
        uint256 wstethAmount = WSTETH.balanceOf(proxy);
        uint256 stETHAmount = STETH.getPooledEthByShares(wstethAmount);
        uint256 sharesAfterUnwrapping = STETH.getSharesByPooledEth(stETHAmount);

        // add the stETH shares of the proxy
        stethShares = sharesAfterUnwrapping + STETH.sharesOf(proxy);
    }

    /// @notice Calculates the amount of stETH shares to rebalance
    /// @param _user The user to calculate the amount of stETH shares to rebalance for
    /// @return stethSharesToRebalance The amount of stETH shares to rebalance
    function stethSharesToRebalance(address _user) external view returns(uint256 stethSharesToRebalance) {
        address proxy = getStrategyProxyAddress(_user);
        uint256 mintedStethShares = WRAPPER.mintedStethSharesOf(proxy);
    
        uint256 sharesAfterUnwrapping = stethSharesOf(_user);

        if (mintedStethShares > sharesAfterUnwrapping ) {
            stethSharesToRebalance = mintedStethShares - sharesAfterUnwrapping;
        }
    }

    /// @notice Calculates the amount of stvETH shares that can be withdrawn
    /// @param _user The user to calculate the amount of stvETH shares to withdraw for
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @return stv The amount of stvETH shares that can be withdrawn
    function withdrawableStvOf(address _user, uint256 _stethSharesToBurn) external view returns(uint256 stv) {
        address proxy = getStrategyProxyAddress(_user);
        stv = WRAPPER.withdrawableStvOf(proxy, _stethSharesToBurn);
    }

    /// @notice Requests a withdrawal from the strategy
    /// @param _stvToWithdraw The amount of stvETH shares to withdraw
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @param _stethSharesToRebalance The amount of stETH shares to rebalance
    /// @param _receiver The address to receive the stvETH shares
    /// @return requestId The request id
    function requestWithdrawal(
        uint256 _stvToWithdraw, 
        uint256 _stethSharesToBurn, 
        uint256 _stethSharesToRebalance, 
        address _receiver
    ) external returns (uint256 requestId) {
        address proxy = _getOrCreateProxy(msg.sender);

        IStrategyProxy(proxy).call(
            address(WSTETH),    
            abi.encodeWithSelector(WSTETH.unwrap.selector, WSTETH.balanceOf(proxy))
        );

        // request withdrawal from wrapper
        bytes memory withdrawalData = IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(
                WrapperB.requestWithdrawal.selector,
                _stvToWithdraw,
                _stethSharesToBurn,
                _stethSharesToRebalance,
                _receiver
            )
        );
        requestId = abi.decode(withdrawalData, (uint256));
    }

    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }

    function getWithdrawalRequestId(address _user) external view returns(bytes32 requestId) {
        requestId = withdrawalRequest[_user];
    }
}
