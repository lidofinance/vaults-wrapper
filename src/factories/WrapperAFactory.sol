// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperA} from "src/WrapperA.sol";

contract WrapperAFactory {
    function deploy(address _dashboard, bool _allowlistEnabled, address _withdrawalQueue)
        external
        returns (address impl)
    {
        impl = address(new WrapperA(_dashboard, _allowlistEnabled, _withdrawalQueue));
    }
}
