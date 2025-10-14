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

    // ==================== Events ====================

    event Execute(address indexed user, uint256 stv, uint256 stethShares, uint256 stethAmount, uint256 ggvShares);
    event RequestWithdraw(address indexed user, uint256 stethAmount, uint256 ggvShares);
    event Finalized(address indexed user, uint256 wqRequestId, uint256 stv, uint256 stethAmount, uint256 stethShares);
    event StrategyWithdrawalRequested(uint256 requestId, bytes32 strategyRequestId, address indexed user, uint256 amount, uint40 timestamp);
    event StrategyWithdrawalFinalized(uint256 requestId, bytes32 strategyRequestId, address indexed user, uint256 amount, uint40 timestamp);

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

    /// @custom:storage-location erc7201:wrapper.ggvStrategy.storage
    struct WrapperStrategyStorage {
        WithdrawalRequest[] withdrawalRequests;
        mapping(address => EnumerableSet.UintSet) requestsByOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.ggvStrategy.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_STRATEGY_STORAGE_LOCATION =
        0xa709d9a71d398dc45b51e1c30a153dd61994aca5b1bd6721afa406671f53ff00;

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

        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();

        uint256 withdrawalRequests = $.requestsByOwner[_user].length();
        if (withdrawalRequests) revert AlreadyRequested();

        GGVParams memory params = abi.decode(_params, (GGVParams));

        address proxy = _getOrCreateProxy(_user);
        IERC20 boringVault = IERC20(TELLER.vault());

        // Calculate how much wsteth we'll get from total GGV shares
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);
        uint256 totalGGV = boringVault.balanceOf(proxy);
        uint256 totalStethSharesFromGgv = BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), params.discount);
        if (stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        // Approve GGV shares
        uint256 ggvShares = Math.mulDiv(totalGGV, stethSharesToBurn, totalStethSharesFromGgv);
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
        bytes32 strategyRequestId = abi.decode(data, (bytes32));

        // Store internal withdrawal request
        requestId = $.withdrawalRequests.length;
        WithdrawalRequest memory request = WithdrawalRequest({
            strategyRequestId: strategyRequestId,
            owner: _user,
            timestamp: uint40(block.timestamp),
            stethAmount: _stethAmount
        });

        $.withdrawalRequests.push(request);
        $.requestsByOwner[_user].add(requestId);

        emit RequestWithdraw(_user, _stethAmount, ggvShares);
//        emit StrategyWithdrawalRequested(requestId, strategyRequestId, msg.sender, _stethAmount, uint40(block.timestamp));
    }

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        if (msg.sender != request.user) revert InvalidSender();

        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];
        $.requestsByOwner[request.owner].remove(_requestId);

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
    function finalizeWithdrawal(uint256 _requestId) external {
        _onlyWrapper();

        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[_requestId];
        $.requestsByOwner[request.owner].remove(_requestId);

        if (request.strategyRequestId == bytes32(0)) revert InvalidStrategyRequestId();
        if (address(0) == request.owner) request.owner = msg.sender;

        address proxy = _getOrCreateProxy(request.owner);

        withdrawalRequest[request.owner] = 0;

        uint256 stethSharesToBurn = WSTETH.balanceOf(proxy);
        bytes memory data = IStrategyProxy(proxy).call(
            address(WSTETH),
            abi.encodeWithSelector(WSTETH.unwrap.selector, stethSharesToBurn)
        );
        uint256 stethAmount = abi.decode(data, (uint256));

        uint256 stethToRebalance = 0;
        uint256 mintedStethShares = WRAPPER.mintedStethSharesOf(proxy);
        if (mintedStethShares > stethSharesToBurn ) {
            stethToRebalance = mintedStethShares - stethSharesToBurn;
        }

        uint256 stv = WRAPPER.balanceOf(proxy);

        bytes memory requestData = IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WrapperB.requestWithdrawal.selector, stv, stethSharesToBurn, stethToRebalance, _request.owner)
        );
        uint256 wqRequestId = abi.decode(requestData, (uint256));

        emit Finalized(request.owner, wqRequestId, stv, stethAmount, stethSharesToBurn);
//        emit StrategyWithdrawalFinalized(_requestId, request.strategyRequestId, request.owner, request.stethAmount, request.timestamp);
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

    // =================================================================================
    // WITHDRAWALS
    // =================================================================================

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return requestIds array of request ids
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].values();
    }

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @param _start start index
    /// @param _end end index
    /// @return requestIds array of request ids
    function getWithdrawalRequests(
        address _owner,
        uint256 _start,
        uint256 _end
    ) public view returns (uint256[] memory requestIds) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].values(_start, _end);
    }

    /// @notice Returns the length of the withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return length of the withdrawal requests
    function getWithdrawalRequestsLength(address _owner) public view returns (uint256 length) {
        WrapperStrategyStorage storage $ = _getWrapperStrategyStorage();
        return $.requestsByOwner[_owner].length();
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _getWrapperStrategyStorage().withdrawalRequests[requestId];
    }

    function _getWrapperStrategyStorage() internal pure returns (WrapperStrategyStorage storage $) {
        assembly {
            $.slot := WRAPPER_STRATEGY_STORAGE_LOCATION
        }
    }
}
