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

    event Execute(address indexed user, uint256 stvTokenAmount, uint256 stETHAmount);
    event RequestWithdraw(address indexed user, uint256 shares);
    event Claim(address indexed user, address indexed asset, uint256 shares, uint256 stethShares, uint256 ggvShares, uint256 stv);

    error InvalidWrapper();
    error InvalidStethShares();
    error AlreadyRequested();

    struct UserPosition {
        address user;
        uint256 stvShares;
        uint256 stethShares;
        uint256 borrowedEth;
        uint256 ggvShares;

        bytes32 exitRequestId;
        uint128 exitAmountOfAssets128;
        uint128 exitGgvShares;
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
    function execute(address _user, uint256 _stvShares) external {
        _onlyWrapper();

        address proxy = _getOrCreateProxy(_user);
        uint256 mintableStethShares = WRAPPER.mintableStethShares(address(this));
        uint256 stETHAmount = STETH.getPooledEthByShares(mintableStethShares);

        //save stv/st share rate
        UserPosition storage position = userPositions[_user];
        position.stvShares += _stvShares;
        position.stethShares += mintableStethShares;

        WRAPPER.transfer(proxy, _stvShares);

        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.mintStethShares.selector, mintableStethShares)
        );
        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stETHAmount)
        );
        bytes memory data = IStrategyProxy(proxy).call(
            address(TELLER),
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stETHAmount, MINIMUM_MINT)
        );

        position.ggvShares += abi.decode(data, (uint256));

        emit Execute(_user, _stvShares, mintableStethShares);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    function requestWithdrawByETH(address _user, uint256 _ethAmount) external returns (uint256 requestId)  {
        _onlyWrapper();

        UserPosition storage position = userPositions[_user];
        if (position.exitRequestId != bytes32(0)) revert AlreadyRequested();

        uint256 stethShares = STETH.getSharesByPooledEth(_ethAmount);
        if (position.stethShares < stethShares) revert InvalidStethShares();
        uint128 ggvShares = uint128(Math.mulDiv(position.ggvShares, stethShares, position.stethShares));

        uint256 exitStvShares = Math.mulDiv(position.stvShares, stethShares, position.stethShares);

        address proxy = _getOrCreateProxy(_user);
        IERC20 boringVault = IERC20(TELLER.vault());

        IStrategyProxy(proxy).call(
            address(boringVault),
            abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );

        uint128 amountOfAssets128 = BORING_QUEUE.previewAssetsOut(assetOut, ggvShares, DISCOUNT);

        bytes memory data = IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(BORING_QUEUE.requestOnChainWithdraw.selector, assetOut, ggvShares, DISCOUNT, type(uint24).max)
        );
        bytes32 ggvRequestId = abi.decode(data, (bytes32));

        position.exitRequestId = ggvRequestId;
        position.exitAmountOfAssets128 = amountOfAssets128;
        position.exitGgvShares = ggvShares;
        position.exitStethShares = stethShares;
        position.exitStvShares = exitStvShares;

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
        position.exitGgvShares = 0;
        position.exitAmountOfAssets128 = 0;
        position.exitStvShares = 0;
    }

    function getWithdrawableAmount(address _address) external view returns (uint256 ethAmount) {
        return STETH.getPooledEthByShares(userPositions[_address].stethShares);
    }

    function finalizeWithdrawal(address _receiver, uint256 _amount) external {
        _onlyWrapper();
        if (address(0) == _receiver) _receiver = msg.sender;
        address proxy = _getOrCreateProxy(_receiver);
 
        UserPosition storage position = userPositions[_receiver];

        // transfer only requested part of steth
        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.transfer.selector, _receiver, position.exitAmountOfAssets128)
        );

        // transfer all STV
        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.transfer.selector, _receiver, position.exitStvShares)
        );

        //TODO: do we need to transfer of ggv leftovers?

        position.ggvShares -= position.exitGgvShares;
        position.stethShares -= position.exitStethShares;
        position.stvShares -= position.exitStvShares;

        position.exitRequestId = 0;
        position.exitGgvShares = 0;
        position.exitAmountOfAssets128 = 0;

         emit Claim(
             _receiver,
             address(STETH),
             position.exitAmountOfAssets128,
             position.exitStethShares,
             position.exitGgvShares,
             position.exitStvShares
         );
    }

    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }
}
