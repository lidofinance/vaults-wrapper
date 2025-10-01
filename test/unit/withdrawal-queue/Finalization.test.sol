// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract FinalizationTest is Test, SetupWithdrawalQueue {
    function test_Finalize_SimpleRequestAndFinalization() public {
        wrapper.depositETH{value: 10 ether}();

        uint256 stvBalance = wrapper.balanceOf(address(this));
        uint256 requestId = wrapper.requestWithdrawal(stvBalance);

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
}
