// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {WithdrawalRequest} from "src/strategy/WithdrawalRequest.sol";
import {WrapperB} from "src/WrapperB.sol";

import {IWstETH} from "src/interfaces/IWstETH.sol";

import {console} from "forge-std/console.sol";

contract GGVStrategy is Strategy {
    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    uint16 public constant MINIMUM_MINT = 0;

    // ==================== Events ====================

    event Execute(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, uint256 ggvShares);
    event RequestWithdraw(address indexed user, uint256 stethAmount, uint256 ggvShares);
    event Finalized(address indexed user, uint256 wqRequestId, uint256 stv, uint256 stethAmount, uint256 stethShares);

    // ==================== Errors ====================

    error InvalidWrapper();
    error InvalidStrategyRequestId();
    error InvalidSender();
    error InvalidStethAmount();
    error InsufficientSurplus(uint256 _amount, uint256 _surplus);
    error AlreadyRequested();
    error TokenNotAllowed();
    error ZeroArgument(string name);

    struct GGVParams {
        uint16 discount;
        uint16 minimumMint;
        uint24 secondsToDeadline;
    }

    mapping(address user => bytes32 withdrawalRequestId) private withdrawalRequest;

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

    /// @notice The strategy id
    function strategyId() public pure override returns (bytes32) {
        return keccak256("strategy.ggv.v1");
    }

    /// @notice Gets the user position
    /// @param _user The user to get the position for
    /// @return The user position
    function getWithdrawalRequestId(address _user) external view returns (bytes32) {
        return withdrawalRequest[_user];
    }

    /// @notice Executes the strategy
    /// @param _user The user to execute the strategy for
    /// @param _stv The number of stv shares to execute
    /// @param _stethShares The number of steth shares to execute
    function execute(address _user, uint256 _stv, uint256 _stethShares) external {
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

        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER),
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stethAmount, MINIMUM_MINT)
        );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit Execute(_user, _stv, _stethShares, stethAmount, ggvShares);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _user The user to request a withdrawal for
    /// @param _stethAmount The amount of stETH to withdraw
    /// @return requestId The request id
    function requestWithdrawByStETH(address _user, uint256 _stethAmount, bytes calldata _params)
        external
        returns (bytes32 requestId)
    {
        _onlyWrapper();

        bytes32 withdrawalRequestId = withdrawalRequest[_user];
        if (withdrawalRequestId != bytes32(0)) revert AlreadyRequested();

        GGVParams memory params = abi.decode(_params, (GGVParams));

        address proxy = _getOrCreateProxy(_user);
        IERC20 boringVault = IERC20(TELLER.vault());

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        uint256 totalGGV = boringVault.balanceOf(proxy);
        uint256 totalStethSharesFromGgv = BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        if (stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        uint256 ggvShares = Math.mulDiv(totalGGV, stethSharesToBurn, totalStethSharesFromGgv);

        IStrategyProxy(proxy).call(
            address(boringVault), abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

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

        withdrawalRequest[_user] = requestId;

        emit RequestWithdraw(_user, _stethAmount, ggvShares);
    }

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        if (msg.sender != request.user) revert InvalidSender();

        bytes32 withdrawalRequestId = withdrawalRequest[msg.sender];
        address proxy = _getOrCreateProxy(msg.sender);

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request)
        );
        bytes32 requestId = abi.decode(data, (bytes32));
        assert(requestId == withdrawalRequestId);

        withdrawalRequest[msg.sender] = 0;
    }

    /// @notice Finalizes a withdrawal of stETH from the strategy
    function finalizeWithdrawal(WithdrawalRequest memory _request) external {
        _onlyWrapper();
        if (_request.strategyRequestId == bytes32(0)) revert InvalidStrategyRequestId();
        if (address(0) == _request.owner) _request.owner = msg.sender;

        address proxy = _getOrCreateProxy(_request.owner);

        withdrawalRequest[_request.owner] = 0;

        uint256 stethSharesToBurn = WSTETH.balanceOf(proxy);
        bytes memory data = IStrategyProxy(proxy).call(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.unwrap.selector, stethSharesToBurn)
        );
        uint256 stethAmount = abi.decode(data, (uint256));

        // Because of rounding issue, the amount of steth shares after wstETH unwrapping can be less than requested
        stethSharesToBurn = STETH.getSharesByPooledEth(stethAmount);

        uint256 stethSharesToRebalance = 0;
        uint256 mintedStethShares = WRAPPER.mintedStethSharesOf(proxy);
        if (mintedStethShares > stethSharesToBurn ) {
            stethSharesToRebalance = mintedStethShares - stethSharesToBurn;
        }

        uint256 stv = WRAPPER.balanceOf(proxy);

        bytes memory requestData = IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WrapperB.requestWithdrawal.selector, stv, stethSharesToBurn, stethSharesToRebalance, _request.owner)
        );
        uint256 wqRequestId = abi.decode(requestData, (uint256));

        emit Finalized(_request.owner, wqRequestId, stv, stethAmount, stethSharesToBurn);
    }

    /// @notice Recovers ERC20 tokens from the strategy
    /// @param _token The token to recover
    /// @param _recipient The recipient of the tokens
    /// @param _amount The amount of tokens to recover
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");
        if (_token == address(WRAPPER)) revert TokenNotAllowed();

        address proxy = getStrategyProxyAddress(msg.sender);

        if (_token == address(STETH)) {
            uint256 stethSharesBalance = STETH.sharesOf(proxy);
            uint256 stethLiabilityShares = WRAPPER.mintedStethSharesOf(proxy);

            uint256 surplusInShares = stethSharesBalance > stethLiabilityShares ? stethSharesBalance - stethLiabilityShares : 0;
            uint256 amountInShares = STETH.getSharesByPooledEth(_amount);
            if (amountInShares > surplusInShares) {
                revert InsufficientSurplus(amountInShares, surplusInShares);
            }
        }

        //TODO wstETH

        IStrategyProxy(proxy).call(_token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }

    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }
}
