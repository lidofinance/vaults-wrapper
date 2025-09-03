// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {DefiWrapper} from "test/utils/DefiWrapper.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {Wrapper} from "src/Wrapper.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract WithdrawalTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;
    
    // Access to harness components
    Wrapper public wrapper;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    IStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core), address(0));

        wrapper = dw.wrapper();
        withdrawalQueue = dw.withdrawalQueue();
        strategy = dw.strategy();
        dashboard = dw.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = dw.stakingVault();

        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);

        assertEq(TOTAL_BP, core.LIDO_TOTAL_BASIS_POINTS(), "TOTAL_BP should be equal to LIDO_TOTAL_BASIS_POINTS");
    }

    // Tests the complete withdrawal flow without stETH minting or leverage strategies
    // Verifies: deposit ETH → request withdrawal → validator exit simulation → finalization → claim ETH
    function test_withdrawalSimplestHappyPath() public {
        uint256 userInitialETH = 10_000 wei;

        console.log("=== Case 4: Withdrawal simplest happy path (no stETH minted, no boost) ===");

        // Phase 1: User deposits ETH
        console.log("=== Phase 1: User deposits ETH ===");
        vm.deal(user1, userInitialETH);

        vm.startPrank(user1);
        uint256 userStvShares = wrapper.depositETH{value: userInitialETH}(user1);
        vm.stopPrank();

        console.log("User deposited ETH:", userInitialETH);
        console.log("User received stvETH shares:", userStvShares);

        // Verify initial state - user has shares, no stETH minted, no boost
        assertEq(wrapper.balanceOf(user1), userStvShares, "User should have stvETH shares");
        assertEq(wrapper.totalAssets(), userInitialETH + dw.CONNECT_DEPOSIT(), "Total assets should equal user deposit plus initial balance");
        assertEq(user1.balance, 0, "User ETH balance should be zero after deposit");
        assertEq(wrapper.lockedStvSharesByUser(user1), 0, "User should have no locked shares (no stETH minted)");

        // Phase 2: User requests withdrawal
        console.log("=== Phase 2: User requests withdrawal ===");

        // Withdraw based on actual shares received (which may be slightly less due to rounding)
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = wrapper.convertToAssets(userStvShares);

        vm.startPrank(user1);
        wrapper.approve(address(withdrawalQueue), userStvShares);
        uint256[] memory requestIds = withdrawalQueue.requestWithdrawals(withdrawalAmounts, user1);
        vm.stopPrank();

        console.log("Withdrawal requested. RequestIds:", requestIds.length);
        console.log("Withdrawal amount:", withdrawalAmounts[0]);

        // Verify withdrawal request state
        assertGt(requestIds.length, 0, "Request ID should be valid");
        assertEq(wrapper.balanceOf(user1), 0, "User stvETH shares should be moved to withdrawal queue for withdrawal");

        // Check withdrawal queue state using getWithdrawalStatus
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestIds[0]);
        assertEq(status.amountOfAssets, withdrawalAmounts[0], "Requested amount should match");
        assertEq(status.owner, user1, "Owner should be user1");
        assertFalse(status.isFinalized, "Request should not be finalized yet");
        assertFalse(status.isClaimed, "Request should not be claimed yet");

        // Phase 3: Simulate validator operations and ETH flow
        console.log("=== Phase 3: Simulate validator operations ===");

        // Simulate validators receiving ETH using CoreHarness
        uint256 stakingVaultBalance = address(stakingVault).balance;
        console.log("Staking vault balance before beacon chain transfer:", stakingVaultBalance);

        uint256 transferredAmount = core.mockValidatorsReceiveETH(address(stakingVault));
        console.log("ETH sent to beacon chain:", transferredAmount);

        // Phase 4: Calculate finalization batches and requirements
        console.log("=== Phase 4: Calculate finalization requirements ===");

        uint256 remainingEthBudget = withdrawalQueue.unfinalizedAssets();
        console.log("Unfinalized assets requiring ETH:", remainingEthBudget);

        // Calculate exact ETH needed for finalization
        uint256 shareRate = withdrawalQueue.calculateCurrentShareRate();

        uint256 ethToLock = 100 ether;

        console.log("ETH required for finalization:", ethToLock);
        console.log("Current share rate:", shareRate);

        // Phase 5: Simulate validator exit and ETH return
        console.log("=== Phase 5: Simulate validator exit and ETH return ===");

        // Simulate validator exit returning ETH to staking vault using CoreHarness
        core.mockValidatorExitReturnETH(address(stakingVault), ethToLock);
        console.log("ETH returned from beacon chain to staking vault:", ethToLock);

        // Phase 6: Finalize withdrawal requests
        console.log("=== Phase 6: Finalize withdrawal requests ===");

        // Finalize the withdrawal request using DefiWrapper (which has FINALIZE_ROLE)
        vm.prank(address(dw));
        withdrawalQueue.finalize(requestIds.length);

        console.log("Withdrawal request finalized");

        // Verify finalization state
        WithdrawalQueue.WithdrawalRequestStatus memory statusAfterFinalization = withdrawalQueue.getWithdrawalStatus(requestIds[0]);
        assertTrue(statusAfterFinalization.isFinalized, "Request should be finalized");
        assertFalse(statusAfterFinalization.isClaimed, "Request should not be claimed yet");

        // Phase 7: User claims withdrawal
        console.log("=== Phase 7: User claims withdrawal ===");

        uint256 userETHBalanceBefore = user1.balance;

        vm.prank(user1);
        withdrawalQueue.claimWithdrawal(requestIds[0], address(0));

        uint256 userETHBalanceAfter = user1.balance;
        uint256 claimedAmount = userETHBalanceAfter - userETHBalanceBefore;

        console.log("User claimed ETH:", claimedAmount);
        console.log("User final ETH balance:", userETHBalanceAfter);

        // Phase 8: Final verification - user gets back the same amount
        console.log("=== Phase 8: Final verification ===");

        // Core requirement: user gets back approximately the same amount of ETH they deposited
        assertTrue(claimedAmount >= userInitialETH - 1 && claimedAmount <= userInitialETH + 1, "User should receive approximately the same amount of ETH they deposited");

        // Verify system state is clean (except for initial supply held by DefiWrapper)
        assertEq(wrapper.balanceOf(user1), 0, "User should have no remaining stvETH shares");
        assertEq(wrapper.lockedStvSharesByUser(user1), 0, "User should have no locked shares");
        assertEq(wrapper.totalSupply(), dw.CONNECT_DEPOSIT(), "Total supply should equal initial supply after withdrawal");
        assertTrue(
            wrapper.totalAssets() >= dw.CONNECT_DEPOSIT() - 1 && wrapper.totalAssets() <= dw.CONNECT_DEPOSIT() + 1,
            "Total assets should equal initial balance after withdrawal (within rounding tolerance)"
        );
        assertEq(address(withdrawalQueue).balance, 0, "Withdrawal queue should have no ETH left");

        // Verify withdrawal request is consumed
        WithdrawalQueue.WithdrawalRequestStatus memory finalStatus = withdrawalQueue.getWithdrawalStatus(requestIds[0]);
        assertTrue(finalStatus.isClaimed, "Request should be marked as claimed");

        console.log("=== Case 4 Test Summary ===");
        console.log("PASS: User deposited and received back same amount");
        console.log("PASS: Complete withdrawal happy path completed without stETH minting or boost");
        console.log("PASS: System state clean after withdrawal (all balances zero)");
    }

}