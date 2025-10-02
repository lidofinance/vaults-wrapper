// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract RequestCreationTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();

        vm.prank(userAlice);
        wrapper.depositETH{value: 100 ether}();

        vm.prank(userBob);
        wrapper.depositETH{value: 100 ether}();

        // from test contract
        wrapper.depositETH{value: 100_000 ether}();
    }

    // Initial State Tests

    function test_InitialState_NoRequests() public view {
        assertEq(withdrawalQueue.getLastRequestId(), 0);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);
        assertEq(withdrawalQueue.unfinalizedRequestNumber(), 0);
        assertEq(withdrawalQueue.unfinalizedAssets(), 0);
        assertEq(withdrawalQueue.unfinalizedStv(), 0);
    }

    function test_InitialState_CorrectRoles() public view {
        assertTrue(withdrawalQueue.hasRole(withdrawalQueue.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(withdrawalQueue.hasRole(withdrawalQueue.FINALIZE_ROLE(), finalizeRoleHolder));
        assertTrue(withdrawalQueue.hasRole(withdrawalQueue.PAUSE_ROLE(), pauseRoleHolder));
        assertTrue(withdrawalQueue.hasRole(withdrawalQueue.RESUME_ROLE(), resumeRoleHolder));
    }

    function test_InitialState_NotPaused() public view {
        assertFalse(withdrawalQueue.paused());
    }

    // Single Request Tests

    function test_RequestWithdrawal_SingleRequest() public {
        uint256 stvToRequest = 10 ** STV_DECIMALS;
        uint256 requestId = wrapper.requestWithdrawal(stvToRequest);

        assertEq(requestId, 1);
        assertEq(withdrawalQueue.getLastRequestId(), 1);
        assertEq(withdrawalQueue.unfinalizedRequestNumber(), 1);
        assertEq(withdrawalQueue.unfinalizedStv(), stvToRequest);

        // Check request details
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertEq(status.amountOfStv, stvToRequest);
        assertEq(status.amountOfAssets, 1 ether); // 1 STV = 1 ETH at initial rate
        assertEq(status.amountOfStethShares, 0);
        assertEq(status.owner, address(this));
        assertEq(status.timestamp, block.timestamp);
        assertFalse(status.isFinalized);
        assertFalse(status.isClaimed);
    }

    function test_RequestWithdrawal_EmitsCorrectEvent() public {
        uint256 expectedAssets = wrapper.previewRedeem(10 ** STV_DECIMALS);

        vm.expectEmit(true, true, true, true);
        emit WithdrawalQueue.WithdrawalRequested(1, address(this), 10 ** STV_DECIMALS, 0, expectedAssets);

        wrapper.requestWithdrawal(10 ** STV_DECIMALS);
    }

    function test_RequestWithdrawal_WithStethShares() public {
        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        wrapper.mintStethShares(mintedStethShares);
        uint256 requestId = wrapper.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertEq(status.amountOfStv, stvToRequest);
        assertEq(status.amountOfStethShares, mintedStethShares);
        assertEq(status.owner, address(this));
    }

    function test_RequestWithdrawal_UpdatesCumulativeValues() public {
        vm.prank(userAlice);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.prank(userBob);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS * 2);

        assertEq(withdrawalQueue.unfinalizedStv(), 10 ** STV_DECIMALS * 3);
        assertEq(withdrawalQueue.getLastRequestId(), 2);

        // Check individual request amounts
        WithdrawalQueue.WithdrawalRequestStatus memory status1 = withdrawalQueue.getWithdrawalStatus(1);
        WithdrawalQueue.WithdrawalRequestStatus memory status2 = withdrawalQueue.getWithdrawalStatus(2);

        assertEq(status1.amountOfStv, 10 ** STV_DECIMALS);
        assertEq(status2.amountOfStv, 10 ** STV_DECIMALS * 2);
    }

    function test_RequestWithdrawal_AddToUserRequests() public {
        uint256 requestId1 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        uint256 requestId2 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        uint256[] memory requests = withdrawalQueue.getWithdrawalRequests(address(this));
        assertEq(requests.length, 2);
        assertEq(requests[0], requestId1);
        assertEq(requests[1], requestId2);

        // Bob should have no requests
        uint256[] memory bobRequests = withdrawalQueue.getWithdrawalRequests(userBob);
        assertEq(bobRequests.length, 0);
    }

    // Multiple requests tests

    function test_RequestWithdrawals_MultipleInSingleCall() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10 ** STV_DECIMALS;
        amounts[1] = 10 ** STV_DECIMALS * 2;
        amounts[2] = 10 ** STV_DECIMALS;

        uint256[] memory requestIds = wrapper.requestWithdrawals(amounts, userAlice);

        assertEq(requestIds.length, 3);
        assertEq(requestIds[0], 1);
        assertEq(requestIds[1], 2);
        assertEq(requestIds[2], 3);
        assertEq(withdrawalQueue.getLastRequestId(), 3);

        // Check individual amounts
        WithdrawalQueue.WithdrawalRequestStatus memory status1 = withdrawalQueue.getWithdrawalStatus(1);
        WithdrawalQueue.WithdrawalRequestStatus memory status2 = withdrawalQueue.getWithdrawalStatus(2);
        WithdrawalQueue.WithdrawalRequestStatus memory status3 = withdrawalQueue.getWithdrawalStatus(3);

        assertEq(status1.amountOfStv, amounts[0]);
        assertEq(status2.amountOfStv, amounts[1]);
        assertEq(status3.amountOfStv, amounts[2]);
    }

    function test_RequestWithdrawals_DifferentUsers() public {
        vm.prank(userAlice);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        vm.prank(userBob);
        wrapper.requestWithdrawal(2 * 10 ** STV_DECIMALS);

        vm.prank(userAlice);
        wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        uint256[] memory aliceRequests = withdrawalQueue.getWithdrawalRequests(userAlice);
        uint256[] memory bobRequests = withdrawalQueue.getWithdrawalRequests(userBob);

        assertEq(aliceRequests.length, 2);
        assertEq(bobRequests.length, 1);
        assertEq(aliceRequests[0], 1);
        assertEq(aliceRequests[1], 3);
        assertEq(bobRequests[0], 2);
    }

    // Validation tests

    function test_RequestWithdrawal_RevertOnTooSmallAmount() public {
        uint256 tinyStvAmount = wrapper.previewWithdraw(withdrawalQueue.MIN_WITHDRAWAL_AMOUNT()) - 1;
        uint256 expectedAssets = wrapper.previewRedeem(tinyStvAmount);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.RequestAmountTooSmall.selector, expectedAssets));
        wrapper.requestWithdrawal(tinyStvAmount, userAlice);
    }

    function test_RequestWithdrawal_RevertOnTooLargeAmount() public {
        uint256 extraAssetsWei = 10 ** (STV_DECIMALS - ASSETS_DECIMALS);
        uint256 hugeStvAmount = wrapper.previewWithdraw(withdrawalQueue.MAX_WITHDRAWAL_AMOUNT()) + extraAssetsWei;
        uint256 expectedAssets = wrapper.previewRedeem(hugeStvAmount);

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.RequestAmountTooLarge.selector, expectedAssets));
        wrapper.requestWithdrawal(hugeStvAmount, userAlice);
    }

    function test_RequestWithdrawal_RevertOnlyWrapper() public {
        vm.prank(userAlice);
        vm.expectRevert(WithdrawalQueue.OnlyWrapperCan.selector);
        withdrawalQueue.requestWithdrawal(10 ** STV_DECIMALS, 0, userAlice);
    }

    function test_RequestWithdrawal_RevertWhenPaused() public {
        vm.prank(pauseRoleHolder);
        withdrawalQueue.pause();

        vm.prank(address(wrapper));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        withdrawalQueue.requestWithdrawal(10 ** STV_DECIMALS, 0, userAlice);
    }

    // Edge cases

    function test_RequestWithdrawal_ZeroOwnerDefaultsToMsgSender() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ** STV_DECIMALS;

        uint256[] memory requestIds = wrapper.requestWithdrawals(amounts, address(0));

        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestIds[0]);
        assertEq(status.owner, address(this)); // Should default to msg.sender
    }

    function test_RequestWithdrawal_ExactMinAmount() public {
        // Calculate STV amount needed for MIN_WITHDRAWAL_AMOUNT
        uint256 minAmount = withdrawalQueue.MIN_WITHDRAWAL_AMOUNT();
        uint256 stvAmount = wrapper.previewWithdraw(minAmount);

        // This should succeed
        uint256 requestId = wrapper.requestWithdrawal(stvAmount);
        assertEq(requestId, 1);
    }

    function test_RequestWithdrawal_ExactMaxAmount() public {
        // Calculate STV amount needed for MAX_WITHDRAWAL_AMOUNT
        uint256 maxAmount = withdrawalQueue.MAX_WITHDRAWAL_AMOUNT();
        uint256 stvAmount = wrapper.previewWithdraw(maxAmount);

        // This should succeed
        uint256 requestId = wrapper.requestWithdrawal(stvAmount);
        assertEq(requestId, 1);
    }
}
