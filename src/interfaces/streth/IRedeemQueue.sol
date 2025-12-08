// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IQueue} from "./IQueue.sol";

interface IRedeemQueue is IQueue {
    struct Request {
        /// @notice Timestamp when the redemption request was submitted.
        /// @dev Determines eligibility for processing based on oracle report timing and `redeemInterval`.
        uint256 timestamp;
        /// @notice Amount of vault shares submitted for redemption.
        uint256 shares;
        /// @notice Whether the request has been processed and is now claimable.
        /// @dev Set to `true` after liquidity has been allocated via `handleBatches`.
        bool isClaimable;
        /// @notice Amount of assets that can be claimed by the user.
        /// @dev Calculated and stored after a matching oracle report has been processed via `handleReport`.
        uint256 assets;
    }

    function requestsOf(address account, uint256 offset, uint256 limit)
        external
        view
        returns (Request[] memory requests);

    function redeem(uint256 shares) external;

    function claim(address account, uint32[] calldata timestamps) external returns (uint256 assets);
}
