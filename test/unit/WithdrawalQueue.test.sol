// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Wrapper} from "src/Wrapper.sol";
import {Escrow} from "src/Escrow.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockDashboard} from "../mocks/MockDashboard.sol";
import {MockVaultHub} from "../mocks/MockVaultHub.sol";
import {MockStakingVault} from "../mocks/MockStakingVault.sol";

contract WithdrawalQueueTest is Test {
    WithdrawalQueue public withdrawalQueue;
    MockVaultHub public vaultHub;
    Wrapper public wrapper;
    Escrow public escrow;
    MockStakingVault public stakingVault;
    MockDashboard public dashboard;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public operator = address(0x3);
    address public admin = address(0x4);
    address public beaconChain = address(0xbeac0);

    uint256 public initialBalance = 100_000 wei;

    uint256 public constant USER1_DEPOSIT = 10_000 wei;
    uint256 public constant USER2_DEPOSIT = 22_000 wei;
    uint256 public constant REBASE_AMOUNT = 5_000 wei;

    function setUp() public {
        vm.deal(user1, initialBalance);
        vm.deal(user2, initialBalance);
        vm.deal(admin, initialBalance);
        vm.deal(operator, initialBalance);

        stakingVault = new MockStakingVault();

        // Deploy mock contracts
        vaultHub = new MockVaultHub();
        vm.label(address(vaultHub), "VaultHub");

        // Deploy dashboard
        dashboard = new MockDashboard(
            address(vaultHub),
            address(stakingVault),
            admin
        );
        vm.label(address(dashboard), "Dashboard");

        stakingVault.setNodeOperator(address(vaultHub));

        // Deploy wrapper and escrow
        wrapper = new Wrapper{value: 0 wei}(
            address(dashboard),
            address(0), // placeholder for escrow
            admin,
            "Staked ETH Vault Wrapper",
            "stvETH",
            false // whitelist disabled
        );

        // Deploy withdrawal queue
        withdrawalQueue = new WithdrawalQueue(wrapper);
        vm.label(address(withdrawalQueue), "WithdrawalQueue");

        wrapper.setWithdrawalQueue(address(withdrawalQueue));

        // Initialize withdrawal queue
        withdrawalQueue.initialize(admin);

        vm.startPrank(admin);
        // Grant roles
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), operator);
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), admin);

        // Resume withdrawal queue
        withdrawalQueue.resume();
        vm.stopPrank();
    }

    // Tests the complete withdrawal queue flow from deposit to final ETH claim
    // Verifies: user deposits → withdrawal requests → validator operations → finalization → claiming
    function test_CompleteWithdrawalFlow() public {
        // Step 1: Users deposit ETH and get stvToken
        vm.startPrank(user1);
        uint256 user1Shares = wrapper.depositETH{value: USER1_DEPOSIT}(user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = wrapper.depositETH{value: USER2_DEPOSIT}(user2);
        vm.stopPrank();

        console.log("user1Shares", user1Shares);
        console.log("user2Shares", user2Shares);

        // Verify deposits
        assertEq(wrapper.balanceOf(user1), user1Shares);
        assertEq(wrapper.balanceOf(user2), user2Shares);

        // Step 2: Users request withdrawals through wrapper
        vm.startPrank(user1);
        wrapper.approve(address(withdrawalQueue), USER1_DEPOSIT);
        uint256 user1RequestId = withdrawalQueue.requestWithdrawal(
            user1,
            USER1_DEPOSIT
        );
        vm.stopPrank();

        vm.startPrank(user2);
        wrapper.approve(address(withdrawalQueue), USER2_DEPOSIT);
        uint256 user2RequestId = withdrawalQueue.requestWithdrawal(
            user2,
            USER2_DEPOSIT
        );
        vm.stopPrank();

        // Simulate operator run validators and send ETH to the BeaconChain
        uint256 stakingVaultBalanceBefore = address(stakingVault).balance;
        console.log("Vault balance before:", stakingVaultBalanceBefore);
        console.log("BeaconChain balance before:", address(beaconChain).balance);

        vm.prank(address(stakingVault));
        (bool sent, ) = address(beaconChain).call{
            value: stakingVaultBalanceBefore
        }("");
        require(sent, "ETH send failed");

        console.log("Vault balance after:", address(stakingVault).balance);
        console.log("BeaconChain balance after:", address(beaconChain).balance);

        // Verify requests were created
        assertEq(user1RequestId, 1);
        assertEq(user2RequestId, 2);

        // Verify stvTokens were transferred to withdrawalQueue
        assertEq(
            wrapper.balanceOf(address(withdrawalQueue)),
            USER1_DEPOSIT + USER2_DEPOSIT
        );
        assertEq(wrapper.balanceOf(user1), 0);
        assertEq(wrapper.balanceOf(user2), 0);

        // Check request status
        WithdrawalQueue.WithdrawalRequestStatus memory user1Status = withdrawalQueue.getWithdrawalStatus(user1RequestId);
        WithdrawalQueue.WithdrawalRequestStatus memory user2Status = withdrawalQueue.getWithdrawalStatus(user2RequestId);

        assertEq(user1Status.isFinalized, false);
        assertEq(user2Status.isFinalized, false);

        assertEq(user1Status.isClaimed, false);
        assertEq(user2Status.isClaimed, false);

        // Calculate batches first
        uint256 remaining_eth_budget = withdrawalQueue.unfinalizedAssets();

        WithdrawalQueue.BatchesCalculationState memory state;
        state.remainingEthBudget = remaining_eth_budget;
        state.finished = false;
        state.batchesLength = 0;

        // Loop until state is finished
        while (!state.finished) {
            state = withdrawalQueue.calculateFinalizationBatches(
                1, // max requests per call
                state
            );
        }

        console.log("state.finished", state.finished);
        console.log("state.remainingEthBudget", state.remainingEthBudget);
        console.log("state.batchesLength", state.batchesLength);

        // Convert batches to array for prefinalize
        uint256[] memory batches = new uint256[](state.batchesLength);
        for (uint256 i = 0; i < state.batchesLength; i++) {
            batches[i] = state.batches[i];
        }

        // Calculate total ETH needed using prefinalize
        uint256 shareRate = withdrawalQueue.calculateCurrentShareRate();
        (uint256 ethToLock, ) = withdrawalQueue.prefinalize(batches, shareRate);
        uint256 totalToFinalize1 = ethToLock;
        console.log("totalToFinalize1", totalToFinalize1);

        vm.prank(operator);
        vm.expectRevert();
        withdrawalQueue.finalize(2);

        // operator exit validators and send ETH back to the Staking Vault
        deal(beaconChain, 1 ether + totalToFinalize1);

        console.log(
            "BeaconChain balance before:",
            address(beaconChain).balance
        );

        vm.prank(beaconChain);
        (bool success, ) = address(stakingVault).call{value: totalToFinalize1}(
            ""
        );
        require(success, "send failed");

        console.log("Vault balance after:", address(stakingVault).balance);
        console.log("BeaconChain balance after:", address(beaconChain).balance);

        console.log("Wrapper balance before:", address(wrapper).balance);
        console.log("Wrapper totalSupply before:", wrapper.totalSupply());
        console.log("Wrapper totalAssets before:", wrapper.totalAssets());
        console.log(
            "WithdrawalQueue balance ETH:",
            address(withdrawalQueue).balance
        );
        console.log(
            "WithdrawalQueue balance stvETH:",
            wrapper.balanceOf(address(withdrawalQueue))
        );

        vm.prank(operator);
        withdrawalQueue.finalize(2);
        console.log("--------------------------------");
        console.log(
            "unfinalizedRequestNumber",
            withdrawalQueue.unfinalizedRequestNumber()
        );
        console.log("unfinalizedAssets", withdrawalQueue.unfinalizedAssets());
        console.log("unfinalizedShares", withdrawalQueue.unfinalizedShares());
        console.log("lastRequestId", withdrawalQueue.getLastRequestId());
        console.log("lastFinalizedRequestId", withdrawalQueue.getLastFinalizedRequestId());

        console.log("Wrapper balance before:", address(wrapper).balance);
        console.log("Wrapper totalSupply before:", wrapper.totalSupply());
        console.log("Wrapper totalAssets before:", wrapper.totalAssets());
        console.log(
            "WithdrawalQueue balance ETH:",
            address(withdrawalQueue).balance
        );
        console.log(
            "WithdrawalQueue balance stvETH:",
            wrapper.balanceOf(address(withdrawalQueue))
        );
        console.log("user1 balance:", user1.balance);
        console.log("user2 balance:", user2.balance);

        // Verify finalization
        user1Status = withdrawalQueue.getWithdrawalStatus(user1RequestId);
        user2Status = withdrawalQueue.getWithdrawalStatus(user2RequestId);
        assertEq(user1Status.isFinalized, true);
        assertEq(user2Status.isFinalized, true);

        // Claim withdrawals
        vm.startPrank(user1);
        withdrawalQueue.claimWithdrawal(user1RequestId);
        vm.stopPrank();

        vm.startPrank(user2);
        withdrawalQueue.claimWithdrawal(user2RequestId);
        vm.stopPrank();

        console.log("--------------------------------");
        console.log("Wrapper balance before:", address(wrapper).balance);
        console.log("Wrapper totalSupply before:", wrapper.totalSupply());
        console.log("Wrapper totalAssets before:", wrapper.totalAssets());
        console.log(
            "WithdrawalQueue balance ETH:",
            address(withdrawalQueue).balance
        );
        console.log(
            "WithdrawalQueue balance stvETH:",
            wrapper.balanceOf(address(withdrawalQueue))
        );
        console.log("user1 balance:", user1.balance);
        console.log("user2 balance:", user2.balance);

        assertEq(user1.balance, initialBalance);
        assertEq(user2.balance, initialBalance);
        assertEq(wrapper.balanceOf(address(withdrawalQueue)), 0);
        assertEq(wrapper.balanceOf(user1), 0);
        assertEq(wrapper.balanceOf(user2), 0);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(wrapper.totalAssets(), 0);
        assertEq(address(withdrawalQueue).balance, 0);
        assertEq(address(wrapper).balance, 0);
    }

    // Tests withdrawal handling when vault experiences staking rewards/rebases
    // Placeholder for testing share rate changes during withdrawal process
    function test_WithdrawalWithRebase() public {}

    // function test_WithdrawalQueueState() public {
    //     // Test initial state
    //     assertEq(withdrawalQueue.nextRequestId(), 0);
    //     assertEq(withdrawalQueue.lastFinalizedRequestId(), 0);
    //     assertEq(withdrawalQueue.totalLockedAssets(), 0);
    //     assertEq(withdrawalQueue.lastCheckpointIndex(), 0);

    //     // Create a withdrawal request through wrapper
    //     vm.startPrank(user1);
    //     uint256 shares = wrapper.depositETH{value: 1e18}(user1);
    //     wrapper.withdraw(shares);
    //     vm.stopPrank();

    //     // Check state after request
    //     assertEq(withdrawalQueue.nextRequestId(), 1);
    //     assertEq(withdrawalQueue.lastFinalizedRequestId(), 0);
    //     assertEq(withdrawalQueue.totalLockedAssets(), 0);

    //     // Get user requests
    //     uint256[] memory userRequests = withdrawalQueue.getWithdrawalRequests(user1);
    //     assertEq(userRequests.length, 1);
    //     assertEq(userRequests[0], 1);
    // }

    // function test_ClaimableEtherCalculation() public {
    //     // Create withdrawal request through wrapper
    //     vm.startPrank(user1);
    //     uint256 shares = wrapper.depositETH{value: 1e18}(user1);
    //     uint256 requestId = wrapper.withdraw(shares);
    //     vm.stopPrank();

    //     uint256[] memory requestIds = new uint256[](1);
    //     requestIds[0] = requestId;

    //     // Check claimable before finalization
    //     uint256[] memory hints = new uint256[](1);
    //     hints[0] = 1;
    //     uint256[] memory claimable = withdrawalQueue.getClaimableEther(requestIds, hints);
    //     assertEq(claimable[0], 0); // Not finalized yet

    //     // Finalize request
    //     vm.prank(operator);
    //     WithdrawalQueueV3.WithdrawalRequestStatus[] memory status = withdrawalQueue.getWithdrawalStatus(requestIds);
    //     uint256 totalToFinalize = status[0].amountOfAssets;
    //     withdrawalQueue.finalize{value: totalToFinalize}(1, totalToFinalize, 1.1e27); // 10% increase

    //     // Check claimable after finalization
    //     claimable = withdrawalQueue.getClaimableEther(requestIds, hints);
    //     assertGt(claimable[0], 0); // Should be claimable now
    // }

    // function test_MultipleWithdrawalRequests() public {
    //     // User1 creates multiple requests through wrapper
    //     vm.startPrank(user1);
    //     uint256 shares1 = wrapper.depositETH{value: 1e18}(user1);
    //     uint256 shares2 = wrapper.depositETH{value: 2e18}(user1);
    //     uint256 shares3 = wrapper.depositETH{value: 2e18}(user1);

    //     uint256 requestId1 = wrapper.withdraw(shares1);
    //     uint256 requestId2 = wrapper.withdraw(shares2);
    //     uint256 requestId3 = wrapper.withdraw(shares3);
    //     vm.stopPrank();

    //     // Verify all requests were created
    //     assertEq(requestId1, 1);
    //     assertEq(requestId2, 2);
    //     assertEq(requestId3, 3);

    //     // Check user's requests
    //     uint256[] memory userRequests = withdrawalQueue.getWithdrawalRequests(user1);
    //     assertEq(userRequests.length, 3);
    //     assertEq(userRequests[0], 1);
    //     assertEq(userRequests[1], 2);
    //     assertEq(userRequests[2], 3);
    // }

    // function test_WithdrawalQueuePauseResume() public {
    //     // Test pause
    //     vm.prank(admin);
    //     withdrawalQueue.pauseFor(type(uint256).max);

    //     // Try to create request while paused
    //     vm.startPrank(user1);
    //     uint256 shares = wrapper.depositETH{value: 1e18}(user1);

    //     vm.expectRevert(); // Should revert when paused
    //     wrapper.withdraw(shares);
    //     vm.stopPrank();

    //     // Resume
    //     vm.prank(admin);
    //     withdrawalQueue.resume();

    //     // Should work again
    //     vm.startPrank(user1);
    //     uint256 requestId = wrapper.withdraw(shares);
    //     vm.stopPrank();

    //     assertEq(requestId, 1);
    // }

    // function test_BatchClaimWithdrawals() public {
    //     // Create multiple withdrawal requests
    //     vm.startPrank(user1);
    //     uint256 shares1 = wrapper.depositETH{value: 1e18}(user1);
    //     uint256 shares2 = wrapper.depositETH{value: 1e18}(user1);

    //     uint256 requestId1 = wrapper.withdraw(shares1);
    //     uint256 requestId2 = wrapper.withdraw(shares2);
    //     vm.stopPrank();

    //     // Finalize requests
    //     vm.prank(operator);
    //     uint256 totalToFinalize = 2e18;
    //     withdrawalQueue.finalize{value: totalToFinalize}(2, totalToFinalize, 1.1e27);

    //     // Batch claim
    //     vm.startPrank(user1);
    //     uint256[] memory requestIds = new uint256[](2);
    //     requestIds[0] = requestId1;
    //     requestIds[1] = requestId2;

    //     uint256[] memory hints = new uint256[](2);
    //     hints[0] = 1;
    //     hints[1] = 1;

    //     uint256 balanceBefore = user1.balance;
    //     withdrawalQueue.claimWithdrawals(requestIds, hints, user1);
    //     uint256 balanceAfter = user1.balance;

    //     assertGt(balanceAfter, balanceBefore);
    //     vm.stopPrank();
    // }

    // function test_UnfinalizedRequests() public {
    //     // Create some requests
    //     vm.startPrank(user1);
    //     uint256 shares = wrapper.depositETH{value: 1e18}(user1);
    //     wrapper.withdraw(shares);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     uint256 shares2 = wrapper.depositETH{value: 2e18}(user2);
    //     wrapper.withdraw(shares2);
    //     vm.stopPrank();

    //     // Check unfinalized requests
    //     assertEq(withdrawalQueue.unfinalizedRequestNumber(), 2);
    //     assertGt(withdrawalQueue.unfinalizedAssets(), 0);

    //     // Finalize only first request
    //     vm.prank(operator);
    //     withdrawalQueue.finalize{value: 1e18}(1, 1e18, 1.1e27);

    //     // Check unfinalized requests after partial finalization
    //     assertEq(withdrawalQueue.unfinalizedRequestNumber(), 1);
    // }

    // function test_InvalidOperations() public {
    //     // Try to claim non-existent request
    //     vm.expectRevert();
    //     withdrawalQueue.claimWithdrawal(999, 1, user1);

    //     // Try to finalize without proper role
    //     vm.expectRevert();
    //     withdrawalQueue.finalize(1, 1e18, 1.1e27);

    //     // Try to finalize with invalid share rate
    //     vm.prank(operator);
    //     vm.expectRevert();
    //     withdrawalQueue.finalize{value: 1e18}(1, 1e18, 0);
    // }

    // function test_DirectWithdrawalQueueOperations() public {
    //     // Test direct operations on withdrawal queue
    //     uint256 shares = 1e18;
    //     uint256 assets = 1e18;

    //     // Create request directly
    //     uint256 requestId = withdrawalQueue.requestWithdrawal(user1, shares, assets);
    //     assertEq(requestId, 1);

    //     // Check request details
    //     WithdrawalQueueV3.WithdrawalRequest memory request = withdrawalQueue.requests(requestId);
    //     assertEq(request.owner, user1);
    //     assertEq(request.cumulativeShares, shares);
    //     assertEq(request.cumulativeAssets, assets);
    //     assertEq(request.claimed, false);

    //     // Finalize directly
    //     vm.prank(operator);
    //     withdrawalQueue.finalize{value: assets}(1, assets, 1.1e27);

    //     // Claim directly
    //     vm.startPrank(user1);
    //     uint256 balanceBefore = user1.balance;
    //     withdrawalQueue.claimWithdrawal(1, 1, user1);
    //     uint256 balanceAfter = user1.balance;
    //     assertGt(balanceAfter, balanceBefore);
    //     vm.stopPrank();
    // }

    // function test_ShareRateCalculation() public {
    //     // Create request with specific shares
    //     uint256 shares = 1000e18;
    //     uint256 assets = 1000e18;

    //     uint256 requestId = withdrawalQueue.requestWithdrawal(user1, shares, assets);

    //     // Finalize with different share rates
    //     vm.prank(operator);
    //     uint256 shareRate = 1.05e27; // 5% increase
    //     withdrawalQueue.finalize{value: assets}(1, assets, shareRate);

    //     // Calculate expected claimable amount
    //     uint256 expectedAmount = (shares * shareRate) / WithdrawalQueueV3.E27_PRECISION_BASE;

    //     // Check claimable amount
    //     uint256[] memory requestIds = new uint256[](1);
    //     requestIds[0] = requestId;
    //     uint256[] memory hints = new uint256[](1);
    //     hints[0] = 1;
    //     uint256[] memory claimable = withdrawalQueue.getClaimableEther(requestIds, hints);

    //     assertEq(claimable[0], expectedAmount);
    // }

    // function test_CheckpointSystem() public {
    //     // Create multiple requests
    //     uint256 requestId1 = withdrawalQueue.requestWithdrawal(user1, 1e18, 1e18);
    //     uint256 requestId2 = withdrawalQueue.requestWithdrawal(user2, 2e18, 2e18);
    //     uint256 requestId3 = withdrawalQueue.requestWithdrawal(user1, 1e18, 1e18);

    //     // Finalize first two requests with one share rate
    //     vm.prank(operator);
    //     withdrawalQueue.finalize{value: 3e18}(2, 3e18, 1.1e27);

    //     // Finalize third request with different share rate
    //     vm.prank(operator);
    //     withdrawalQueue.finalize{value: 1e18}(3, 1e18, 1.2e27);

    //     // Check checkpoints
    //     assertEq(withdrawalQueue.lastCheckpointIndex(), 2);

    //     WithdrawalQueueV3.Checkpoint memory checkpoint1 = withdrawalQueue.checkpoints(1);
    //     WithdrawalQueueV3.Checkpoint memory checkpoint2 = withdrawalQueue.checkpoints(2);

    //     assertEq(checkpoint1.fromRequestId, 1);
    //     assertEq(checkpoint1.shareRate, 1.1e27);
    //     assertEq(checkpoint2.fromRequestId, 3);
    //     assertEq(checkpoint2.shareRate, 1.2e27);
    // }
}
