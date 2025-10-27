// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvPool} from "src/StvPool.sol";

contract StvPoolFactory {
    function deploy(
        address _steth,
        address _vaultHub,
        address _stakingVault,
        address _dashboard,
        address _withdrawalQueue,
        address _distributor,
        bool _allowListEnabled
    ) external returns (address impl) {
        impl = address(
            new StvPool(_steth, _vaultHub, _stakingVault, _dashboard, _withdrawalQueue, _distributor, _allowListEnabled)
        );
    }
}
