// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvStETHPool} from "./StvStETHPool.sol";

/**
 * @title StvStrategyPool
 * @notice Configuration C: Minting functionality with strategy - stv with stETH minting capability and strategy integration
 * @dev Strategy addresses are managed through the allowlist mechanism inherited from BasePool
 */
contract StvStrategyPool is StvStETHPool {
    constructor(
        address _dashboard,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) StvStETHPool(_dashboard, _allowListEnabled, _reserveRatioGapBP, _withdrawalQueue) {
    }

    function wrapperType() external pure virtual override returns (string memory) {
        return "StvStrategyPool";
    }
}
