// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {DefiWrapper} from "test/utils/DefiWrapper.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {WrapperBase} from "src/WrapperBase.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperB} from "src/WrapperB.sol";
import {WrapperC} from "src/WrapperC.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {ExampleLoopStrategy, LenderMock} from "src/ExampleLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract WithdrawalTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;
    
    // Access to harness components
    WrapperC public wrapperC; // Wrapper with strategy
    WrapperA public wrapperA; // Basic wrapper for basic withdrawal tests
    WrapperB public wrapperB; // Minting wrapper
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    ExampleLoopStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core));

        wrapperC = dw.wrapper();
        withdrawalQueue = dw.withdrawalQueue();
        strategy = dw.strategy();
        dashboard = dw.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = dw.stakingVault();

        // Create additional wrapper configurations for withdrawal testing
        wrapperA = new WrapperA(
            address(dashboard),
            address(this),
            "Basic Wrapper A",
            "stvA",
            false // whitelist disabled
        );
        WithdrawalQueue queueA = new WithdrawalQueue(wrapperA);
        queueA.initialize(address(this));
        wrapperA.setWithdrawalQueue(address(queueA));
        queueA.grantRole(queueA.FINALIZE_ROLE(), address(this));
        queueA.resume();
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperA));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(queueA));
        
        wrapperB = new WrapperB(
            address(dashboard),
            address(this),
            "Minting Wrapper B",
            "stvB",
            false // whitelist disabled
        );
        WithdrawalQueue queueB = new WithdrawalQueue(wrapperB);
        queueB.initialize(address(this));
        wrapperB.setWithdrawalQueue(address(queueB));
        queueB.grantRole(queueB.FINALIZE_ROLE(), address(this));
        queueB.resume();
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperB));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(queueB));

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
        uint256 userStvShares = wrapperA.depositETH{value: userInitialETH}(user1);
        vm.stopPrank();

        console.log("User deposited ETH:", userInitialETH);
        console.log("User received stvETH shares:", userStvShares);

        // Verify initial state - user has shares, no stETH minted, no boost
        assertEq(wrapperA.balanceOf(user1), userStvShares, "User should have stvETH shares");
        assertEq(wrapperA.totalAssets(), userInitialETH + dw.CONNECT_DEPOSIT(), "Total assets should equal user deposit plus initial balance");
        assertEq(user1.balance, 0, "User ETH balance should be zero after deposit");
        assertEq(steth.balanceOf(user1), 0, "User should have no stETH (config A)");

        // Phase 2: User requests withdrawal
        console.log("=== Phase 2: User requests withdrawal ===");

        // Use Configuration A withdrawal interface
        vm.startPrank(user1);
        uint256 requestId = wrapperA.requestWithdrawal(userStvShares);
        vm.stopPrank();

        console.log("Withdrawal requested. RequestId:", requestId);

        // Verify withdrawal request state
        assertGt(requestId, 0, "Request ID should be valid");
        assertEq(wrapperA.balanceOf(user1), 0, "User stvETH shares should be burned after withdrawal request");

        // Get the withdrawal queue for wrapperA
        WithdrawalQueue queueA = wrapperA.withdrawalQueue();
        
        // Check withdrawal queue state using getWithdrawalStatus
        WithdrawalQueue.WithdrawalRequestStatus memory status = queueA.getWithdrawalStatus(requestId);
        assertTrue(status.amountOfAssets > 0, "Requested amount should be positive");
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

        uint256 remainingEthBudget = queueA.unfinalizedAssets();
        console.log("Unfinalized assets requiring ETH:", remainingEthBudget);

        WithdrawalQueue.BatchesCalculationState memory state;
        state.remainingEthBudget = remainingEthBudget;
        state.finished = false;
        state.batchesLength = 0;

        // Calculate batches for finalization
        while (!state.finished) {
            state = queueA.calculateFinalizationBatches(1, state);
        }

        console.log("Batches calculation finished, batches length:", state.batchesLength);

        // Convert batches to array for prefinalize
        uint256[] memory batches = new uint256[](state.batchesLength);
        for (uint256 i = 0; i < state.batchesLength; i++) {
            batches[i] = state.batches[i];
        }

        // Calculate exact ETH needed for finalization
        uint256 shareRate = queueA.calculateCurrentShareRate();
        (uint256 ethToLock, ) = queueA.prefinalize(batches, shareRate);

        console.log("ETH required for finalization:", ethToLock);
        console.log("Current share rate:", shareRate);

        // Phase 5: Simulate validator exit and ETH return
        console.log("=== Phase 5: Simulate validator exit and ETH return ===");

        // Simulate validator exit returning ETH to staking vault using CoreHarness
        core.mockValidatorExitReturnETH(address(stakingVault), ethToLock);
        console.log("ETH returned from beacon chain to staking vault:", ethToLock);

        // Phase 6: Finalize withdrawal requests
        console.log("=== Phase 6: Finalize withdrawal requests ===");

        // Finalize the withdrawal request using test admin (which has FINALIZE_ROLE)
        vm.prank(address(this));
        queueA.finalize(requestId);

        console.log("Withdrawal request finalized");

        // Verify finalization state
        WithdrawalQueue.WithdrawalRequestStatus memory statusAfterFinalization = queueA.getWithdrawalStatus(requestId);
        assertTrue(statusAfterFinalization.isFinalized, "Request should be finalized");
        assertFalse(statusAfterFinalization.isClaimed, "Request should not be claimed yet");

        // Phase 7: User claims withdrawal
        console.log("=== Phase 7: User claims withdrawal ===");

        uint256 userETHBalanceBefore = user1.balance;

        vm.prank(user1);
        wrapperA.claimWithdrawal(requestId);

        uint256 userETHBalanceAfter = user1.balance;
        uint256 claimedAmount = userETHBalanceAfter - userETHBalanceBefore;

        console.log("User claimed ETH:", claimedAmount);
        console.log("User final ETH balance:", userETHBalanceAfter);

        // Phase 8: Final verification - user gets back the same amount
        console.log("=== Phase 8: Final verification ===");

        // Core requirement: user gets back approximately the same amount of ETH they deposited
        assertTrue(claimedAmount >= userInitialETH - 1 && claimedAmount <= userInitialETH + 1, "User should receive approximately the same amount of ETH they deposited");

        // Verify system state is clean (except for initial supply held by wrapper itself)
        assertEq(wrapperA.balanceOf(user1), 0, "User should have no remaining stvETH shares");
        assertEq(wrapperA.totalSupply(), dw.CONNECT_DEPOSIT(), "Total supply should equal initial supply after withdrawal");
        assertTrue(
            wrapperA.totalAssets() >= dw.CONNECT_DEPOSIT() - 1 && wrapperA.totalAssets() <= dw.CONNECT_DEPOSIT() + 1,
            "Total assets should equal initial balance after withdrawal (within rounding tolerance)"
        );
        assertEq(address(queueA).balance, 0, "Withdrawal queue should have no ETH left");

        // Verify withdrawal request is consumed
        WithdrawalQueue.WithdrawalRequestStatus memory finalStatus = queueA.getWithdrawalStatus(requestId);
        assertTrue(finalStatus.isClaimed, "Request should be marked as claimed");

        console.log("=== Case 4 Test Summary ===");
        console.log("PASS: User deposited and received back same amount");
        console.log("PASS: Complete withdrawal happy path completed without stETH minting or boost");
        console.log("PASS: System state clean after withdrawal (all balances zero)");
    }

}