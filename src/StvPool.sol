// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {BasePool} from "./BasePool.sol";

error InsufficientShares(uint256 required, uint256 available);

/**
 * @title StvPool
 * @notice Configuration A: No minting, no strategy - Simple stv without stETH minting
 */
contract StvPool is BasePool {
    constructor(
        address _dashboard,
        bool _allowListEnabled,
        address _withdrawalQueue
    ) BasePool(_dashboard, _allowListEnabled, _withdrawalQueue) {}

    function wrapperType() public pure override returns (string memory) {
        return "StvPool";
    }
}
