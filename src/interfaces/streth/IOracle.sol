// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IOracle {
    /// @notice Detailed price report used for validation and tracking
    struct DetailedReport {
        uint224 priceD18; // Reported asset price in 18-decimal fixed-point format
        uint32 timestamp; // Timestamp when the report was submitted
        bool isSuspicious; // Whether the report is flagged as suspicious according to deviation thresholds
    }

    /// @notice Returns the most recent detailed report for an asset
    /// @param asset Address of the asset
    function getReport(address asset) external view returns (DetailedReport memory);
}
