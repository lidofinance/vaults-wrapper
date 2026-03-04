// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFeeManager {
    function calculateDepositFee(uint256 amount) external view returns (uint256);

    function calculateRedeemFee(uint256 amount) external view returns (uint256);

    function depositFeeD6() external view returns (uint256);

    function redeemFeeD6() external view returns (uint256);

    function setFees(uint24 depositFeeD6_, uint24 redeemFeeD6_, uint24 performanceFeeD6_, uint24 protocolFeeD6_)
        external;
}
