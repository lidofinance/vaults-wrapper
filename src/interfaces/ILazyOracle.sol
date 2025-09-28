// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: MIT

pragma solidity >=0.8.25;

/**
 * Interface to connect AccountingOracle with LazyOracle and force type consistency
 */
interface ILazyOracle {
    function updateReportData(
        uint256 _vaultsDataTimestamp,
        uint256 _vaultsDataRefSlot,
        bytes32 _vaultsDataTreeRoot,
        string memory _vaultsDataReportCid
    ) external;

    function updateVaultData(
        address _vault,
        uint256 _totalValue,
        uint256 _cumulativeLidoFees,
        uint256 _liabilityShares,
        uint256 _slashingReserve,
        bytes32[] calldata _proof
    ) external;
    function latestReportTimestamp() external view returns (uint256);
    function latestReportData()
        external
        view
        returns (uint256 timestamp, uint256 refSlot, bytes32 treeRoot, string memory reportCid);
}
