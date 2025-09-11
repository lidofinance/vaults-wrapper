// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;


import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/console.sol";

contract GGVStrategy is Strategy {

    ITellerWithMultiAssetSupport public immutable TELLER;
    IBoringOnChainQueue public immutable BORING_QUEUE;

    event Execute(address indexed user, uint256 stvTokenAmount, uint256 stETHAmount);
    event RequestWithdraw(address indexed user, uint256 shares);
    event Claim(address indexed user, address indexed asset, uint256 shares);

    error InvalidStETHAmount();
    error InvalidGGVShares();

    struct UserPosition {
        address user;
        uint256 stvShares;
        uint256 stShares;
        uint256 borrowedEth;
    }

    mapping(address user => UserPosition) public userPositions;

    constructor (
        address _strategyProxyImplementation,
        address _stETH,
        address _wrapper,
        address _teller,
        address _boringQueue
    ) Strategy(_stETH, _wrapper, _strategyProxyImplementation) {
        TELLER = ITellerWithMultiAssetSupport(_teller);
        BORING_QUEUE = IBoringOnChainQueue(_boringQueue);
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
    /// @param _mintableStShares The number of steth shares to mint
    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external {
        address proxy = _getOrCreateProxy(_user);
        uint256 stETHAmount = STETH.getPooledEthByShares(_mintableStShares);

        console.log("execute._stvShares", _stvShares);
        console.log("execute._mintableStShares", _mintableStShares);
        console.log("execute.stETHAmount", stETHAmount);

        //save stv/st share rate
        UserPosition storage position = userPositions[_user];
        position.stvShares += _stvShares;
        position.stShares += _mintableStShares;

        console.log("stv/st share rate", position.stvShares / position.stShares);

        WRAPPER.transfer(proxy, _stvShares);

        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.mintStShares.selector, _mintableStShares)
        );
        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.approve.selector, address(TELLER.vault()), stETHAmount)
        );
        IStrategyProxy(proxy).call(
            address(TELLER),
            abi.encodeWithSelector(TELLER.deposit.selector, address(STETH), stETHAmount, 0 /* minimumMint */)
        );

        console.log("steth balance GGVStrategy", STETH.balanceOf(address(this)));
        console.log("steth balance TELLER.vault()", STETH.balanceOf(address(TELLER.vault())));
        console.log("steth balance proxy", STETH.balanceOf(proxy));

        emit Execute(msg.sender, _stvShares, _mintableStShares);
    }

    /// @notice Requests a withdrawal of ggv shares from the strategy
    /// @param ggvShares The number of ggv shares to withdraw
    function requestWithdraw(uint256 ggvShares) external {
        if (ggvShares == 0) revert InvalidGGVShares();
        address proxy = _getOrCreateProxy(msg.sender);

        IERC20 boringVault = IERC20(TELLER.vault());

        IStrategyProxy(proxy).call(
            address(boringVault),
            abi.encodeWithSelector(boringVault.approve.selector, address(BORING_QUEUE), ggvShares)
        );
         IStrategyProxy(proxy).call(
            address(BORING_QUEUE),
            abi.encodeWithSelector(BORING_QUEUE.requestOnChainWithdraw.selector, address(STETH), uint128(ggvShares), 1, type(uint24).max)
        );

        emit RequestWithdraw(msg.sender, ggvShares);
    }

    /// @notice Claims the specified asset from the strategy
    function finalizeWithdrawal(uint256 stETHAmount) external returns(uint256 stvToken) {
        address _receiver = msg.sender;
        address proxy = _getOrCreateProxy(_receiver);

        IStrategyProxy(proxy).call(
            address(STETH),
            abi.encodeWithSelector(STETH.transfer.selector, _receiver, stETHAmount)
        );

        UserPosition storage position = userPositions[_receiver];

        uint256 stShares = STETH.getSharesByPooledEth(stETHAmount);
        uint256 availableStShares = Math.min(stShares, position.stShares);

        stvToken = Math.mulDiv(position.stvShares, availableStShares, position.stShares);

        IStrategyProxy(proxy).call(
            address(WRAPPER),
            abi.encodeWithSelector(WRAPPER.transfer.selector, address(_receiver), stvToken)
        );


        emit Claim(_receiver, address(STETH), stETHAmount);
    }

    function requestWithdraw(address _user, uint256 _stvShares) external returns (uint256 requestId) {}
}
