// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";

error InsufficientShares(uint256 required, uint256 available);

/**
 * @title WrapperA
 * @notice Configuration A: No minting, no strategy - Simple stvETH shares without stETH minting
 */
contract WrapperA is WrapperBase {
    constructor(
        address _dashboard,
        bool _allowListEnabled,
        address _withdrawalQueue
    ) WrapperBase(_dashboard, _allowListEnabled, _withdrawalQueue) {}

    function wrapperType() public pure override returns (string memory) {
        return "WrapperA";
    }
}
