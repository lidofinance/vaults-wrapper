// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

contract StrategyCallForwarderFactory {
    function deploy() external returns (address) {
        return address(new StrategyCallForwarder());
    }
}
