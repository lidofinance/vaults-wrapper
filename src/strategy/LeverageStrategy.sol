// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStETH} from "../interfaces/IStETH.sol";
import {WrapperC} from "../WrapperC.sol";
import {IVaultHub} from "../interfaces/IVaultHub.sol";
import {IDashboard} from "../interfaces/IDashboard.sol";
import {LenderMock} from 'src/mock/LenderMock.sol';

contract LeverageStrategy is IStrategy {

    IERC20 public immutable STV_TOKEN;
    IStETH public immutable STETH;
    LenderMock public immutable LENDER_MOCK;

    WrapperC public WRAPPER;

    uint256 public immutable LOOPS;

    struct UserPosition {
        address user;
        uint256 stvShares;
        uint256 stShares;
        uint256 borrowedEth;
    }

    mapping(address user => UserPosition) public userPositions;

    constructor(address _stETH, uint256 _loops) {
        STETH = IStETH(_stETH);
        LOOPS = _loops;
        LENDER_MOCK = new LenderMock(_stETH);
    }

    function initialize(address _wrapper) external {
        WRAPPER = WrapperC(payable(_wrapper));
    }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("strategy.leverage.v1");
    }

    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external {
        _onlyWrapper();

        UserPosition storage position = userPositions[_user];
        position.stvShares += _stvShares;
        position.stShares += _mintableStShares;

        
        
    }

    function requestWithdraw(address _user, uint256 _stvShares) external returns (uint256 requestId) {}

    function finalizeWithdrawal(address _receiver, uint256 stETHAmount) external returns(uint256 stvToken) {}
 
    function finalizeWithdrawal(uint256 shares) external returns(uint256 stvToken) {}


    function _onlyWrapper() internal view {
        if (msg.sender != address(WRAPPER)) revert InvalidWrapper();
    }
}