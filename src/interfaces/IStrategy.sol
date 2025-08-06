// SPDX-License-Identifier: GPL-3.0
pragma solidity >= 0.5.0;

interface IStrategy {
    function execute(address user, uint256 stETHAmount) external;
}