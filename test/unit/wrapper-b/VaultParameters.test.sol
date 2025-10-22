// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";
import {MockVaultHub} from "../../mocks/MockVaultHub.sol";

contract VaultParametersTest is Test, SetupWrapperB {
    function test_ReserveRatioBP_ReturnsExpectedValue() public view {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint256 vaultReserveRatioBP = vaultHub.vaultConnection(stakingVault).reserveRatioBP;

        assertEq(wrapper.reserveRatioBP(), vaultReserveRatioBP + reserveRatioGapBP);
    }

    function test_ForcedRebalanceThresholdBP_ReturnsExpectedValue() public view {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint256 vaultForcedRebalanceThresholdBP = vaultHub.vaultConnection(stakingVault).forcedRebalanceThresholdBP;

        assertEq(wrapper.forcedRebalanceThresholdBP(), vaultForcedRebalanceThresholdBP + reserveRatioGapBP);
    }

    function test_SyncVaultParameters_UpdatesParameters() public {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint16 baseReserveRatioBP = 1_000;
        uint16 baseForcedThresholdBP = 1_200;
        vaultHub.mock_setConnectionParameters(stakingVault, baseReserveRatioBP, baseForcedThresholdBP);

        wrapper.syncVaultParameters();

        assertEq(wrapper.reserveRatioBP(), baseReserveRatioBP + reserveRatioGapBP);
        assertEq(wrapper.forcedRebalanceThresholdBP(), baseForcedThresholdBP + reserveRatioGapBP);
    }

    function test_SyncVaultParameters_EmitsEvent() public {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint16 baseReserveRatioBP = 1_000;
        uint16 baseForcedThresholdBP = 1_200;
        vaultHub.mock_setConnectionParameters(stakingVault, baseReserveRatioBP, baseForcedThresholdBP);

        vm.expectEmit(false, false, false, true);
        emit WrapperB.VaultParametersUpdated(
            baseReserveRatioBP + reserveRatioGapBP,
            baseForcedThresholdBP + reserveRatioGapBP
        );
        wrapper.syncVaultParameters();
    }

    function test_SyncVaultParameters_NoOpWhenParametersUnchanged() public {
        vm.recordLogs();

        wrapper.syncVaultParameters();

        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_SyncVaultParameters_RevertsWhenReserveRatioTooHigh() public {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint16 baseReserveRatioBP = 9_600;
        uint16 baseForcedThresholdBP = 0;
        vaultHub.mock_setConnectionParameters(stakingVault, baseReserveRatioBP, baseForcedThresholdBP);

        vm.expectRevert(
            abi.encodeWithSelector(
                WrapperB.InvalidReserveRatio.selector,
                uint256(baseReserveRatioBP + reserveRatioGapBP)
            )
        );
        wrapper.syncVaultParameters();
    }

    function test_SyncVaultParameters_RevertsWhenForcedThresholdTooHigh() public {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        address stakingVault = dashboard.stakingVault();
        uint16 baseReserveRatioBP = 4_000;
        uint16 baseForcedThresholdBP = 9_700;
        vaultHub.mock_setConnectionParameters(stakingVault, baseReserveRatioBP, baseForcedThresholdBP);

        vm.expectRevert(
            abi.encodeWithSelector(
                WrapperB.InvalidForcedRebalanceThreshold.selector,
                uint256(baseForcedThresholdBP + reserveRatioGapBP)
            )
        );
        wrapper.syncVaultParameters();
    }
}
