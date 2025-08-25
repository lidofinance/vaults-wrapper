// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WrapperA} from "src/WrapperA.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockDashboard} from "../mocks/MockDashboard.sol";
import {MockVaultHub} from "../mocks/MockVaultHub.sol";
import {MockStakingVault} from "../mocks/MockStakingVault.sol";

contract WithdrawalQueueTest is Test {
    WithdrawalQueue public withdrawalQueue;
    MockVaultHub public vaultHub;
    WrapperA public wrapper;
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

        // Deploy wrapper
        wrapper = new WrapperA(
            address(dashboard),
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
        (uint256 totalToFinalize1, ) = withdrawalQueue.prefinalize(batches, shareRate);
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

    function test_EmergencyExit() public {
        vm.startPrank(user1);
        uint256 user1Shares = wrapper.depositETH{value: USER1_DEPOSIT}(user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = wrapper.depositETH{value: USER2_DEPOSIT}(user2);
        vm.stopPrank();

        console.log("user1Shares", user1Shares);
        console.log("user2Shares", user2Shares);

        vm.startPrank(user1);
        uint256 halfUser1Deposit = USER1_DEPOSIT/2;
        wrapper.approve(address(withdrawalQueue), halfUser1Deposit);
        uint256 user1RequestId = withdrawalQueue.requestWithdrawal(
            user1,
            halfUser1Deposit
        );
        vm.stopPrank();

        console.log("user1RequestId", user1RequestId);
        console.log("--------------------------------");
        console.log("unfinalizedRequestNumber", withdrawalQueue.unfinalizedRequestNumber());
        console.log("unfinalizedAssets", withdrawalQueue.unfinalizedAssets());
        console.log("unfinalizedShares", withdrawalQueue.unfinalizedShares());
        console.log("lastRequestId", withdrawalQueue.getLastRequestId());
        console.log("lastFinalizedRequestId", withdrawalQueue.getLastFinalizedRequestId());
        console.log("halfUser1Deposit", halfUser1Deposit);


        console.log("--- calculateFinalizationBatches ---");

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
        console.log("state.batchesLength", state.batchesLength);

        console.log("--- finalize ---");
        console.log("emergencyExitActivated", withdrawalQueue.isEmergencyExitActivated());
        assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), false);

        vm.expectRevert();
        withdrawalQueue.finalize(1);

        assertEq(address(withdrawalQueue).balance, 0);

        vm.warp(block.timestamp + 60 days);
        assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

        vm.prank(user1);
        withdrawalQueue.activateEmergencyExit();

        assertEq(withdrawalQueue.isEmergencyExitActivated(), true);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

        uint256 user1BalanceBefore = user1.balance;

        vm.prank(user1);
        withdrawalQueue.finalize(1);

        assertEq(address(withdrawalQueue).balance, halfUser1Deposit);
        assertEq(address(user1).balance, user1BalanceBefore);

        vm.prank(user1);
        withdrawalQueue.claimWithdrawal(user1RequestId);

        assertEq(address(withdrawalQueue).balance, 0);
        assertEq(address(user1).balance, user1BalanceBefore + halfUser1Deposit);
    }

    // Tests withdrawal handling when vault experiences staking rewards/rebases
    // Placeholder for testing share rate changes during withdrawal process
    function test_WithdrawalWithRebase() public {}
}
