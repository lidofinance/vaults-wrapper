// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

import {IWstETH} from "src/interfaces/IWstETH.sol";

contract GGVStrategy is Strategy {
    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    uint16 public constant DISCOUNT = 1;
    uint16 public constant MINIMUM_MINT = 0;

    // ==================== Events ====================

    event Execute(address indexed user, uint256 stv, uint256 stethShares, uint256 ggvShares);
    event RequestWithdraw(address indexed user, uint256 shares);
    event Claim(address indexed user, address indexed asset, uint256 stv);

    // ==================== Errors ====================

    error InvalidWrapper();
    error InvalidSender();
    error InvalidStethAmount();
    error InsufficientSurplus(uint256 _amount, uint256 _surplus);
    error AlreadyRequested();
    error TokenNotAllowed();
    error ZeroArgument(string name);

    struct UserPosition {
        bytes32 exitRequestId;
        uint256 exitStvShares;
    }

    mapping(address user => UserPosition) public userPositions;

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
    function getUserPosition(address _user) external view returns (UserPosition memory) {
        return userPositions[_user];
    }

    /// @notice Executes the strategy
    /// @param _user The user to execute the strategy for
    /// @param _stv The number of stv shares to execute
    /// @param _stethShares The number of steth shares to execute
    function execute(address _user, uint256 _stv, uint256 _stethShares) external {
        _onlyWrapper();

        address proxy = _getOrCreateProxy(_user);
        uint256 stETHAmount = STETH.getPooledEthByShares(_stethShares);

        WRAPPER.transfer(proxy, _stv);

        IStrategyProxy(proxy).call(
            address(WRAPPER), abi.encodeWithSelector(WRAPPER.mintStethShares.selector, _stethShares)
        );
        IStrategyProxy(proxy).call(
            address(STETH), abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stETHAmount)
        );
        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER), abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stETHAmount, MINIMUM_MINT)
        );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit Execute(_user, _stv, _stethShares, ggvShares);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param _user The user to request a withdrawal for
    /// @param _stethAmount The amount of stETH to withdraw
    /// @return requestId The request id
    function requestWithdrawByStETH(address _user, uint256 _stethAmount) external returns (uint256 requestId) {
        _onlyWrapper();

        UserPosition storage position = userPositions[_user];
        if (position.exitRequestId != bytes32(0)) revert AlreadyRequested();

        address proxy = _getOrCreateProxy(_user);
        IERC20 boringVault = IERC20(TELLER.vault());

        //steth shares
        uint256 stethSharesToBurn = STETH.getSharesByPooledEth(_stethAmount);

        // Calculate how much steth shares we'll get from total GGV shares
        uint256 totalGGV = boringVault.balanceOf(proxy);
        uint256 totalStethSharesFromGgv = BORING_QUEUE.previewAssetsOut(address(WSTETH), uint128(totalGGV), DISCOUNT);

        if (stethSharesToBurn > totalStethSharesFromGgv) revert InvalidStethAmount();

        uint256 ggvShares = Math.mulDiv(totalGGV, stethSharesToBurn, totalStethSharesFromGgv);
        uint256 calculatedExitStvShares = WRAPPER.withdrawableStv(proxy, stethSharesToBurn);
        uint256 userStvBalance = WRAPPER.balanceOf(proxy);

        uint256 exitStvShares = Math.min(calculatedExitStvShares, userStvBalance);

        IStrategyProxy(proxy).call(
            address(boringVault), abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(
                BORING_QUEUE.requestOnChainWithdraw.selector,
                address(WSTETH),
                uint128(ggvShares),
                DISCOUNT,
                type(uint24).max
            )
        );
        bytes32 ggvRequestId = abi.decode(data, (bytes32));

        position.exitRequestId = ggvRequestId;
        position.exitStvShares = exitStvShares;

        emit RequestWithdraw(_user, ggvShares);

        return uint256(ggvRequestId);
    }

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        if (msg.sender != request.user) revert InvalidSender();

        UserPosition storage position = userPositions[msg.sender];
        address proxy = _getOrCreateProxy(msg.sender);
        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE), abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request)
        );
        bytes32 requestId = abi.decode(data, (bytes32));
        assert(requestId == position.exitRequestId);

        position.exitRequestId = 0;
    }

    /// @notice Finalizes a withdrawal of stETH from the strategy
    /// @param _receiver The address that owns the stETH
    /// @param _amount The amount of stETH to withdraw
    function finalizeWithdrawal(address _receiver, uint256 _amount) external {
        _onlyWrapper();
        if (address(0) == _receiver) _receiver = msg.sender;
        address proxy = _getOrCreateProxy(_receiver);

        UserPosition storage position = userPositions[_receiver];
        position.exitRequestId = 0;

        uint256 wstethAmount = WSTETH.balanceOf(proxy);
        bytes memory unwrapData =
            IStrategyProxy(proxy).call(address(WSTETH), abi.encodeWithSelector(WSTETH.unwrap.selector, wstethAmount));
        uint256 stethAmount = abi.decode(unwrapData, (uint256));
        uint256 stethShares = STETH.getSharesByPooledEth(stethAmount);

        uint256 stv = WRAPPER.withdrawableStv(proxy, stethShares);
        uint256 requestId = WRAPPER.requestWithdrawalQueue(proxy, _receiver, stv);

        emit Claim(_receiver, address(STETH), position.exitStvShares);
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
            uint256 stethBalance = STETH.sharesOf(proxy);
            uint256 stethDebt = WRAPPER.mintedStethSharesOf(proxy);

            uint256 surplusInShares = stethBalance > stethDebt ? stethBalance - stethDebt : 0;
            uint256 amountInShares = STETH.getSharesByPooledEth(_amount);
            if (amountInShares > surplusInShares) {
                revert InsufficientSurplus(amountInShares, surplusInShares);
            }
        }

        IStrategyProxy(proxy).call(_token, abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }

    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }
}
