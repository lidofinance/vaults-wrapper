// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IOracle} from "./IOracle.sol";
import {IShareManager} from "./IShareManager.sol";

interface IVault {
    /// @notice Returns the ShareManager used for minting and burning shares
    function shareManager() external view returns (IShareManager);

    /// @notice Returns the Oracle contract used for handling reports and managing supported assets.
    function oracle() external view returns (IOracle);

    /// @notice Returns whether the given queue is registered
    function hasQueue(address queue) external view returns (bool);

    /// @notice Returns whether the given queue is a deposit queue
    function isDepositQueue(address queue) external view returns (bool);
}
