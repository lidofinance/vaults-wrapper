// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvStETHPool} from "src/StvStETHPool.sol";

contract StvStETHPoolFactory {
    function deploy(address _dashboard, bool _allowlistEnabled, uint256 _reserveRatioGapBP, address _withdrawalQueue) external returns (address impl) {
        impl = address(new StvStETHPool(_dashboard, _allowlistEnabled, _reserveRatioGapBP, _withdrawalQueue));
    }
}
