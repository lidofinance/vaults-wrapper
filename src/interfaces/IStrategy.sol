// SPDX-License-Identifier: GPL-3.0
pragma solidity >= 0.5.0;

interface IStrategy {
    function execute(address user, uint256 stvTokenShares) external;
    function initiateExit(address user, uint256 assets) external;
    function finalizeExit(address user) external returns (uint256 assets);

    function getBorrowDetails() external view returns (
        uint256 borrowAssets,
        uint256 userAssets,
        uint256 totalAssets
    );

    function isExiting() external view returns (bool);
}