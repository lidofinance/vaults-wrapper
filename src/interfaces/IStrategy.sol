// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

interface IStrategy {
    function execute(address user, uint256 stETHAmount) external;
    function initiateExit(address user, uint256 assets) external;
    function finalizeExit(address user) external returns (uint256 assets);
    
    function getBorrowDetails() external view returns (
        uint256 borrowAssets,
        uint256 userAssets,
        uint256 totalAssets
    );
    
    function isExiting() external view returns (bool);
}