// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IVault} from "./IVault.sol";

interface IVaultConfigurator {
    struct InitParams {
        uint256 version;
        address proxyAdmin;
        address vaultAdmin;
        uint256 shareManagerVersion;
        bytes shareManagerParams;
        uint256 feeManagerVersion;
        bytes feeManagerParams;
        uint256 riskManagerVersion;
        bytes riskManagerParams;
        uint256 oracleVersion;
        bytes oracleParams;
        address defaultDepositHook;
        address defaultRedeemHook;
        uint256 queueLimit;
        IVault.RoleHolder[] roleHolders;
    }

    function create(InitParams calldata params)
        external
        returns (address shareManager, address feeManager, address riskManager, address oracle, address vault);
}
