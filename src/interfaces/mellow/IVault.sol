// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFeeManager} from "./IFeeManager.sol";
import {IOracle} from "./IOracle.sol";
import {IShareManager} from "./IShareManager.sol";

interface IVault {
    function shareManager() external view returns (IShareManager);

    function oracle() external view returns (IOracle);

    function hasQueue(address queue) external view returns (bool);

    function isDepositQueue(address queue) external view returns (bool);

    function isPausedQueue(address queue) external view returns (bool);

    function feeManager() external view returns (IFeeManager);

    function queueAt(address asset, uint256 index) external view returns (address);

    function setQueueLimit(uint256 limit) external;

    function createQueue(uint256 version, bool isDeposit, address owner, address asset, bytes calldata data) external;
}
