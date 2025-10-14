// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperAHarness} from "test/utils/WrapperAHarness.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Factory} from "src/Factory.sol";
import {WrapperA} from "src/WrapperA.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";

/**
 * @title WrapperATest
 * @notice Integration tests for WrapperA (no minting, no strategy)
 */
contract WrapperATest is WrapperAHarness {
    function setUp() public {
        _initializeCore();
    }

    function test_happy_path_deposit_request_finalize_claim() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei (above MIN_WITHDRAWAL_AMOUNT=100)
        uint256 depositAmount = 10_000;
        uint256 expectedStv = ctx.wrapper.previewDeposit(depositAmount);
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));
        assertEq(ctx.wrapper.balanceOf(USER1), expectedStv, "minted shares should match previewDeposit");
        assertEq(address(ctx.vault).balance, depositAmount + CONNECT_DEPOSIT, "vault balance should match deposit amount");

        // 2) USER1 immediately requests withdrawal of all their shares
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(expectedStv);

        // Expected ETH to withdraw
        uint256 expectedEth = ctx.wrapper.previewRedeem(expectedStv);
        // 3) Advance past min delay and ensure fresh report via harness
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // 4) Ensure report is fresh; ETH is already on the vault from deposit
        _ensureFreshness(ctx);

        // 5) Node Operator finalizes one request
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        // 6) USER1 claims
        uint256 userBalanceBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        assertEq(USER1.balance, userBalanceBefore + expectedEth, "user should receive expected ETH on claim");
    }

    function test_happy_path_deposit_request_finalize_claim_with_rewards_report() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei (above MIN_WITHDRAWAL_AMOUNT=100)
        uint256 depositAmount = 10_000;
        uint256 expectedStv = ctx.wrapper.previewDeposit(depositAmount);
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));
        assertEq(ctx.wrapper.balanceOf(USER1), expectedStv, "minted shares should match previewDeposit");
        assertEq(address(ctx.vault).balance, depositAmount + CONNECT_DEPOSIT, "vault balance should match deposit amount");

        // 2) USER1 immediately requests withdrawal of all their shares
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(expectedStv);

        // Expected ETH to withdraw is locked at request time
        uint256 expectedEth = ctx.wrapper.previewRedeem(expectedStv);
        assertEq(expectedEth, depositAmount, "expected eth should match deposit amount");
        // 3) Advance past min delay
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // 4) Apply +3% rewards via vault report BEFORE finalization
        //    This increases total value but should not discount the request
        reportVaultValueChangeNoFees(ctx, 10300); // +3%
        _ensureFreshness(ctx);

        // 5) Ensure report is fresh; ETH is already on the vault from deposit
        _ensureFreshness(ctx);

        // 6) Node Operator finalizes one request
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        // 7) USER1 claims
        uint256 userBalanceBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        // Expected claim equals the amount locked at request time (no discount on rewards)
        assertEq(USER1.balance, userBalanceBefore + expectedEth, "user should receive expected ETH on claim");
    }

    function test_happy_path_deposit_request_finalize_claim_with_rewards_report_before_request() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei (above MIN_WITHDRAWAL_AMOUNT=100)
        uint256 depositAmount = 10_000;
        uint256 expectedStv = ctx.wrapper.previewDeposit(depositAmount);
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));
        assertEq(ctx.wrapper.balanceOf(USER1), expectedStv, "minted shares should match previewDeposit");
        assertEq(address(ctx.vault).balance, depositAmount + CONNECT_DEPOSIT, "vault balance should match deposit amount");

        // 2) Apply +3% rewards via vault report BEFORE withdrawal request
        reportVaultValueChangeNoFees(ctx, 10300); // +3%
        _ensureFreshness(ctx);

        // 3) Now request withdrawal of all USER1 shares
        //    Expected ETH is increased by ~3% compared to initial deposit
        uint256 expectedEth = ctx.wrapper.previewRedeem(expectedStv);
        assertApproxEqAbs(expectedEth, (depositAmount * 103) / 100, WEI_ROUNDING_TOLERANCE, "expected eth should be ~+3% of deposit");

        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(expectedStv);
        // 4) Advance past min delay and ensure a fresh report after the request (required by WQ)
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // 5) Ensure report is fresh; ETH is already on the vault from deposit
        _ensureFreshness(ctx);

        // 6) Node Operator finalizes one request
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        // 7) USER1 claims and receives the increased amount
        uint256 userBalanceBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        assertApproxEqAbs(
            USER1.balance,
            userBalanceBefore + ((depositAmount * 103) / 100),
            WEI_ROUNDING_TOLERANCE,
            "user should receive ~deposit * 1.03 on claim"
        );
    }

    function test_finalize_reverts_after_loss_report_with_small_deposit() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei (above MIN_WITHDRAWAL_AMOUNT=100)
        uint256 depositAmount = 10_000;
        uint256 expectedStv = ctx.wrapper.previewDeposit(depositAmount);
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));
        assertEq(ctx.wrapper.balanceOf(USER1), expectedStv, "minted shares should match previewDeposit");
        assertEq(address(ctx.vault).balance, depositAmount + CONNECT_DEPOSIT, "vault balance should match deposit amount");

        // 2) USER1 immediately requests withdrawal of all their shares
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(expectedStv);

        // Expected ETH to withdraw is locked at request time (equals initial deposit for WrapperA)
        uint256 expectedEthAtRequest = ctx.wrapper.previewRedeem(expectedStv);
        assertEq(expectedEthAtRequest, depositAmount, "expected eth should match deposit amount at request time");

        // 3) Advance past min delay and ensure a fresh report after the request
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // 4) Apply -3% report BEFORE finalization (vault value decreases)
        reportVaultValueChangeNoFees(ctx, 9700); // -3%
        _ensureFreshness(ctx);

        // After the loss report, totalValue should be less than CONNECT_DEPOSIT
        assertLt(ctx.dashboard.totalValue(), CONNECT_DEPOSIT, "totalValue should be less than CONNECT_DEPOSIT after loss report");

        // Finalization should revert due to insufficient ETH to cover the request
        vm.prank(NODE_OPERATOR);
        vm.expectRevert();
        ctx.withdrawalQueue.finalize(1);
    }


    function test_withdrawal_request_finalized_after_reward_and_loss_reports() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // Simulate a +3% vault value report before deposit
        reportVaultValueChangeNoFees(ctx, 10300); // +3%
        _ensureFreshness(ctx);

        // 1) USER1 deposits 10_000 wei (above MIN_WITHDRAWAL_AMOUNT=100)
        uint256 depositAmount = 10_000;
        uint256 expectedStv = ctx.wrapper.previewDeposit(depositAmount);
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));

        // 2) USER1 requests withdrawal of all their shares
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(expectedStv);

        // 3) Advance past min delay and ensure a fresh report after the request (required by WQ)
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // 4) Simulate a -2% vault value report after the withdrawal request
        reportVaultValueChangeNoFees(ctx, 9800); // -2%
        _ensureFreshness(ctx);

        // 5) Ensure report is fresh; ETH is already on the vault from deposit
        _ensureFreshness(ctx);

        // 6) Node Operator finalizes one request
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        // 7) USER1 claims and receives the decreased amount
        uint256 userBalanceBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        assertApproxEqAbs(
            USER1.balance,
            userBalanceBefore + ((depositAmount * 98) / 100),
            WEI_ROUNDING_TOLERANCE,
            "user should receive ~deposit * 0.98 on claim"
        );
    }

    function test_partial_withdrawal_pro_rata_claim() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei
        uint256 depositAmount = 10_000;
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));

        // 2) USER1 creates two partial withdrawal requests that in total withdraw all shares
        uint256 userShares = ctx.wrapper.balanceOf(USER1);

        // First partial: half of user shares
        uint256 firstShares = userShares / 2;
        uint256 firstAssets = ctx.wrapper.previewRedeem(firstShares);
        vm.prank(USER1);
        uint256 requestId1 = ctx.wrapper.requestWithdrawal(firstShares);

        // Second partial: the remaining shares
        uint256 remainingShares = ctx.wrapper.balanceOf(USER1);
        uint256 secondShares = remainingShares;
        uint256 secondAssets = ctx.wrapper.previewRedeem(secondShares);
        vm.prank(USER1);
        uint256 requestId2 = ctx.wrapper.requestWithdrawal(secondShares);

        // 3) Advance past min delay and ensure fresh report
        _advancePastMinDelayAndRefreshReport(ctx, requestId2);

        // 4) Finalize both requests
        vm.prank(NODE_OPERATOR);
        uint256 finalized = ctx.withdrawalQueue.finalize(2);
        assertEq(finalized, 2, "should finalize both partial requests");

        // 5) Claim both and verify total equals sum of previews; user ends with zero shares
        uint256 userBalanceBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId1, USER1);
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId2, USER1);

        assertApproxEqAbs(
            USER1.balance,
            userBalanceBefore + firstAssets + secondAssets,
            WEI_ROUNDING_TOLERANCE * 2,
            "total claimed should equal sum of both previewRedeem values"
        );
        assertEq(ctx.wrapper.balanceOf(USER1), 0, "USER1 should have no stv shares remaining");
    }

    function test_finalize_batch_stops_then_completes_when_funded() public {
        // Deploy wrapper system
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // 1) USER1 deposits 10_000 wei
        uint256 depositAmount = 10_000;
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));

        // 2) Create two split withdrawal requests
        uint256 userShares = ctx.wrapper.balanceOf(USER1);
        uint256 firstShares = userShares / 3; // ~33%
        uint256 secondShares = userShares / 2; // ~50%
        uint256 firstAssets = ctx.wrapper.previewRedeem(firstShares);
        uint256 secondAssets = ctx.wrapper.previewRedeem(secondShares);

        vm.startPrank(USER1);
        uint256 requestId1 = ctx.wrapper.requestWithdrawal(firstShares);
        uint256 requestId2 = ctx.wrapper.requestWithdrawal(secondShares);
        vm.stopPrank();

        // 3) Advance past min delay for both
        _advancePastMinDelayAndRefreshReport(ctx, requestId2);

        // 4) Move all withdrawable out to CL, then return only enough for the first via CL (insufficient for second)
        _depositToCL(ctx);
        _ensureFreshness(ctx);
        _withdrawFromCL(ctx, firstAssets);
        _ensureFreshness(ctx);

        vm.prank(NODE_OPERATOR);
        uint256 finalized = ctx.withdrawalQueue.finalize(2);
        assertEq(finalized, 1, "should finalize only the first request due to insufficient withdrawable");

        // 5) Claim first, second remains unfinalized
        uint256 userBalBefore = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId1, USER1);
        assertApproxEqAbs(USER1.balance, userBalBefore + firstAssets, WEI_ROUNDING_TOLERANCE);

        // 6) Return remaining via CL and finalize second
        _withdrawFromCL(ctx, secondAssets);
        _ensureFreshness(ctx);

        vm.prank(NODE_OPERATOR);
        finalized = ctx.withdrawalQueue.finalize(1);
        assertEq(finalized, 1, "second request should now finalize after funding");

        // 7) Claim second
        uint256 userBalBefore2 = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId2, USER1);
        assertApproxEqAbs(USER1.balance, userBalBefore2 + secondAssets, WEI_ROUNDING_TOLERANCE);
    }

    function test_initial_state() public {
        WrapperContext memory ctx2 = _deployWrapperA(false, 0);
        _checkInitialState(ctx2);
    }

    /**
     * @notice Test deploying a wrapper with custom configuration (allowlist enabled)
     */
    function test_custom_deployment_with_allowlist() public {
        // Deploy wrapper with allowlist enabled
        WrapperContext memory custom = _deployWrapperA(true, 0);

        // Verify the custom wrapper was deployed with allowlist enabled
        assertTrue(custom.wrapper.ALLOW_LIST_ENABLED(), "Custom wrapper should have allowlist enabled");

        // Deploy another wrapper without allowlist to compare
        WrapperContext memory def = _deployWrapperA(false, 0);

        // Verify the wrappers are different instances
        assertTrue(address(custom.wrapper) != address(def.wrapper), "Custom wrapper should be different from default");
        assertTrue(
            address(custom.withdrawalQueue) != address(def.withdrawalQueue),
            "Custom queue should be different from default"
        );
        assertFalse(def.wrapper.ALLOW_LIST_ENABLED(), "Default wrapper should not have allowlist enabled");
    }

    function test_claim_before_finalization_reverts_then_succeeds_after_finalize() public {
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        // Deposit and request
        uint256 depositAmount = 10_000;
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: depositAmount}(USER1, address(0));
        uint256 userShares = ctx.wrapper.balanceOf(USER1);
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(userShares);

        // Claim before finalize reverts
        vm.expectRevert("RequestNotFoundOrNotFinalized(1)");
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        // Satisfy min delay and freshness
        _advancePastMinDelayAndRefreshReport(ctx, requestId);

        // Finalize
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        // Claim succeeds
        uint256 before = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);
        assertApproxEqAbs(USER1.balance, before + depositAmount, WEI_ROUNDING_TOLERANCE);
    }

}
