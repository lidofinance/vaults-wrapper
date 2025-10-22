// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract EmergencyExitTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();

        // Deposit initial ETH to pool for withdrawals
        pool.depositETH{value: 1000 ether}();
    }

    // Basic Emergency Exit State

    function test_EmergencyExit_InitialState() public view {
        // Initially should not be activated
        assertFalse(withdrawalQueue.isEmergencyExitActivated());
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());
    }

    function test_EmergencyExit_QueueNotStuckWithoutRequests() public {
        // Empty queue should never be stuck
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());

        // Even after long time
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());
    }

    function test_EmergencyExit_QueueNotStuckWhenFullyFinalized() public {
        _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Queue should not be stuck even after long time
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());
    }

    // Queue Stuck Detection

    function test_EmergencyExit_QueueBecomesStuck() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Initially not stuck
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());

        // Still not stuck before max time
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS());
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());

        // Becomes stuck after max time
        vm.warp(block.timestamp + 1);
        assertTrue(withdrawalQueue.isWithdrawalQueueStuck());
    }

    function test_EmergencyExit_QueueStuckWithMultipleRequests() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);
        pool.requestWithdrawal(10 ** STV_DECIMALS);
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Advance time past max acceptable time for first request
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);

        assertTrue(withdrawalQueue.isWithdrawalQueueStuck());
    }

    // Emergency Exit Activation

    function test_EmergencyExit_SuccessfulActivation() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Make queue stuck
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        assertTrue(withdrawalQueue.isWithdrawalQueueStuck());

        // Anyone can activate emergency exit
        vm.prank(userAlice);
        vm.expectEmit(true, false, false, true);
        emit WithdrawalQueue.EmergencyExitActivated(block.timestamp);
        withdrawalQueue.activateEmergencyExit();

        assertTrue(withdrawalQueue.isEmergencyExitActivated());
    }

    function test_EmergencyExit_RevertWhenNotStuck() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Queue is not stuck yet
        assertFalse(withdrawalQueue.isWithdrawalQueueStuck());

        // Should revert when trying to activate
        vm.expectRevert(WithdrawalQueue.InvalidEmergencyExitActivation.selector);
        withdrawalQueue.activateEmergencyExit();
    }

    function test_EmergencyExit_RevertAlreadyActivated() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Make queue stuck and activate
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        withdrawalQueue.activateEmergencyExit();

        // Try to activate again
        vm.expectRevert(WithdrawalQueue.InvalidEmergencyExitActivation.selector);
        withdrawalQueue.activateEmergencyExit();
    }

    // Emergency Exit Effects on Operations

    function test_EmergencyExit_RequestsWorkWhenPaused() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Make queue stuck and activate emergency exit
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        withdrawalQueue.activateEmergencyExit();

        // Pause the contract
        vm.prank(pauseRoleHolder);
        withdrawalQueue.pause();

        // Should still be able to create requests in emergency exit
        pool.requestWithdrawal(10 ** STV_DECIMALS);
        assertEq(withdrawalQueue.getLastRequestId(), 2);
    }

    function test_EmergencyExit_FinalizationBypassesRoles() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Make queue stuck and activate emergency exit
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        withdrawalQueue.activateEmergencyExit();

        // Any user can finalize in emergency exit (no FINALIZE_ROLE needed)
        vm.prank(userBob);
        uint256 finalizedCount = withdrawalQueue.finalize(1);
        assertEq(finalizedCount, 1);
    }

    function test_EmergencyExit_FinalizationBypassesPause() public {
        pool.requestWithdrawal(10 ** STV_DECIMALS);

        // Make queue stuck and activate emergency exit
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);
        vm.warp(block.timestamp + withdrawalQueue.MAX_ACCEPTABLE_WQ_FINALIZATION_TIME_IN_SECONDS() + 1);
        withdrawalQueue.activateEmergencyExit();

        // Pause the contract
        vm.prank(pauseRoleHolder);
        withdrawalQueue.pause();

        // Should still be able to finalize in emergency exit
        vm.prank(userAlice);
        uint256 finalizedCount = withdrawalQueue.finalize(1);
        assertEq(finalizedCount, 1);
    }

    // Receive ETH for tests
    receive() external payable {}
}
