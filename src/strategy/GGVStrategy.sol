// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

contract GGVStrategy is Strategy {

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    uint16 public constant DISCOUNT = 1;
    uint16 public constant MINIMUM_MINT = 0;

    address public assetOut;

    event Execute(address indexed user, uint256 stvTokenAmount, uint256 stETHAmount, uint256 ggvShares);
    event RequestWithdraw(address indexed user, uint256 shares);
    event Claim(address indexed user, address indexed asset, uint256 shares, uint256 stv);

    error InvalidWrapper();
    error InvalidEthAmount();
    error AlreadyRequested();

    struct UserPosition {
        address user;
        uint256 stvShares;
        uint256 stethShares;
        uint256 borrowedEth;
        uint256 ggvShares;

        bytes32 exitRequestId;
        uint256 exitStethShares;
        uint256 exitStvShares;
    }

    mapping(address user => UserPosition) public userPositions;

    constructor (
        address _strategyProxyImplementation,
        address _wrapper,
        address _stETH,
        address _wstETH,
        address _teller,
        address _boringQueue
    ) Strategy(_wrapper, _stETH, _wstETH, _strategyProxyImplementation) {
        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);

        assetOut = address(STETH);
    }

    function strategyId() public pure override returns (bytes32) {
        return keccak256("strategy.ggv.v1");
    }

    function getUserPosition(address _user) external view returns (UserPosition memory) {
        return userPositions[_user];
    }

    /// @notice Executes the strategy
    /// @param _user The user to execute the strategy for
    /// @param _stvShares The number of stv shares to execute
    function execute(address _user, uint256 _stvShares, uint256 _stethShares) external {
        _onlyWrapper();

        address proxy = _getOrCreateProxy(_user);
        uint256 stETHAmount = STETH.getPooledEthByShares(_stethShares);

        UserPosition storage position = userPositions[_user];
        position.stvShares += _stvShares;
        position.stethShares += _stethShares;

        WRAPPER.transfer(proxy, _stvShares);

        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.mintStethShares.selector, _stethShares)
        );
        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stETHAmount)
        );
        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER),
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stETHAmount, MINIMUM_MINT)
        );
        uint256 ggvShares = abi.decode(data, (uint256));

        emit Execute(_user, _stvShares, _stethShares, ggvShares);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    function requestWithdrawByETH(address _user, uint256 _ethAmount) external returns (uint256 requestId)  {
        _onlyWrapper();

        UserPosition storage position = userPositions[_user];
        if (position.exitRequestId != bytes32(0)) revert AlreadyRequested();

        address proxy = _getOrCreateProxy(_user);

        uint256 totalStvShares = WRAPPER.balanceOf(proxy);
        uint256 userTotalEth = WRAPPER.previewRedeem(totalStvShares);
        if (userTotalEth < _ethAmount) revert InvalidEthAmount();

        IERC20 boringVault = IERC20(TELLER.vault());

        uint256 totalGgvShares = boringVault.balanceOf(proxy);
        uint256 ggvShares = Math.mulDiv(totalGgvShares, _ethAmount, userTotalEth);
        uint256 exitStvShares = Math.mulDiv(totalStvShares, _ethAmount, userTotalEth);

        uint128 amountOfAssets128 = BORING_QUEUE.previewAssetsOut(assetOut, uint128(ggvShares), DISCOUNT);

        IStrategyProxy(proxy).call(
            address(boringVault),
            abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(BORING_QUEUE.requestOnChainWithdraw.selector, assetOut, uint128(ggvShares), DISCOUNT, type(uint24).max)
        );
        bytes32 ggvRequestId = abi.decode(data, (bytes32));

        position.exitRequestId = ggvRequestId;
        position.exitStvShares = totalStvShares;

        emit RequestWithdraw(_user, ggvShares);
        
        return uint256(ggvRequestId);
    }

    /// @notice Cancels a withdrawal request
    /// @param request The request to cancel
    function cancelRequest(IBoringOnChainQueue.OnChainWithdraw memory request) external {
        UserPosition storage position = userPositions[msg.sender];
        address proxy = _getOrCreateProxy(msg.sender);
        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(BORING_QUEUE.cancelOnChainWithdraw.selector, request)
        );
        bytes32 requestId = abi.decode(data, (bytes32));

        position.exitRequestId = 0;
    }

    function getWithdrawableAmount(address _receiver) external view returns (uint256 ethAmount) {
        address proxy = getStrategyProxyAddress(_receiver);
        IERC20 boringVault = IERC20(TELLER.vault());
        uint256 ggvShares = boringVault.balanceOf(proxy);

        uint256 stv = WRAPPER.balanceOf(proxy);
        uint256 amountOfAssets128 = BORING_QUEUE.previewAssetsOut(assetOut, uint128(ggvShares), DISCOUNT); //max
        uint256 stethShares = STETH.getSharesByPooledEth(amountOfAssets128);

        uint256 _eth = WRAPPER.withdrawableEth(proxy, stv, stethShares);

        return _eth;
    }

    function withdrawalAmount(address _receiver) external view returns (uint256) {
        address proxy = getStrategyProxyAddress(_receiver);
        IERC20 boringVault = IERC20(TELLER.vault());
        uint256 ggvShares = boringVault.balanceOf(proxy);

        uint256 stv = WRAPPER.balanceOf(proxy);

        return WRAPPER.previewRedeem(stv);
    }

    function finalizeWithdrawal(address _receiver, uint256 _amount) external {
        _onlyWrapper();
        if (address(0) == _receiver) _receiver = msg.sender;
        address proxy = _getOrCreateProxy(_receiver);

        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(WRAPPER), type(uint256).max)
        );

        UserPosition storage position = userPositions[_receiver];
        uint256 stethShares = STETH.getSharesByPooledEth(STETH.balanceOf(proxy));
        uint256 requestId = WRAPPER.requestWithdrawalQueue(proxy, _receiver, position.exitStvShares);

        position.exitRequestId = 0;

         emit Claim(
             _receiver,
             address(STETH),
             position.exitStethShares,
             position.exitStvShares
         );
    }

    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }
}
