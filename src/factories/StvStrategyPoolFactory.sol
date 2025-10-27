// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvStrategyPool} from "src/StvStrategyPool.sol";

contract StvStrategyPoolFactory {
    function deploy(address _dashboard, bool _allowlistEnabled, uint256 _reserveRatioGapBP, address _withdrawalQueue, address _distributor) external returns (address impl) {
        impl = address(new StvStrategyPool(_dashboard, _allowlistEnabled, _reserveRatioGapBP, _withdrawalQueue, _distributor));
    }
}
