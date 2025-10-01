// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract FinalizationTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();
        wrapper.depositETH{value: 100_000 ether}();
    }

    // Basic Finalization

    function test_Finalize_SimpleRequestAndFinalization() public {
        uint256 requestId = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Verify request was created
        assertEq(requestId, 1);
        assertEq(withdrawalQueue.getLastRequestId(), 1);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);

        // Check request status - should not be finalized yet
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertFalse(status.isFinalized);
        assertEq(status.owner, address(this));

        // Move time forward to pass minimum delay
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // Finalize the request
        vm.prank(finalizeRoleHolder);
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        // Verify finalization succeeded
        assertEq(finalizedCount, 1);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), requestId);

        // Check request status is now finalized
        status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized);
        assertFalse(status.isClaimed);
    }

    function test_Finalize_MultipleRequests() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Verify all requests created
        assertEq(withdrawalQueue.getLastRequestId(), 3);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);

        // Move time forward
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // Finalize all requests
        vm.prank(finalizeRoleHolder);
        uint256 finalizedCount = withdrawalQueue.finalize(10); // More than needed

        // Verify all finalized
        assertEq(finalizedCount, 3);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 3);

        // Check each request status
        for (uint256 i = 1; i <= 3; i++) {
            WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(i);
            assertTrue(status.isFinalized);
            assertFalse(status.isClaimed);
        }
    }

    function test_Finalize_PartialFinalization() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        assertEq(withdrawalQueue.getLastRequestId(), 3);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        vm.prank(finalizeRoleHolder);
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        assertEq(finalizedCount, 1);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 1);

        vm.prank(finalizeRoleHolder);
        uint256 remainingCount = withdrawalQueue.finalize(10);
        assertTrue(remainingCount > 0);
    }

    // Restrictions

    function test_Finalize_RevertMinDelayNotPassed() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Don't advance time enough
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME - 1);

        vm.prank(finalizeRoleHolder);
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        // Should finalize 0 requests due to time restriction
        assertEq(finalizedCount, 0);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);
    }

    function test_Finalize_RequestAfterReport() public {
        // Set oracle timestamp to current time
        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);

        // Move time forward and create request after report
        vm.warp(block.timestamp + 1 hours);

        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        vm.prank(finalizeRoleHolder);
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        // Should not finalize because request was created after last report
        assertEq(finalizedCount, 0);
    }

    function test_Finalize_RevertOnlyFinalizeRole() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // Try to finalize without proper role
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAlice,
                withdrawalQueue.FINALIZE_ROLE()
            )
        );
        vm.prank(userAlice);
        withdrawalQueue.finalize(1);
    }

    function test_Finalize_RevertWhenPaused() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // Pause the contract
        vm.prank(pauseRoleHolder);
        withdrawalQueue.pause();

        vm.prank(finalizeRoleHolder);
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        withdrawalQueue.finalize(1);
    }

    // Edge Cases

    function test_Finalize_ZeroMaxRequests() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        vm.prank(finalizeRoleHolder);
        vm.expectRevert(WithdrawalQueue.NoRequestsToFinalize.selector);
        uint256 finalizedCount = withdrawalQueue.finalize(0);
    }

    function test_Finalize_NoRequestsToFinalize() public {
        vm.prank(finalizeRoleHolder);
        vm.expectRevert(WithdrawalQueue.NoRequestsToFinalize.selector);
        withdrawalQueue.finalize(1);
    }

    function test_Finalize_AlreadyFullyFinalized() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // First finalization
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.finalize(1);

        // Try to finalize again
        vm.prank(finalizeRoleHolder);
        vm.expectRevert(WithdrawalQueue.NoRequestsToFinalize.selector);
        withdrawalQueue.finalize(1);
    }

    // Checkpoint Tests

    function test_Finalize_CreatesCheckpoint() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Verify no checkpoints initially
        assertEq(withdrawalQueue.getLastCheckpointIndex(), 0);

        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        vm.prank(finalizeRoleHolder);
        withdrawalQueue.finalize(1);

        // Verify checkpoint was created
        assertEq(withdrawalQueue.getLastCheckpointIndex(), 1);
    }

    // Emergency Exit

    function test_Finalize_DuringEmergencyExit() public {
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Set very old timestamp to make queue "stuck"
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);

        // Activate emergency exit
        withdrawalQueue.activateEmergencyExit();
        assertTrue(withdrawalQueue.isEmergencyExitActivated());

        // Should be able to finalize without role restriction in emergency
        vm.prank(userAlice); // Any user can call
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        assertEq(finalizedCount, 1);
    }
}
