// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IQueue} from "./IQueue.sol";

interface IDepositQueue is IQueue {
    function claimableOf(address account) external view returns (uint256 shares);

    function requestOf(address account) external view returns (uint256 timestamp, uint256 assets);

    function deposit(uint224 assets, address referral, bytes32[] calldata merkleProof) external payable;

    function cancelDepositRequest() external;

    function claim(address account) external returns (bool success);
}
