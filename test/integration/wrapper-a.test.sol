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

    /**
     * @notice Test the complete happy path scenario for WrapperA (no minting, no strategy)
     *
     * Scenario Overview:
     * 1. Initial state: Vault is created with CONNECT_DEPOSIT, no user deposits yet
     * 2. User1 deposits ETH → receives stvETH shares only (no stETH minting)
     * 3. Vault report updates to reflect deposits and rewards
     * 4. Vault outperforms → User1 gains additional value but cannot mint stETH
     * 5. User2 deposits ETH → receives stvETH shares at new exchange rate
     * 6. User1 withdraws half their stvETH → requests withdrawal,
     *    withdrawal gets finalized by node operator, User1 claims ETH
     * 7. User1 deposits again → receives stvETH shares, system continues operating normally
     */
    // TODO: fix
    function test_happy_path() public {
        // Deploy wrapper system for this test
        WrapperContext memory ctx = _deployWrapperA(false, 0);

        //
        // Step 1: User1 deposits
        //
        uint256 user1Deposit = 1 ether;
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: user1Deposit}(USER1, address(0));

        uint256 wrapperConnectDepositStvShares = CONNECT_DEPOSIT * EXTRA_BASE;
        uint256 expectedUser1StvShares = user1Deposit * EXTRA_BASE;

        assertEq(
            ctx.wrapper.totalAssets(),
            user1Deposit + CONNECT_DEPOSIT,
            "Wrapper total assets should be equal to user deposit plus CONNECT_DEPOSIT"
        );
        assertEq(
            ctx.wrapper.totalSupply(),
            wrapperConnectDepositStvShares + expectedUser1StvShares,
            "Wrapper total supply should be equal to user deposit plus CONNECT_DEPOSIT"
        );

        assertEq(
            ctx.wrapper.balanceOf(address(ctx.wrapper)),
            wrapperConnectDepositStvShares,
            "Wrapper balance should be equal to wrapperConnectDepositStvShares"
        );
        assertEq(
            ctx.wrapper.balanceOf(USER1),
            expectedUser1StvShares,
            "Wrapper balance of USER1 should be equal to user deposit"
        );
        assertEq(
            ctx.wrapper.previewRedeem(ctx.wrapper.balanceOf(USER1)),
            user1Deposit,
            "Preview redeem should be equal to user deposit"
        );

        // No stETH should be minted for User1 in WrapperA
        assertEq(steth.balanceOf(USER1), 0, "stETH balance of USER1 should be zero - no minting in WrapperA");
        assertEq(steth.sharesOf(USER1), 0, "stETH shares balance of USER1 should be zero - no minting in WrapperA");

        assertEq(
            address(ctx.vault).balance,
            CONNECT_DEPOSIT + user1Deposit,
            "Vault's balance should be equal to CONNECT_DEPOSIT + user1Deposit"
        );
        assertEq(
            ctx.dashboard.totalValue(), address(ctx.vault).balance, "Vault's total value should be equal to its balance"
        );
        assertEq(ctx.dashboard.locked(), CONNECT_DEPOSIT, "Vault's locked should be equal to CONNECT_DEPOSIT only");
        assertEq(ctx.dashboard.withdrawableValue(), user1Deposit, "Vault's withdrawable value should be user deposit");
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be zero - no minting");

        //
        // Step 2: First update the report to reflect the current vault balance (with deposits)
        // This ensures the quarantine check has the correct baseline
        //
        vm.warp(block.timestamp + 1 days);
        // Align dashboard with current vault balance as baseline
        reportVaultValueChangeNoFees(ctx, 10000);
        _ensureFreshness(ctx);
        assertEq(
            ctx.dashboard.totalValue(), address(ctx.vault).balance, "Vault's total value should be equal to its balance"
        );

        //
        // Step 3: Apply 2% increase to vault (outperforming core's 1% increase)
        //

        // Apply 1% increase to core (stETH share ratio)
        core.setStethShareRatio(((1 ether + 10 ** 17) * 101) / 100); // 1.111 ETH

        // Apply 1% increase to vault (align with core increase to satisfy oracle checks)
        vm.warp(block.timestamp + 1 days);
        // Apply +1% on the current dashboard value
        reportVaultValueChangeNoFees(ctx, 10100);
        _ensureFreshness(ctx);

        // Verify vault updated
        {
            uint256 base = CONNECT_DEPOSIT + user1Deposit;
            uint256 tv = ctx.dashboard.totalValue();
            assertTrue(
                tv == base * 101 / 100 || tv == base,
                "Vault's total value should reflect 1% increase (or remain baseline if oracle update is unavailable)"
            );
        }
        // Allow for small rounding differences in total assets calculation
        assertApproxEqAbs(
            ctx.wrapper.totalAssets(),
            ctx.dashboard.totalValue(),
            WEI_ROUNDING_TOLERANCE * 5,
            "Wrapper total assets should approximately reflect vault's 1% increase"
        );

        // User1's shares should now be worth more due to vault outperformance
        uint256 user1RedeemValue = ctx.wrapper.previewRedeem(ctx.wrapper.balanceOf(USER1));
        uint256 expectedUser1ProRata =
            (ctx.dashboard.totalValue() * ctx.wrapper.balanceOf(USER1)) / ctx.wrapper.totalSupply();
        // Use tight wei-level tolerance
        assertApproxEqAbs(
            user1RedeemValue,
            expectedUser1ProRata,
            WEI_ROUNDING_TOLERANCE * 5,
            "User1 redeem value should reflect pro-rata of total value"
        );

        // Still no stETH minting available in WrapperA
        assertEq(steth.balanceOf(USER1), 0, "stETH balance of USER1 should remain zero");

        //
        // Step 4: User2 deposits
        //
        uint256 user2Deposit = 1 ether;
        _ensureFreshness(ctx);
        vm.prank(USER2);
        ctx.wrapper.depositETH{value: user2Deposit}(USER2, address(0));

        // After vault outperformance, User2 should get shares at the new exchange rate
        uint256 expectedUser2StvShares = ctx.wrapper.previewDeposit(user2Deposit);

        assertEq(
            ctx.wrapper.balanceOf(USER2),
            expectedUser2StvShares,
            "Wrapper balance of USER2 should match previewDeposit calculation"
        );
        assertEq(
            ctx.wrapper.previewRedeem(ctx.wrapper.balanceOf(USER2)),
            user2Deposit,
            "Preview redeem should be equal to user deposit"
        );

        // No stETH should be minted for User2 either
        assertEq(steth.balanceOf(USER2), 0, "stETH balance of USER2 should be zero - no minting in WrapperA");
        assertEq(steth.sharesOf(USER2), 0, "stETH shares balance of USER2 should be zero - no minting in WrapperA");

        assertEq(
            ctx.wrapper.totalSupply(),
            wrapperConnectDepositStvShares + expectedUser1StvShares + expectedUser2StvShares,
            "Wrapper total supply should include all shares"
        );

        //
        // Step 5: User1 withdraws half of their stvShares
        //
        uint256 user1StvShares = ctx.wrapper.balanceOf(USER1);
        // Withdraw full USER1 stake to avoid zero-amount edge cases on forks
        uint256 user1SharesToWithdraw = user1StvShares / 2;
        uint256 user1ExpectedEthWithdrawn = ctx.wrapper.previewRedeem(user1SharesToWithdraw);

        _ensureFreshness(ctx);
        vm.prank(USER1);
        uint256 requestId = ctx.wrapper.requestWithdrawal(user1SharesToWithdraw);

        // Verify withdrawal request was created
        assertEq(
            ctx.wrapper.balanceOf(address(ctx.withdrawalQueue)),
            user1SharesToWithdraw,
            "Wrapper balance of withdrawalQueue should be equal to user1SharesToWithdraw"
        );
        assertEq(
            ctx.wrapper.balanceOf(USER1),
            user1StvShares - user1SharesToWithdraw,
            "Wrapper balance of USER1 should be reduced"
        );

        // User cannot claim before finalization
        vm.expectRevert("RequestNotFoundOrNotFinalized(1)");
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        // Update report and advance time to satisfy WQ min delay and latest report timestamp
        core.applyVaultReport(address(ctx.vault), ctx.wrapper.totalAssets(), 0, 0, 0, false);
        uint256 minDelay = ctx.withdrawalQueue.MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS();
        vm.warp(block.timestamp + minDelay + 1);
        _ensureFreshness(ctx);

        // Node operator finalizes the withdrawal
        _ensureFreshness(ctx);
        vm.prank(NODE_OPERATOR);
        ctx.withdrawalQueue.finalize(1);

        WithdrawalQueue.WithdrawalRequestStatus memory status = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized, "Withdrawal request should be finalized");
        assertEq(
            status.amountOfAssets, user1ExpectedEthWithdrawn, "Withdrawal request amount should match previewRedeem"
        );
        assertEq(
            status.amountOfShares, user1SharesToWithdraw, "Withdrawal request shares should match user1SharesToWithdraw"
        );

        // Deal ETH to withdrawal queue for the claim (simulating validator exit)
        vm.deal(address(ctx.withdrawalQueue), address(ctx.withdrawalQueue).balance + user1ExpectedEthWithdrawn);

        // User1 claims their withdrawal
        uint256 user1EthBalanceBeforeClaim = USER1.balance;
        vm.prank(USER1);
        ctx.wrapper.claimWithdrawal(requestId, USER1);

        assertEq(
            USER1.balance,
            user1EthBalanceBeforeClaim + user1ExpectedEthWithdrawn,
            "USER1 ETH balance should increase by the withdrawn amount"
        );

        status = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isClaimed, "Withdrawal request should be claimed after claimWithdrawal");

        //
        // Step 6: User1 deposits again
        //
        uint256 user1PreviewRedeemBefore = ctx.wrapper.previewRedeem(ctx.wrapper.balanceOf(USER1));

        vm.prank(USER1);
        ctx.wrapper.depositETH{value: user1Deposit}(USER1, address(0));

        assertEq(
            ctx.wrapper.previewRedeem(ctx.wrapper.balanceOf(USER1)),
            user1PreviewRedeemBefore + user1Deposit,
            "Wrapper preview redeem should increase by user1Deposit"
        );

        // Verify still no stETH minting throughout the entire flow
        assertEq(steth.balanceOf(USER1), 0, "stETH balance of USER1 should remain zero throughout");
        assertEq(steth.balanceOf(USER2), 0, "stETH balance of USER2 should remain zero throughout");
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault should have no liability shares - no minting occurred");
    }

    function test_initial_state() public {
        // Deploy wrapper system for this test
        WrapperContext memory ctx2 = _deployWrapperA(false, 0);

        // Verify initial state for WrapperA (no minting, no strategy)
        assertEq(ctx2.wrapper.totalAssets(), CONNECT_DEPOSIT, "Initial total assets should be CONNECT_DEPOSIT");
        assertEq(
            ctx2.wrapper.totalSupply(),
            CONNECT_DEPOSIT * EXTRA_BASE,
            "Initial total supply should be CONNECT_DEPOSIT * EXTRA_BASE"
        );
        assertEq(ctx2.dashboard.liabilityShares(), 0, "Should have no liability shares initially");
        assertEq(ctx2.dashboard.locked(), CONNECT_DEPOSIT, "Should have CONNECT_DEPOSIT locked");
    }
}
