// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {DummyImplementation} from "src/proxy/DummyImplementation.sol";

contract LoopStrategyFactory {
    function deploy(
        address,
        /* _steth */
        address,
        /* _pool */
        uint256 /* _loops */
    )
        external
        returns (address impl)
    {
        impl = address(new DummyImplementation());
        //        impl = address(new LoopStrategy(_steth, _pool, _loops));
    }
}
