// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IQueue} from "./IQueue.sol";

interface IRedeemQueue is IQueue {
    struct Request {
        uint256 timestamp;
        uint256 shares;
        bool isClaimable;
        uint256 assets;
    }

    function requestsOf(address account, uint256 offset, uint256 limit)
        external
        view
        returns (Request[] memory requests);

    function redeem(uint256 shares) external;

    function claim(address account, uint32[] calldata timestamps) external returns (uint256 assets);

    function handleBatches(uint256 batches) external returns (uint256 counter);
}
