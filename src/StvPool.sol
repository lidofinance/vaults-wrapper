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
        address _steth,
        address _vaultHub,
        address _stakingVault,
        address _dashboard,
        address _withdrawalQueue,
        address _distributor,
        bool _allowListEnabled
    ) BasePool(_steth, _vaultHub, _stakingVault, _dashboard, _withdrawalQueue, _distributor, _allowListEnabled) {}

    function wrapperType() public pure override returns (string memory) {
        return "StvPool";
    }
}
