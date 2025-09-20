// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract WithdrawalQueueFactory {
    function deploy(address _wrapper, uint256 _maxFinalizationTime) external returns (address impl) {
        impl = address(new WithdrawalQueue(_wrapper, _maxFinalizationTime));
    }
}


