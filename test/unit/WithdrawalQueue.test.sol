// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WrapperBase} from "src/WrapperBase.sol";
import {WrapperA} from "src/WrapperA.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockDashboard} from "../mocks/MockDashboard.sol";
import {MockVaultHub} from "../mocks/MockVaultHub.sol";
import {MockStakingVault} from "../mocks/MockStakingVault.sol";
import {MockLazyOracle} from "../mocks/MockLazyOracle.sol";

contract WithdrawalQueueTest is Test {
    WithdrawalQueue public withdrawalQueue;
    MockVaultHub public vaultHub;
    WrapperA public wrapper;
    MockStakingVault public stakingVault;
    MockDashboard public dashboard;
    MockLazyOracle public lazyOracle;

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

        vm.startPrank(address(0x1234));
        stakingVault = new MockStakingVault();
        vm.stopPrank();

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

        // Fund the staking vault with the required CONNECT_DEPOSIT
        vm.deal(address(stakingVault), 1 ether);
        // Initialize vault hub to reflect the staking vault balance
        vaultHub.mock_setVaultBalance(address(stakingVault), 1 ether);

        // Deploy wrapper
        uint256 maxAcceptableWQFinalizationTimeInSeconds = 60 days;

        // Precreate wrapper proxy with empty implementation
        OssifiableProxy wrapperProxy = new OssifiableProxy(address(0), admin, bytes(""));

        // Deploy WQ implementation with immutable wrapper; proxy it and initialize
        address wqImpl = address(new WithdrawalQueue(address(wrapperProxy), maxAcceptableWQFinalizationTimeInSeconds));
        OssifiableProxy wqProxy = new OssifiableProxy(wqImpl, admin, abi.encodeCall(WithdrawalQueue.initialize, (admin, operator)));

        // Deploy wrapper implementation with immutable WQ, then upgrade wrapper proxy and initialize
        WrapperA impl = new WrapperA(address(dashboard), false, address(wqProxy));
        wrapperProxy.proxy__upgradeToAndCall(address(impl), abi.encodeCall(WrapperBase.initialize, (admin, "Staked ETH Vault Wrapper", "stvETH")));
        wrapper = WrapperA(payable(address(wrapperProxy)));

        withdrawalQueue = WithdrawalQueue(payable(address(wqProxy)));
        vm.label(address(wqProxy), "WithdrawalQueue");

        // Grant necessary roles to wrapper for dashboard operations
        vm.startPrank(admin);
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

        // No need to set in wrapper; it is immutable now
    }

    // Tests the complete withdrawal queue flow from deposit to final ETH claim
    // Verifies: user deposits → withdrawal requests → validator operations → finalization → claiming
    function test_CompleteWithdrawalFlow() public {
        vm.startPrank(user1);
        wrapper.depositETH{value: USER1_DEPOSIT}(user1);
        uint256 user1Shares = wrapper.balanceOf(user1);
        vm.stopPrank();

        vm.startPrank(user2);
        wrapper.depositETH{value: USER2_DEPOSIT}(user2);
        uint256 user2Shares = wrapper.balanceOf(user2);
        vm.stopPrank();

        console.log("user1Shares", user1Shares);
        console.log("user2Shares", user2Shares);

        // Verify deposits
        assertEq(wrapper.balanceOf(user1), user1Shares);
        assertEq(wrapper.balanceOf(user2), user2Shares);

        vm.startPrank(user1);
        wrapper.approve(address(withdrawalQueue), USER1_DEPOSIT);

        uint256[] memory user1Amounts = new uint256[](1);
        user1Amounts[0] = USER1_DEPOSIT;
        uint256[] memory user1RequestIds = withdrawalQueue.requestWithdrawals(
            user1Amounts,
            user1
        );
        vm.stopPrank();

        vm.startPrank(user2);
        wrapper.approve(address(withdrawalQueue), USER2_DEPOSIT);
        uint256[] memory user2Amounts = new uint256[](1);
        user2Amounts[0] = USER2_DEPOSIT;
        uint256[] memory user2RequestIds = withdrawalQueue.requestWithdrawals(
            user2Amounts,
            user2
        );
        vm.stopPrank();

        // Simulate operator run validators and send ETH to the BeaconChain
        uint256 stakingVaultBalanceBefore = address(stakingVault).balance;
        console.log("Vault balance before:", stakingVaultBalanceBefore);
        console.log("BeaconChain balance before:", address(beaconChain).balance);

        console.log("---send to beaconChain---");

        vm.prank(address(stakingVault));
        (bool sent, ) = address(beaconChain).call{
            value: stakingVaultBalanceBefore
        }("");
        require(sent, "ETH send failed");

        console.log("Vault balance after:", address(stakingVault).balance);
        console.log("BeaconChain balance after:", address(beaconChain).balance);

        // Verify requests were created
        assertEq(user1RequestIds.length, 1);
        assertEq(user2RequestIds.length, 1);

        // Verify stvTokens were burned by wrapper
        assertEq(wrapper.balanceOf(user1), 0);
        assertEq(wrapper.balanceOf(user2), 0);

        // Check request status
        WithdrawalQueue.WithdrawalRequestStatus memory user1Status = withdrawalQueue.getWithdrawalStatus(user1RequestIds[0]);
        WithdrawalQueue.WithdrawalRequestStatus memory user2Status = withdrawalQueue.getWithdrawalStatus(user2RequestIds[0]);

        assertEq(user1Status.isFinalized, false);
        assertEq(user2Status.isFinalized, false);

        assertEq(user1Status.isClaimed, false);
        assertEq(user2Status.isClaimed, false);

        // Calculate total ETH needed using prefinalize
        uint256 shareRate = withdrawalQueue.calculateCurrentShareRate();
        uint256 totalToFinalize1 = withdrawalQueue.unfinalizedAssets();
        console.log("totalToFinalize1", totalToFinalize1);

        console.log("\n---NO exit validators---");
        // operator exit validators and send ETH back to the Staking Vault
        deal(beaconChain, 1 ether + totalToFinalize1);
        vm.prank(beaconChain);
        (bool success, ) = address(stakingVault).call{value: totalToFinalize1}(
            ""
        );
        require(success, "send failed");
        console.log("Vault balance before finalize:", address(stakingVault).balance);

        console.log("\n--finalize--");

        vm.prank(operator);
        vm.expectRevert();
        withdrawalQueue.finalize(3);

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
        console.log("unfinalizedRequestNumber before", withdrawalQueue.unfinalizedRequestNumber());

        vm.prank(operator);
        uint256 finalizedRequests = withdrawalQueue.finalize(2);
        assertEq(finalizedRequests, 2);

        assertEq(withdrawalQueue.unfinalizedRequestNumber(), 0);
        assertEq(withdrawalQueue.unfinalizedAssets(), 0);
        assertEq(withdrawalQueue.unfinalizedShares(), 0);
        assertEq(withdrawalQueue.getLastRequestId(), 2);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 2);

        console.log("--------------step1------------------");

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

        assertEq(user1.balance, initialBalance - USER1_DEPOSIT);
        assertEq(user2.balance, initialBalance - USER2_DEPOSIT);

        // Verify finalization
        user1Status = withdrawalQueue.getWithdrawalStatus(user1RequestIds[0]);
        user2Status = withdrawalQueue.getWithdrawalStatus(user2RequestIds[0]);
        assertEq(user1Status.isFinalized, true);
        assertEq(user2Status.isFinalized, true);

        // Claim withdrawals
        vm.startPrank(user1);
        withdrawalQueue.claimWithdrawal(user1RequestIds[0], address(0));
        vm.stopPrank();

        vm.startPrank(user2);
        withdrawalQueue.claimWithdrawal(user2RequestIds[0], address(0));
        vm.stopPrank();

        console.log("--------------step2------------------");
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

    // function test_EmergencyExit() public {
    //     vm.startPrank(user1);
    //     uint256 user1Shares = wrapper.depositETH{value: USER1_DEPOSIT}(user1);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     uint256 user2Shares = wrapper.depositETH{value: USER2_DEPOSIT}(user2);
    //     vm.stopPrank();

    //     console.log("user1Shares", user1Shares);
    //     console.log("user2Shares", user2Shares);

    //     vm.startPrank(user1);
    //     uint256 halfUser1Deposit = USER1_DEPOSIT/2;
    //     wrapper.approve(address(withdrawalQueue), halfUser1Deposit);
    //     uint256 user1RequestId = withdrawalQueue.requestWithdrawal(
    //         user1,
    //         halfUser1Deposit
    //     );
    //     vm.stopPrank();

    //     console.log("user1RequestId", user1RequestId);
    //     console.log("--------------------------------");
    //     console.log("unfinalizedRequestNumber", withdrawalQueue.unfinalizedRequestNumber());
    //     console.log("unfinalizedAssets", withdrawalQueue.unfinalizedAssets());
    //     console.log("unfinalizedShares", withdrawalQueue.unfinalizedShares());
    //     console.log("lastRequestId", withdrawalQueue.getLastRequestId());
    //     console.log("lastFinalizedRequestId", withdrawalQueue.getLastFinalizedRequestId());
    //     console.log("halfUser1Deposit", halfUser1Deposit);


    //     console.log("--- calculateFinalizationBatches ---");

    //     // Calculate batches first
    //     uint256 remaining_eth_budget = withdrawalQueue.unfinalizedAssets();

    //     console.log("--- finalize ---");
    //     console.log("emergencyExitActivated", withdrawalQueue.isEmergencyExitActivated());
    //     assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
    //     assertEq(withdrawalQueue.isWithdrawalQueueStuck(), false);

    //     vm.expectRevert();
    //     withdrawalQueue.finalize(1);

    //     assertEq(address(withdrawalQueue).balance, 0);

    //     vm.warp(block.timestamp + 61 days);
    //     assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
    //     assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

    //     vm.prank(user1);
    //     withdrawalQueue.activateEmergencyExit();

    //     assertEq(withdrawalQueue.isEmergencyExitActivated(), true);
    //     assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

    //     uint256 user1BalanceBefore = user1.balance;

    //     vm.prank(user1);
    //     withdrawalQueue.finalize(1);

    //     assertEq(address(withdrawalQueue).balance, halfUser1Deposit);
    //     assertEq(address(user1).balance, user1BalanceBefore);

    //     vm.prank(user1);
    //     withdrawalQueue.claimWithdrawal(user1RequestId);

    //     assertEq(address(withdrawalQueue).balance, 0);
    //     assertEq(address(user1).balance, user1BalanceBefore + halfUser1Deposit);
    // }

    // Tests withdrawal handling when vault experiences staking rewards/rebases
    // Placeholder for testing share rate changes during withdrawal process
    function test_WithdrawalWithRebase() public {}
}
