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
}