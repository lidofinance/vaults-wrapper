// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

struct WithdrawalRequest {
    bytes32 strategyRequestId;
    address owner;
    uint256 stethAmount;
    uint40 timestamp;
}