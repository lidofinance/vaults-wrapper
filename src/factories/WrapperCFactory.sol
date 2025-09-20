// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperC} from "src/WrapperC.sol";

contract WrapperCFactory {
    function deploy(address _dashboard, address _steth, bool _allowlistEnabled, address _strategy, uint256 _reserveRatioGapBP, address _withdrawalQueue) external returns (address impl) {
        impl = address(new WrapperC(_dashboard, _steth, _allowlistEnabled, _strategy, _reserveRatioGapBP, _withdrawalQueue));
    }
}


