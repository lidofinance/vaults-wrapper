// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvPool} from "src/StvPool.sol";

contract StvPoolFactory {
    function deploy(address _dashboard, bool _allowlistEnabled, address _withdrawalQueue, address _distributor)
        external
        returns (address impl)
    {
        impl = address(new StvPool(_dashboard, _allowlistEnabled, _withdrawalQueue, _distributor));
    }
}
