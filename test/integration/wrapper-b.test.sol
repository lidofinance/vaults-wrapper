// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperHarness} from "test/utils/WrapperHarness.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

/**
 * @title WrapperBTest
 * @notice Integration tests for WrapperB (minting, no strategy)
 */
contract WrapperBTest is WrapperHarness {

    function setUp() public override {
        super.setUp();
    }


    // TODO: add after report invariants
    // TODO: add after deposit invariants
    // TODO: add after requestWithdrawal invariants
    // TODO: add after finalizeWithdrawal invariants
    // TODO: add after claimWithdrawal invariants

    /**
     * @notice Test the complete happy path scenario for WrapperB (minting, no strategy)
     *
     * Scenario Overview:
     * 1. Initial state: Vault is created with CONNECT_DEPOSIT, no user deposits yet
     * 2. User1 deposits ETH → receives stvETH shares, gets stETH minted based on reserve ratio
     * 3. Vault report updates to reflect deposits and 1% stETH price increase
     * 4. Vault outperforms (2% increase vs 1% stETH increase) → User1 gains additional minting capacity
     * 5. User2 deposits ETH → receives stvETH shares at new exchange rate after vault outperformance
     * 6. User1 withdraws half their stvETH → requests withdrawal, approves stETH transfer,
     *    withdrawal gets finalized by node operator, User1 claims ETH
     * 7. User1 deposits again → receives stvETH shares, system continues operating normally
     */
    function test_happy_path() public {
        console.log("=== Scenario 1 (all fees are zero) ===");

        //
        // Step 1: User1 deposits
        //

        uint256 user1Deposit = 10_000 wei;
        vm.prank(USER1);
        wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 1");

        uint256 wrapperConnectDepositStvShares = CONNECT_DEPOSIT * EXTRA_BASE;
        uint256 expectedUser1StvShares = user1Deposit * EXTRA_BASE;
        uint256 expectedUser1Steth = user1Deposit * (TOTAL_BASIS_POINTS - RESERVE_RATIO_BP) / TOTAL_BASIS_POINTS - 1; // 7999
        uint256 expectedUser1StethShares = steth.getSharesByPooledEth(expectedUser1Steth + 1); // 7272

        assertEq(wrapper.totalAssets(), user1Deposit + CONNECT_DEPOSIT, "Wrapper total assets should be equal to user deposit plus CONNECT_DEPOSIT");
        // assertEq(wrapper.totalSupply(), wrapperConnectDepositStvShares + expectedUser1StvShares, "Wrapper total supply should be equal to user deposit plus CONNECT_DEPOSIT");

        assertEq(wrapper.balanceOf(address(wrapper)), wrapperConnectDepositStvShares, "Wrapper balance should be equal to wrapperConnectDepositStvShares");
        assertEq(wrapper.balanceOf(USER1), expectedUser1StvShares, "Wrapper balance of USER1 should be equal to user deposit");
        assertEq(steth.sharesOf(USER1), expectedUser1StethShares, "stETH shares balance of USER1 should be equal to user deposit");
        assertEq(steth.balanceOf(USER1), expectedUser1Steth, "stETH balance of USER1 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER1)), user1Deposit, "Preview redeem should be equal to user deposit");
        assertEq(wrapper.mintableStShares(USER1), 0, "Mintable stETH shares should be equal to 0");

        assertEq(address(vault).balance, CONNECT_DEPOSIT + user1Deposit, "Vault's balance should be equal to CONNECT_DEPOSIT + user1Deposit");
        assertEq(dashboard.totalValue(), address(vault).balance, "Vault's total value should be equal to its balance");
        assertEq(dashboard.maxLockableValue(), address(vault).balance, "Vault's total value should be equal to its balance");
        assertEq(dashboard.locked(), CONNECT_DEPOSIT + 8000, "Vault's locked should be equal to CONNECT_DEPOSIT");
        assertEq(dashboard.withdrawableValue(), 2000, "Vault's withdrawable value should be zero");
        assertEq(dashboard.liabilityShares(), 7272, "Vault's liability shares should be zero");
        assertEq(dashboard.totalMintingCapacityShares(), 9090, "Total minting capacity should be 9090");
        assertEq(dashboard.remainingMintingCapacityShares(0), 9090 - 7272, "Remaining minting capacity should be zero");

        //
        // Step 2: First update the report to reflect the current vault balance (with deposits)
        // This ensures the quarantine check has the correct baseline
        //

        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(vault), address(vault).balance, 0, 0, 0, false);
        assertEq(dashboard.totalValue(), address(vault).balance, "Vault's total value should be equal to its balance");
        assertEq(wrapper.mintableStShares(USER1), 0, "Mintable stETH shares should be equal to 0");

        _assertUniversalInvariants("Step 2");

        //
        // Step 3: Now apply the 1% increase to both core and vault
        //

        core.setStethShareRatio(((1 ether + 10**17) * 101) / 100); // 1.111 ETH

        uint256 newTotalValue = (CONNECT_DEPOSIT + user1Deposit) * 101 / 100;
        uint256 newUser1Steth = user1Deposit * 101 / 100;
        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(vault), newTotalValue, 0, 0, 0, false);

        _assertUniversalInvariants("Step 3");

        assertEq(address(vault).balance, CONNECT_DEPOSIT + user1Deposit, "Vault's balance should be equal to CONNECT_DEPOSIT + user1Deposit");
        assertEq(dashboard.totalValue(), newTotalValue, "Vault's total value should be equal to its balance");
        assertEq(dashboard.maxLockableValue(), newTotalValue, "Vault's total value should be equal to its balance");
        assertEq(wrapper.totalAssets(), newTotalValue, "Wrapper total assets should be equal to new total value minus CONNECT_DEPOSIT");

        assertEq(wrapper.balanceOf(USER1), user1Deposit * EXTRA_BASE, "Wrapper balance of USER1 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER1)), newUser1Steth, "Preview redeem should be equal to user deposit * 101 / 100");
        assertEq(wrapper.mintableStShares(USER1), 0, "Mintable stETH shares should be equal to 0 because vault performed same as core");

        //
        // Step 3b: Vault outperforms - core increases by 1%, vault increases by 2%
        //

        // Apply 1% increase to core (stETH share ratio)
        core.setStethShareRatio(((1 ether + 10**17) * 102) / 100); // 1.122 ETH (another 1% on top of previous 1%)

        // Apply 2% increase to vault (on top of previous 1%)
        uint256 vaultValue2Pct = (CONNECT_DEPOSIT + user1Deposit) * 103 / 100; // 2% total increase from step 2
        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(vault), vaultValue2Pct, 0, 0, 0, false);

        _assertUniversalInvariants("Step 3b");

        // Verify vault outperformed
        assertEq(dashboard.totalValue(), vaultValue2Pct, "Vault's total value should reflect 2% increase");
        assertEq(wrapper.totalAssets(), vaultValue2Pct, "Wrapper total assets should reflect vault's 2% increase");

        // User1 should now be able to mint more stETH since vault outperformed
        uint256 expectedUser1MintableStSharesAfterOutperformance = 72;

        // Calculate expected mintable shares based on vault outperformance
        // Vault increased 2% total (103/100), Core increased 1% total (102/100)
        // The 1% outperformance on USER1's share should allow additional minting
        // User1 has 10099 wei worth of assets after step 3, now worth 10299 after step 3b
        // Already minted 7272 shares, can mint more based on the 200 wei gain (2% - 1% on 10000)

        // The exact calculation: outperformance allows minting against the extra value
        // Extra value from outperformance = 10299 - 10099 = 200 wei
        // Max additional mintable = 200 * 80% / 1.122 = ~142 shares (accounting for reserve ratio and stETH price)
        // But actual calculation is: total max mintable (7344) - already minted (7272) = 72 shares

        assertEq(wrapper.mintableStShares(USER1), expectedUser1MintableStSharesAfterOutperformance, "User1 should be able to mint exactly 72 additional stETH shares after vault outperformed");

        // Preview redeem should show increased value due to vault outperformance
        uint256 user1RedeemValue = wrapper.previewRedeem(wrapper.balanceOf(USER1));
        assertGt(user1RedeemValue, newUser1Steth, "User1 redeem value should be higher after vault outperformance");
        assertEq(user1RedeemValue, user1Deposit * 103 / 100, "User1 redeem value should reflect 2% total increase");

        //
        // Step 4: User2 deposits
        //

        uint256 user2Deposit = 10_000 wei;
        vm.prank(USER2);
        wrapper.depositETH{value: user2Deposit}(USER2);

        _assertUniversalInvariants("Step 4");

        // After vault outperformance, the share calculation changes
        uint256 expectedUser2StvShares = wrapper.previewDeposit(user2Deposit); // Calculate based on current state
        uint256 expectedUser2Steth = user2Deposit * (TOTAL_BASIS_POINTS - RESERVE_RATIO_BP) / TOTAL_BASIS_POINTS - 1; // 7999
        uint256 expectedUser2StethShares = steth.getSharesByPooledEth(expectedUser2Steth + 1); // Should be around 7134 with new stETH ratio

        assertEq(steth.sharesOf(USER2), expectedUser2StethShares, "stETH shares balance of USER2 should be equal to user deposit");
        assertEq(steth.balanceOf(USER2), expectedUser2Steth, "stETH balance of USER2 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER2)), user2Deposit, "Preview redeem should be equal to user deposit");
        assertEq(wrapper.balanceOf(USER2), expectedUser2StvShares, "Wrapper balance of USER2 should match previewDeposit calculation");

        assertEq(wrapper.totalSupply(), wrapperConnectDepositStvShares + expectedUser1StvShares + expectedUser2StvShares, "Wrapper total supply should be equal to user deposit plus CONNECT_DEPOSIT");
        assertEq(wrapper.previewRedeem(wrapper.totalSupply()), vaultValue2Pct + user2Deposit, "Preview redeem should be equal to vault value after 2% increase plus user2Deposit");

        assertEq(wrapper.mintableStShares(USER1), expectedUser1MintableStSharesAfterOutperformance, "User1 should be able to mint exactly 72 additional stETH shares after vault outperformed");

        //
        // Step 5: User1 withdraws half of his stvShares
        //

        uint256 user1StvShares = wrapper.balanceOf(USER1);
        uint256 user1StSharesToWithdraw = user1StvShares / 2;
        uint256 user1ExpectedEthWithdrawn = wrapper.previewRedeem(user1StSharesToWithdraw);

        // User1 requests withdrawal of half his shares, expect ALLOWANCE_EXCEEDED revert
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        vm.prank(USER1);
        wrapper.requestWithdrawal(user1StSharesToWithdraw);

        _assertUniversalInvariants("Step 5.1");

        vm.startPrank(USER1);

        uint256 user1StSharesToReturn = wrapper.stSharesForWithdrawal(USER1, user1StSharesToWithdraw);
        uint256 user1StethToApprove = steth.getPooledEthByShares(user1StSharesToReturn);
        // NB: allowance is nominated in stETH not its shares
        steth.approve(address(wrapper), user1StethToApprove);
        uint256 requestId = wrapper.requestWithdrawal(user1StSharesToWithdraw);
        // TODO: compare with dashboard.liabilityShares() here

        vm.expectRevert("RequestNotFoundOrNotFinalized(1)");
        wrapper.claimWithdrawal(requestId, USER1);

        vm.stopPrank();

        assertEq(wrapper.balanceOf(address(withdrawalQueue)), user1StSharesToWithdraw, "Wrapper balance of withdrawalQueue should be equal to user1StSharesToWithdraw");
        assertEq(wrapper.balanceOf(USER1), user1StvShares - user1StSharesToWithdraw, "Wrapper balance of USER1 should be equal to user1StvShares minus user1StSharesToWithdraw");

        uint256 wqBalanceBefore = wrapper.balanceOf(address(withdrawalQueue));

        vm.prank(NODE_OPERATOR);
        withdrawalQueue.finalize(requestId);
        // TODO: compare with dashboard.liabilityShares() here

        uint256 wqBalanceAfter = wrapper.balanceOf(address(withdrawalQueue));
        // TODO: restore the check (there is a problem in the contracts)
        assertEq(
            wqBalanceBefore - wqBalanceAfter,
            user1StSharesToWithdraw,
            "Wrapper balance of withdrawalQueue should decrease by shares of the finalized request"
        );

        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized, "Withdrawal request should be finalized");
        assertEq(status.amountOfAssets, user1ExpectedEthWithdrawn, "Withdrawal request amount should match previewRedeem");
        assertEq(status.amountOfShares, user1StSharesToWithdraw, "Withdrawal request shares should match user1StSharesToWithdraw");

        // TODO: remove this vm.deal when WQ / setup is fixed
        vm.deal(address(withdrawalQueue), address(withdrawalQueue).balance + user1ExpectedEthWithdrawn);

        uint256 user1EthBalanceBeforeClaim = USER1.balance;
        vm.prank(USER1);
        wrapper.claimWithdrawal(requestId, USER1);

        assertEq(USER1.balance, user1EthBalanceBeforeClaim + user1ExpectedEthWithdrawn, "USER1 ETH balance should increase by the withdrawn amount after claim");

        _assertUniversalInvariants("Step 5.2");

        status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isClaimed, "Withdrawal request should be claimed after claimWithdrawal");

        //
        // Step 6: User1 deposits the same amount of ETH as deposited initially
        //

        uint256 user1PreviewRedeemBefore = wrapper.previewRedeem(wrapper.balanceOf(USER1));

        vm.prank(USER1);
        wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 6");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER1)), user1PreviewRedeemBefore + user1Deposit, "Wrapper preview redeem should be equal to user1PreviewRedeemBefore plus user1Deposit");

    }

    // ========================================================================
    // Helper functions
    // ========================================================================

    // _contextMsg has been moved to WrapperHarness

}