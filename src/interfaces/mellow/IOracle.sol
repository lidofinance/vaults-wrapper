// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IOracle {
    struct SecurityParams {
        uint224 maxAbsoluteDeviation;
        uint224 suspiciousAbsoluteDeviation;
        uint64 maxRelativeDeviationD18;
        uint64 suspiciousRelativeDeviationD18;
        uint32 timeout;
        uint32 depositInterval;
        uint32 redeemInterval;
    }

    struct Report {
        address asset; // Address of the asset the price refers to
        uint224 priceD18; // Asset price in 18-decimal fixed-point format
    }

    struct DetailedReport {
        uint224 priceD18; // Reported asset price in 18-decimal fixed-point format
        uint32 timestamp; // Timestamp when the report was submitted
        bool isSuspicious; // Whether the report is flagged as suspicious according to deviation thresholds
    }

    function SUBMIT_REPORTS_ROLE() external view returns (bytes32);

    function ACCEPT_REPORT_ROLE() external view returns (bytes32);

    function SET_SECURITY_PARAMS_ROLE() external view returns (bytes32);

    function ADD_SUPPORTED_ASSETS_ROLE() external view returns (bytes32);

    function REMOVE_SUPPORTED_ASSETS_ROLE() external view returns (bytes32);

    function vault() external view returns (address);

    function securityParams() external view returns (SecurityParams memory);

    function supportedAssets() external view returns (uint256);

    function supportedAssetAt(uint256 index) external view returns (address);

    function isSupportedAsset(address asset) external view returns (bool);

    function getReport(address asset) external view returns (DetailedReport memory);

    function validatePrice(uint256 priceD18, address asset) external view returns (bool isValid, bool isSuspicious);

    function submitReports(Report[] calldata reports) external;

    function acceptReport(address asset, uint256 priceD18, uint32 timestamp) external;

    function setSecurityParams(SecurityParams calldata securityParams_) external;

    function addSupportedAssets(address[] calldata assets) external;

    function removeSupportedAssets(address[] calldata assets) external;

    function setVault(address vault_) external;
}
