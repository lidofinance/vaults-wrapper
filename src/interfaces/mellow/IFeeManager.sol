// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IFeeManager {
    function depositFeeD6() external view returns (uint256);

    function redeemFeeD6() external view returns (uint256);
}
