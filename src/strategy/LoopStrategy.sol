// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStETH} from "../interfaces/IStETH.sol";
import {WrapperC} from "../WrapperC.sol";
import {IVaultHub} from "../interfaces/IVaultHub.sol";
import {IDashboard} from "../interfaces/IDashboard.sol";
import {LenderMock} from 'src/mock/LenderMock.sol';

error NoStETHAvailableForLeverage();


contract LoopStrategy is IStrategy {
    IERC20 public immutable STV_TOKEN;
    IStETH public immutable STETH;
    WrapperC public immutable WRAPPER;
    LenderMock public immutable LENDER_MOCK;

    struct UserPosition {
        address user;
        uint256 stvShares;
        uint256 stShares;
        uint256 borrowedEth;
    }

    mapping(address => UserPosition) public userPositions;

    uint256 public immutable LOOPS;

    constructor(address _stETH, address _wrapper, uint256 _loops) {
        STETH = IStETH(_stETH);
        WRAPPER = WrapperC(payable(_wrapper));
        STV_TOKEN = IERC20(_wrapper);

        LOOPS = _loops;

        LENDER_MOCK = new LenderMock(_stETH);
    }

    function strategyId() external pure override returns (bytes32) {
        return keccak256("ExampleLoopStrategy");
    }

    function getUserPosition(address _address) external view returns (UserPosition memory) {
        return userPositions[_address];
    }

    function execute(address user, uint256 stETHAmount) external override {
        // TODO: remove when all strategies unify the execute interface
    }

    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external override {
        UserPosition memory position = userPositions[_user];
        position.stvShares += _stvShares;
        position.user = _user;

        uint256 mintableStShares = _mintableStShares;
        uint256 borrowedEth = 0;
        for (uint256 i = 0; i < LOOPS; i++) {
            WRAPPER.mintStethShares(mintableStShares);
            position.stShares += _mintableStShares;

            borrowedEth = _borrowFromPool(STETH.getPooledEthByShares(mintableStShares));
            position.borrowedEth += borrowedEth;

            uint256 stSharesBefore = STETH.balanceOf(address(this));
            uint256 mintedStvShares = WRAPPER.depositETH{value: borrowedEth}(address(this), address(0), 0);
            position.stvShares += mintedStvShares;
            mintableStShares = STETH.balanceOf(address(this)) - stSharesBefore;
        }

        // Save user position with loop information
        userPositions[_user] = position;
    }

    function _borrowFromPool(uint256 _stethCollateral) internal returns (uint256 borrowedEth) {
        STETH.approve(address(LENDER_MOCK), _stethCollateral);

        uint256 ethBefore = address(this).balance;
        LENDER_MOCK.borrow(_stethCollateral);

        borrowedEth = address(this).balance - ethBefore;
    }

    receive() external payable {}

    function _getStvSharesWithdrawableWithoutBurningStShares(address _address) internal view returns (uint256 stvShares) {
        UserPosition memory position = userPositions[_address];
        stvShares = position.stvShares; // TODO: calc properly
    }

    function requestWithdraw(address _user, uint256 _stvShares) external override returns (uint256 requestId) {
        // LENDER_MOCK.giveBack{value: address(this).balance}();
        // return WRAPPER.requestWithdrawal(_stvShares);
        uint256 stvShares = _getStvSharesWithdrawableWithoutBurningStShares(_user);
        return WRAPPER.requestWithdrawal(_stvShares);
    }

    function claim(address asset, uint256 shares) external {}
}
