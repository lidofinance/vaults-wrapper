// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Strategy} from "src/strategy/Strategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

contract LeverageStrategy is Strategy {
    constructor(address _strategyProxyImpl, address _stETH) Strategy(_strategyProxyImpl, _stETH) {}

    receive() external payable {}

    function execute(address _user, uint256 _stvShares, uint256 _mintableStShares) external {
        // TODO
    }

    function execute(address user, uint256 stETHAmount) external override {
        // TODO: remove when all strategies unify the execute interface
    }

    function strategyId() public pure override returns (bytes32) {
        return keccak256("strategy.leverage.v1");
    }

    function requestWithdraw(address _user, uint256 _stvShares) external override returns (uint256 requestId) {
        return 0;
    }

    function claim(address asset, uint256 shares) external {}

}