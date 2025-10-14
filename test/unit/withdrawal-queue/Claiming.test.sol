// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract ClaimingTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();

        // Deposit initial ETH to wrapper for withdrawals
        wrapper.depositETH{value: 100_000 ether}();
    }

    // Basic Claiming

    function test_ClaimWithdrawal_SuccessfulClaim() public {
        // Create and finalize a request
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Check initial state
        assertTrue(withdrawalQueue.getWithdrawalStatus(requestId).isFinalized);
        assertFalse(withdrawalQueue.getWithdrawalStatus(requestId).isClaimed);

        // Record initial ETH balance
        uint256 initialBalance = address(this).balance;
        uint256 claimableAmount = withdrawalQueue.getClaimableEther(requestId);
        assertTrue(claimableAmount > 0);

        // Claim the withdrawal
        wrapper.claimWithdrawal(requestId, address(this));

        // Verify claim succeeded
        assertTrue(withdrawalQueue.getWithdrawalStatus(requestId).isClaimed);
        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);
        assertEq(address(this).balance, initialBalance + claimableAmount);
    }

    function test_ClaimWithdrawal_ClaimToRecipient() public {
        // Create and finalize a request
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Claim to different recipient
        uint256 initialRecipientBalance = userAlice.balance;
        uint256 claimableAmount = withdrawalQueue.getClaimableEther(requestId);

        wrapper.claimWithdrawal(requestId, userAlice);

        // Verify ETH went to recipient
        assertEq(userAlice.balance, initialRecipientBalance + claimableAmount);
        assertTrue(withdrawalQueue.getWithdrawalStatus(requestId).isClaimed);
    }

    function test_ClaimWithdrawals_MultipleClaims() public {
        // Create and finalize multiple requests
        uint256 requestId1 = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);
        uint256 requestId2 = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);
        uint256 requestId3 = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Get hints for batch claiming
        uint256[] memory requestIds = new uint256[](3);
        requestIds[0] = requestId1;
        requestIds[1] = requestId2;
        requestIds[2] = requestId3;

        uint256[] memory hints = withdrawalQueue.findCheckpointHints(
            requestIds,
            1,
            withdrawalQueue.getLastCheckpointIndex()
        );

        // Record initial balance and claimable amounts
        uint256 initialBalance = address(this).balance;
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            totalClaimable += withdrawalQueue.getClaimableEther(requestIds[i]);
        }

        // Batch claim
        wrapper.claimWithdrawals(requestIds, hints, address(this));

        // Verify all claims
        for (uint256 i = 0; i < requestIds.length; i++) {
            assertTrue(withdrawalQueue.getWithdrawalStatus(requestIds[i]).isClaimed);
            assertEq(withdrawalQueue.getClaimableEther(requestIds[i]), 0);
        }
        assertEq(address(this).balance, initialBalance + totalClaimable);
    }

    // Error Cases

    function test_ClaimWithdrawals_RevertArraysLengthMismatch() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.ArraysLengthMismatch.selector, 1, 0));
        wrapper.claimWithdrawals(requestIds, hints, address(this));
    }

    function test_ClaimWithdrawal_RevertNotFinalized() public {
        uint256 requestId = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        // Try to claim before finalization
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.RequestNotFoundOrNotFinalized.selector, requestId));
        wrapper.claimWithdrawal(requestId, address(this));
    }

    function test_ClaimWithdrawal_RevertAlreadyClaimed() public {
        // Create and finalize a request
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Claim once
        wrapper.claimWithdrawal(requestId, address(this));

        // Try to claim again
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.RequestAlreadyClaimed.selector, requestId));
        wrapper.claimWithdrawal(requestId, address(this));
    }

    function test_ClaimWithdrawal_RevertWrongOwner() public {
        // Create and finalize a request
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        // Try to claim from different address
        vm.prank(userAlice);
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.NotOwner.selector, userAlice, address(this)));
        wrapper.claimWithdrawal(requestId, userAlice);
    }

    function test_ClaimWithdrawal_RevertInvalidRequestId() public {
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.InvalidRequestId.selector, 999));
        wrapper.claimWithdrawal(999, address(this));
    }

    function test_ClaimWithdrawal_RevertRecipientReverts() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);
        RevertingReceiver revertingRecipient = new RevertingReceiver();

        vm.expectRevert(WithdrawalQueue.CantSendValueRecipientMayHaveReverted.selector);
        wrapper.claimWithdrawal(requestId, address(revertingRecipient));
    }

    function test_ClaimWithdrawal_RevertIfNotWrapper() public {
        // Create and finalize a request
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.OnlyWrapperCan.selector));
        withdrawalQueue.claimWithdrawal(requestId, userAlice, userAlice);
    }

    // Edge Cases

    function test_ClaimWithdrawal_DefaultsRecipientToMsgSender() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);
        uint256 initialBalance = address(this).balance;
        uint256 claimableAmount = withdrawalQueue.getClaimableEther(requestId);

        wrapper.claimWithdrawal(requestId, address(0));

        assertEq(address(this).balance, initialBalance + claimableAmount);
    }

    function test_ClaimWithdrawal_PartiallyFinalizedQueue() public {
        // Create 3 requests but finalize only 2
        uint256 requestId1 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        uint256 requestId2 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        uint256 requestId3 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        _finalizeRequests(2); // Only finalize first 2

        // Can claim first 2
        wrapper.claimWithdrawal(requestId1, address(this));
        wrapper.claimWithdrawal(requestId2, address(this));

        // Cannot claim the third
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.RequestNotFoundOrNotFinalized.selector, requestId3));
        wrapper.claimWithdrawal(requestId3, address(this));
    }

    function test_ClaimWithdrawal_ClaimableEtherCalculation() public {
        uint256 requestedStv = 10 ** STV_DECIMALS;
        uint256 requestId = wrapper.requestWithdrawal(requestedStv);

        // Before finalization - should be 0
        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);

        _finalizeRequests(1);

        // After finalization - should be equal to previewRedeem (if stvRate didn't change)
        uint256 claimableAmount = withdrawalQueue.getClaimableEther(requestId);
        assertEq(claimableAmount, wrapper.previewRedeem(requestedStv));

        // After claiming - should be 0 again
        wrapper.claimWithdrawal(requestId, address(this));
        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);
    }

    function test_ClaimWithdrawals_DefaultRecipientToMsgSender() public {
        uint256[] memory requestIds = new uint256[](2);
        requestIds[0] = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);
        requestIds[1] = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        uint256[] memory hints = withdrawalQueue.findCheckpointHints(
            requestIds,
            1,
            withdrawalQueue.getLastCheckpointIndex()
        );

        uint256 initialBalance = address(this).balance;
        uint256 totalClaimable;
        for (uint256 i = 0; i < requestIds.length; ++i) {
            totalClaimable += withdrawalQueue.getClaimableEther(requestIds[i]);
        }

        wrapper.claimWithdrawals(requestIds, hints, address(0));

        assertEq(address(this).balance, initialBalance + totalClaimable);
    }

    function test_ClaimWithdrawals_RevertWithZeroHint() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = new uint256[](1);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.InvalidHint.selector, 0));
        wrapper.claimWithdrawals(requestIds, hints, address(this));
    }

    function test_ClaimWithdrawals_RevertWithOutOfRangeHint() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = new uint256[](1);
        hints[0] = withdrawalQueue.getLastCheckpointIndex() + 1;

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.InvalidHint.selector, hints[0]));
        wrapper.claimWithdrawals(requestIds, hints, address(this));
    }

    function test_GetClaimableEtherBatch_RevertArraysLengthMismatch() public {
        uint256 requestId = _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.ArraysLengthMismatch.selector, 1, 0));
        withdrawalQueue.getClaimableEther(requestIds, hints);
    }

    // Receive ETH for claiming tests
    receive() external payable {}
}

contract RevertingReceiver {
    receive() external payable {
        revert("Cannot receive");
    }
}
