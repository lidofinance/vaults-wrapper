// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IQueue} from "./IQueue.sol";

interface ISyncDepositQueue is IQueue {
    function syncDepositParams() external view returns (uint256 penaltyD6, uint32 maxAgeD6);

    function name() external view returns (string memory);
}
