// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperB} from "src/WrapperB.sol";

contract WrapperBFactory {
    function deploy(address _dashboard, address _steth, bool _allowlistEnabled, uint256 _reserveRatioGapBP, address _withdrawalQueue) external returns (address impl) {
        impl = address(new WrapperB(_dashboard, _steth, _allowlistEnabled, _reserveRatioGapBP, _withdrawalQueue));
    }
}


