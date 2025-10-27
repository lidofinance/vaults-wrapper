// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvStrategyPool} from "src/StvStrategyPool.sol";

contract StvStrategyPoolFactory {
    function deploy(
        address _steth,
        address _vaultHub,
        address _stakingVault,
        address _dashboard,
        address _withdrawalQueue,
        address _distributor,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP
    ) external returns (address impl) {
        impl = address(
            new StvStrategyPool(
                _steth,
                _vaultHub,
                _stakingVault,
                _dashboard,
                _withdrawalQueue,
                _distributor,
                _allowListEnabled,
                _reserveRatioGapBP
            )
        );
    }
}
