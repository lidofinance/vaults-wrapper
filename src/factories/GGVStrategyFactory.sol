// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

contract GGVStrategyFactory is IStrategyFactory {
    address public immutable TELLER;
    address public immutable BORING_QUEUE;
    address public immutable STETH;
    address public immutable WSTETH;

    constructor(address _teller, address _boringQueue, address _steth, address _wsteth) {
        require(_teller.code.length > 0, "TELLER: not a contract");
        require(_boringQueue.code.length > 0, "BORING_QUEUE: not a contract");
        require(_steth.code.length > 0, "STETH: not a contract");
        require(_wsteth.code.length > 0, "WSTETH: not a contract");
        TELLER = _teller;
        BORING_QUEUE = _boringQueue;
        STETH = _steth;
        WSTETH = _wsteth;
    }

    function deploy(address _pool, bytes calldata _deployBytes) external returns (address impl) {
        // _deployBytes is unused for GGVStrategy, but required by IStrategyFactory interface
        _deployBytes;
        address strategyCallForwarderImpl = address(new StrategyCallForwarder());
        impl = address(new GGVStrategy(strategyCallForwarderImpl, _pool, STETH, WSTETH, TELLER, BORING_QUEUE));
    }
}
