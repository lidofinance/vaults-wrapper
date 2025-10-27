// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BasePool} from "src/BasePool.sol";
import {StvPool} from "src/StvPool.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockDashboard} from "../mocks/MockDashboard.sol";
import {MockVaultHub} from "../mocks/MockVaultHub.sol";
import {MockStakingVault} from "../mocks/MockStakingVault.sol";
import {MockLazyOracle} from "../mocks/MockLazyOracle.sol";
import {MockUpgradableWq} from "../mocks/MockUpgradableWq.sol";

contract WithdrawalQueueTest is Test {
    WithdrawalQueue public withdrawalQueue;
    MockVaultHub public vaultHub;
    StvPool public pool;
    MockStakingVault public stakingVault;
    MockDashboard public dashboard;
    MockLazyOracle public lazyOracle;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public operator = address(0x3);
    address public admin = address(0x4);
    address public beaconChain = address(0xbeac0);

    uint256 public initialBalance = 1 ether;

    uint256 public constant USER1_DEPOSIT = 0.001 ether;
    uint256 public constant USER2_DEPOSIT = 0.0022 ether;
    uint256 public constant REBASE_AMOUNT = 0.0005 ether;

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
            address(0), // stETH not needed for this test
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

        // Deploy pool
        uint256 maxAcceptableWQFinalizationTimeInSeconds = 60 days;
        uint256 minWithdrawalDelayTime = 1 days;

        // Precreate pool proxy with dummy implementation
        address dummyImpl = address(new DummyImplementation());
        OssifiableProxy poolProxy = new OssifiableProxy(dummyImpl, admin, bytes(""));

        lazyOracle = new MockLazyOracle();
        vm.label(address(lazyOracle), "LazyOracle");

        // Deploy WQ implementation with immutable pool; proxy it and initialize
        address wqImpl = address(
            new WithdrawalQueue(
                address(poolProxy),
                address(dashboard),
                address(vaultHub),
                address(0),
                address(stakingVault),
                address(lazyOracle),
                maxAcceptableWQFinalizationTimeInSeconds,
                minWithdrawalDelayTime
            )
        );
        OssifiableProxy wqProxy = new OssifiableProxy(
            wqImpl,
            admin,
            abi.encodeCall(WithdrawalQueue.initialize, (admin, operator))
        );

        // Deploy pool implementation with immutable WQ, then upgrade pool proxy and initialize
        StvPool impl = new StvPool(address(dashboard), false, address(wqProxy), address(0));
        vm.startPrank(admin);
        poolProxy.proxy__upgradeToAndCall(
            address(impl),
            abi.encodeCall(BasePool.initialize, (admin, "Staked ETH Vault Wrapper", "stvETH"))
        );
        vm.stopPrank();
        pool = StvPool(payable(address(poolProxy)));

        withdrawalQueue = WithdrawalQueue(payable(address(wqProxy)));
        vm.label(address(wqProxy), "WithdrawalQueue");

        // Grant necessary roles to pool for dashboard operations
        vm.startPrank(admin);
        dashboard.grantRole(dashboard.FUND_ROLE(), address(pool));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

        // No need to set in pool; it is immutable now
    }

    // Tests the complete withdrawal queue flow from deposit to final ETH claim
    // Verifies: user deposits → withdrawal requests → validator operations → finalization → claiming
    // TODO: Fix this test
    function xtest_CompleteWithdrawalFlow() public {
        vm.startPrank(user1);
        pool.depositETH{value: USER1_DEPOSIT}(user1);
        uint256 user1Shares = pool.balanceOf(user1);
        vm.stopPrank();

        vm.startPrank(user2);
        pool.depositETH{value: USER2_DEPOSIT}(user2);
        uint256 user2Shares = pool.balanceOf(user2);
        vm.stopPrank();

        console.log("user1Shares", user1Shares);
        console.log("user2Shares", user2Shares);

        // Verify deposits
        assertEq(pool.balanceOf(user1), user1Shares);
        assertEq(pool.balanceOf(user2), user2Shares);

        vm.startPrank(user1);
        uint256[] memory user1Amounts = new uint256[](1);
        user1Amounts[0] = user1Shares;
        uint256[] memory user1RequestIds = pool.requestWithdrawals(user1Amounts, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256[] memory user2Amounts = new uint256[](1);
        user2Amounts[0] = user2Shares;
        uint256[] memory user2RequestIds = pool.requestWithdrawals(user2Amounts, user2);
        vm.stopPrank();

        // Simulate operator run validators and send ETH to the BeaconChain
        uint256 stakingVaultBalanceBefore = address(stakingVault).balance;
        console.log("Vault balance before:", stakingVaultBalanceBefore);
        console.log("BeaconChain balance before:", address(beaconChain).balance);

        console.log("---send to beaconChain---");

        vm.prank(address(stakingVault));
        (bool sent, ) = address(beaconChain).call{value: stakingVaultBalanceBefore}("");
        require(sent, "ETH send failed");

        console.log("Vault balance after:", address(stakingVault).balance);
        console.log("BeaconChain balance after:", address(beaconChain).balance);

        // Verify requests were created
        assertEq(user1RequestIds.length, 1);
        assertEq(user2RequestIds.length, 1);

        // Verify stvTokens were burned by pool
        assertEq(pool.balanceOf(user1), 0);
        assertEq(pool.balanceOf(user2), 0);

        // Check request status
        WithdrawalQueue.WithdrawalRequestStatus memory user1Status = withdrawalQueue.getWithdrawalStatus(
            user1RequestIds[0]
        );
        WithdrawalQueue.WithdrawalRequestStatus memory user2Status = withdrawalQueue.getWithdrawalStatus(
            user2RequestIds[0]
        );

        assertEq(user1Status.isFinalized, false);
        assertEq(user2Status.isFinalized, false);

        assertEq(user1Status.isClaimed, false);
        assertEq(user2Status.isClaimed, false);

        // Calculate total ETH needed using prefinalize
        uint256 totalToFinalize1 = withdrawalQueue.unfinalizedAssets();
        console.log("totalToFinalize1", totalToFinalize1);

        console.log("\n---NO exit validators---");
        // operator exit validators and send ETH back to the Staking Vault
        deal(beaconChain, 1 ether + totalToFinalize1);
        vm.prank(beaconChain);
        (bool success, ) = address(stakingVault).call{value: totalToFinalize1}("");
        require(success, "send failed");
        console.log("Vault balance before finalize:", address(stakingVault).balance);

        console.log("\n--finalize--");

        vm.prank(operator);
        vm.expectRevert();
        withdrawalQueue.finalize(3);

        console.log("Vault balance after:", address(stakingVault).balance);
        console.log("BeaconChain balance after:", address(beaconChain).balance);

        console.log("Wrapper balance before:", address(pool).balance);
        console.log("Wrapper totalSupply before:", pool.totalSupply());
        console.log("Wrapper totalAssets before:", pool.totalAssets());
        console.log("WithdrawalQueue balance ETH:", address(withdrawalQueue).balance);
        console.log("WithdrawalQueue balance stvETH:", pool.balanceOf(address(withdrawalQueue)));
        console.log("unfinalizedRequestNumber before", withdrawalQueue.unfinalizedRequestNumber());

        vm.prank(operator);
        uint256 finalizedRequests = withdrawalQueue.finalize(2);
        assertEq(finalizedRequests, 2);

        assertEq(withdrawalQueue.unfinalizedRequestNumber(), 0);
        assertEq(withdrawalQueue.unfinalizedAssets(), 0);
        assertEq(withdrawalQueue.unfinalizedStv(), 0);
        assertEq(withdrawalQueue.getLastRequestId(), 2);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 2);

        console.log("--------------step1------------------");

        console.log("Wrapper balance before:", address(pool).balance);
        console.log("Wrapper totalSupply before:", pool.totalSupply());
        console.log("Wrapper totalAssets before:", pool.totalAssets());
        console.log("WithdrawalQueue balance ETH:", address(withdrawalQueue).balance);
        console.log("WithdrawalQueue balance stvETH:", pool.balanceOf(address(withdrawalQueue)));

        assertEq(user1.balance, initialBalance - USER1_DEPOSIT);
        assertEq(user2.balance, initialBalance - USER2_DEPOSIT);

        // Verify finalization
        user1Status = withdrawalQueue.getWithdrawalStatus(user1RequestIds[0]);
        user2Status = withdrawalQueue.getWithdrawalStatus(user2RequestIds[0]);
        assertEq(user1Status.isFinalized, true);
        assertEq(user2Status.isFinalized, true);

        // Claim withdrawals
        vm.startPrank(user1);
        pool.claimWithdrawal(user1RequestIds[0], user1);
        vm.stopPrank();

        vm.startPrank(user2);
        pool.claimWithdrawal(user2RequestIds[0], user2);
        vm.stopPrank();

        console.log("--------------step2------------------");
        console.log("Wrapper balance before:", address(pool).balance);
        console.log("Wrapper totalSupply before:", pool.totalSupply());
        console.log("Wrapper totalAssets before:", pool.totalAssets());
        console.log("WithdrawalQueue balance ETH:", address(withdrawalQueue).balance);
        console.log("WithdrawalQueue balance stvETH:", pool.balanceOf(address(withdrawalQueue)));
        console.log("user1 balance:", user1.balance);
        console.log("user2 balance:", user2.balance);

        assertEq(user1.balance, initialBalance);
        assertEq(user2.balance, initialBalance);
        assertEq(pool.balanceOf(address(withdrawalQueue)), 0);
        assertEq(pool.balanceOf(user1), 0);
        assertEq(pool.balanceOf(user2), 0);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.totalAssets(), 0);
        assertEq(address(withdrawalQueue).balance, 0);
        assertEq(address(pool).balance, 0);
    }

    // function test_EmergencyExit() public {
    //     vm.startPrank(user1);
    //     uint256 user1Shares = pool.depositETH{value: USER1_DEPOSIT}(user1);
    //     vm.stopPrank();

    //     vm.startPrank(user2);
    //     uint256 user2Shares = pool.depositETH{value: USER2_DEPOSIT}(user2);
    //     vm.stopPrank();

    //     console.log("user1Shares", user1Shares);
    //     console.log("user2Shares", user2Shares);

    //     vm.startPrank(user1);
    //     uint256 halfUser1Deposit = USER1_DEPOSIT/2;
    //     pool.approve(address(withdrawalQueue), halfUser1Deposit);
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
