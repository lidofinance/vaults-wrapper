// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: MIT

pragma solidity >=0.8.25;

/**
 * Interface to connect AccountingOracle with LazyOracle and force type consistency
 */
interface ILazyOracle {
    function latestReportTimestamp() external view returns (uint256);
}
