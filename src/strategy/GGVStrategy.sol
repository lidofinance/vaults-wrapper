// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {IStrategyExitAsync} from "src/interfaces/IStrategyExitAsync.sol";
import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";
import {WrapperB} from "src/WrapperB.sol";

contract GGVStrategy is Strategy, IStrategyExitAsync, ERC165 {

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    uint16 public constant MINIMUM_MINT = 0;

    // ==================== Events ====================

    event MintedGgvShares(address indexed recipient, uint256 ggvShares);

    // ==================== Errors ====================

    error InvalidWrapper();
    error InvalidStrategyRequestId();
    error InvalidSender();
    error InvalidStethAmount();
    error AlreadyRequested();
    error InvalidRequestId();

    struct GGVParams {
        uint16 discount;
        uint16 minimumMint;
        uint24 secondsToDeadline;
    }

    mapping(address user => bytes32 requestId) private exitRequest;

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

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IStrategy).interfaceId 
            || interfaceId == type(IStrategyExitAsync).interfaceId 
            || super.supportsInterface(interfaceId);
    }

    /// @notice Supplies stETH to the strategy
    /// @param _referral The referral address
    /// @param _params The parameters for the supply
    function supply(address _referral, bytes calldata _params) external payable {
        address proxy = _getOrCreateProxy(msg.sender);
        uint256 stethShares = WRAPPER.calcStethSharesToMintForAssets(msg.value);
        uint256 stv = WRAPPER.depositETH{value: msg.value}(proxy, _referral, stethShares);

        uint256 stethAmount = STETH.getPooledEthByShares(stethShares);

        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, TELLER.vault(), stethAmount)
        );

        GGVParams memory params = abi.decode(_params, (GGVParams));

        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER),    
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stethAmount, params.minimumMint)
        );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit MintedGgvShares(msg.sender, ggvShares);
        emit StrategyExecuted(msg.sender, stv, stethShares, stethAmount, _params);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _stethAmount The amount of stETH to withdraw
    /// @return requestId The request id
    function requestExitByStETH(uint256 _stethAmount, bytes calldata _params)
        external
        returns (bytes32 requestId)
    {
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        requestId = requestExitByStethShares(stethSharesToBurn, _params);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _stethSharesToBurn The amount of steth shares to burn
    /// @param _params The parameters for the withdrawal
    /// @return requestId The request id
    function requestExitByStethShares(uint256 _stethSharesToBurn, bytes calldata _params) 
        public 
        returns (bytes32 requestId) 
    {
        bytes32 withdrawalRequestId = exitRequest[msg.sender];
        if (withdrawalRequestId != bytes32(0)) revert AlreadyRequested();

        GGVParams memory params = abi.decode(_params, (GGVParams));

        address proxy = _getOrCreateProxy(msg.sender);
        IERC20 boringVault = IERC20(TELLER.vault());

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 totalGGV = boringVault.balanceOf(proxy);
        uint256 totalStethSharesFromGgv = BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        if (_stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        // Approve GGV shares
        uint256 ggvShares = Math.mulDiv(totalGGV, _stethSharesToBurn, totalStethSharesFromGgv);
        IStrategyProxy(proxy).call(
            address(boringVault), abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

        // Withdrawal request from GGV
        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(
                BORING_QUEUE.requestOnChainWithdraw.selector,
                address(WSTETH),
                uint128(ggvShares),
                params.discount,
                params.secondsToDeadline
            )
        );
        requestId = abi.decode(data, (bytes32));
        exitRequest[msg.sender] = requestId;

        emit ExitRequested(msg.sender, requestId, _stethSharesToBurn, _params);
    }

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelGgvRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        address proxy = getStrategyProxyAddress(msg.sender);
        if (proxy != request.user) revert InvalidSender();

        IStrategyProxy(proxy).call(
            address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request)
        );
    }

    /// @notice Replaces a withdrawal request
    /// @param request The request to replace
    /// @param discount The discount to use
    /// @param secondsToDeadline The deadline to use
    /// @return oldRequestId The old request id
    /// @return newRequestId The new request id
    function replaceGgvOnChainWithdraw(IBoringOnChainQueue.OnChainWithdraw memory request, uint16 discount, uint24 secondsToDeadline) external returns (bytes32 oldRequestId, bytes32 newRequestId) {
        address proxy = getStrategyProxyAddress(msg.sender);
        if (proxy != request.user) revert InvalidSender();

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.replaceOnChainWithdraw.selector, request, discount, secondsToDeadline)
        );
        (oldRequestId, newRequestId) = abi.decode(data, (bytes32, bytes32));
        assert(oldRequestId == exitRequest[msg.sender]);
        exitRequest[msg.sender] = newRequestId;
    }

    /// @notice Finalizes a withdrawal of stETH from the strategy
    function finalizeRequestExit(address /*_receiver*/, bytes32 _requestId) external {
        // GGV does not provide a way to check request status, so we cannot verify if the request
        // was actually finalized in GGV Queue. Additionally, GGV allows multiple withdrawal requests,
        // so it's possible to have request->finalize->request sequence where 2 unfinalised requests 
        // exist in GGV at the same time.
        if (_requestId != exitRequest[msg.sender]) revert InvalidRequestId();
        exitRequest[msg.sender] = bytes32(0);
    }

    /// @notice Returns the amount of stETH shares of a user
    /// @param _user The user to get the stETH shares for
    /// @return stethShares The amount of stETH shares
    function proxyStethSharesOf(address _user) public view returns(uint256 stethShares) {
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
    /// @return stethShares The amount of stETH shares to rebalance
    function proxyStethSharesToRebalance(address _user) external view returns(uint256 stethShares) {
        address proxy = getStrategyProxyAddress(_user);
        uint256 mintedStethShares = WRAPPER.mintedStethSharesOf(proxy);

        uint256 sharesAfterUnwrapping = proxyStethSharesOf(_user);

        if (mintedStethShares > sharesAfterUnwrapping ) {
            stethShares = mintedStethShares - sharesAfterUnwrapping;
        }
    }

    /// @notice Calculates the amount of stvETH shares that can be withdrawn
    /// @param _user The user to calculate the amount of stvETH shares to withdraw for
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @return stv The amount of stvETH shares that can be withdrawn
    function proxyWithdrawableStvOf(address _user, uint256 _stethSharesToBurn) external view returns(uint256 stv) {
        address proxy = getStrategyProxyAddress(_user);
        stv = WRAPPER.withdrawableStvOf(proxy, _stethSharesToBurn);
    }

    /// @notice Requests a withdrawal from the Withdrawal Queue
    /// @param _stvToWithdraw The amount of stvETH shares to withdraw
    /// @param _stethSharesToBurn The amount of stETH shares to burn
    /// @param _stethSharesToRebalance The amount of stETH shares to rebalance
    /// @param _receiver The address to receive the stvETH shares
    /// @return requestId The Withdrawal Queue request ID
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

    /// @notice Returns the request id for a withdrawal
    /// @param _user The user to get the request id for
    /// @return exitRequestId The request id
    function getExitRequestId(address _user) external view returns(bytes32 exitRequestId) {
        exitRequestId = exitRequest[_user];
    }
}
