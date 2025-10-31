// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";
import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";

contract GGVStrategyFactory is IStrategyFactory {
    function deploy(address _pool, address _steth, address _wsteth, address _teller, address _boringQueue)
        external
        returns (address impl)
    {
        address strategyCallForwarderImpl = address(new StrategyCallForwarder());
        impl = address(new GGVStrategy(strategyCallForwarderImpl, _pool, _steth, _wsteth, _teller, _boringQueue));
    }
}
