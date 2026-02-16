// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IQueue} from "./IQueue.sol";

interface ISyncDepositQueue is IQueue {
    function syncDepositParams() external view returns (uint256 penaltyD6, uint32 maxAge);

    function name() external view returns (string memory);
}
