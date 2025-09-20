// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";
import {ILazyOracle} from "../../src/interfaces/ILazyOracle.sol";

contract MockLazyOracle is ILazyOracle {

    uint256 private _latestReportTimestamp;

    function latestReportTimestamp() external view returns (uint256) {
        return _latestReportTimestamp;
    }

    function mock__updateLatestReportTimestamp(uint256 _timestamp) external {
        _latestReportTimestamp = _timestamp;
    }

    function updateReportData(
        uint256 _vaultsDataTimestamp,
        uint256 _vaultsDataRefSlot,
        bytes32 _vaultsDataTreeRoot,
        string memory _vaultsDataReportCid
    ) external {}
    function updateVaultData(
        address _vault,
        uint256 _totalValue,
        uint256 _cumulativeLidoFees,
        uint256 _liabilityShares,
        uint256 _slashingReserve,
        bytes32[] calldata _proof
    ) external {}
    function latestReportData() external view returns (uint256 timestamp, uint256 refSlot, bytes32 treeRoot, string memory reportCid) {}
}