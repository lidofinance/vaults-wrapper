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
}
