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
        address _steth,
        address _vaultHub,
        address _stakingVault,
        address _dashboard,
        address _withdrawalQueue,
        address _distributor,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP
    )
        StvStETHPool(
            _steth,
            _vaultHub,
            _stakingVault,
            _dashboard,
            _withdrawalQueue,
            _distributor,
            _allowListEnabled,
            _reserveRatioGapBP
        )
    {}

    function wrapperType() external pure virtual override returns (string memory) {
        return "StvStrategyPool";
    }
}
