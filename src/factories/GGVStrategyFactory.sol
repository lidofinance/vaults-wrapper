// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {StrategyProxy} from "src/strategy/StrategyProxy.sol";

contract GGVStrategyFactory {
    function deploy(address _pool, address _steth, address _wsteth, address _teller, address _boringQueue)
        external
        returns (address impl)
    {
        address strategyProxyImpl = address(new StrategyProxy());
        impl = address(new GGVStrategy(strategyProxyImpl, _pool, _steth, _wsteth, _teller, _boringQueue));
    }
}
