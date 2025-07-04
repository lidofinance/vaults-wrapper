// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {Wrapper} from "../src/Wrapper.sol";
import {MockDashboard} from "./mocks/MockDashboard.sol";
import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockStakingVault} from "./mocks/MockStakingVault.sol";

contract WithdrawalQueueTest is Test {
    WithdrawalQueue public withdrawalQueue;
    Wrapper public wrapper;
    MockDashboard public dashboard;
    MockVaultHub public vaultHub;
    MockStakingVault public stakingVault;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public nodeOperator = address(0x4);

    uint256 public constant E27_PRECISION_BASE = 1e27;

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event WithdrawalsFinalized(
        uint256 firstRequestId,
        uint256 lastRequestId,
        uint256 totalAssets,
        uint256 totalShares,
        uint256 shareRate
    );
    event WithdrawalClaimed(
        uint256 indexed requestId,
        address indexed user,
        uint256 assets
    );

    function setUp() public {
        // Deploy mocks
        stakingVault = new MockStakingVault();
        vaultHub = new MockVaultHub();
        dashboard = new MockDashboard(address(vaultHub), address(stakingVault));

        // Deploy wrapper
        wrapper = new Wrapper(
            address(dashboard),
            address(withdrawalQueue),
            address(this), // Owner of the wrapper
            "Staked ETH Vault Wrapper",
            "stvETH"
        );

        // Deploy withdrawal queue
        withdrawalQueue = new WithdrawalQueue(address(dashboard));

        // Give ownership to node operator
        withdrawalQueue.transferOwnership(nodeOperator);

        // Setup initial vault state
        vaultHub.mock_simulateRewards(address(stakingVault), 1000 ether);

        // Fund users
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
    }

    function test_NormalWithdrawalFlow() public {
        // 1. Users deposit ETH and get shares
        vm.startPrank(user1);
        uint256 user1Shares = wrapper.deposit(10 ether, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = wrapper.deposit(20 ether, user2);
        vm.stopPrank();

        console.log("User1 shares:", user1Shares);
        console.log("User2 shares:", user2Shares);
        console.log("Wrapper totalAssets:", wrapper.totalAssets());
        console.log("Wrapper totalSupply:", wrapper.totalSupply());

        // 2. Users request withdrawals
        vm.startPrank(user1);
        uint256 requestId1 = wrapper.withdraw(5 ether, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 requestId2 = wrapper.withdraw(8 ether, user2, user2);
        vm.stopPrank();

        console.log("Request1 ID:", requestId1);
        console.log("Request2 ID:", requestId2);

        // 3. Check withdrawal queue state
        assertEq(withdrawalQueue.nextRequestId(), 3); // 1-based indexing
        assertEq(withdrawalQueue.lastFinalizedRequestId(), 0);

        // 4. Node operator finalizes withdrawals
        vm.startPrank(nodeOperator);
        uint256 totalAssetsToFinalize = 13 ether;
        withdrawalQueue.finalize(
            2,
            totalAssetsToFinalize,
            wrapper.calculateShareRate()
        ); // Finalize both requests
        vm.stopPrank();

        // 5. Check finalization
        assertEq(withdrawalQueue.lastFinalizedRequestId(), 2);

        // 6. Users claim their withdrawals
        vm.startPrank(user1);
        withdrawalQueue.claim(1);
        vm.stopPrank();

        vm.startPrank(user2);
        withdrawalQueue.claim(2);
        vm.stopPrank();

        // 7. Verify balances
        assertEq(user1.balance, 95 ether); // 100 - 10 + 5
        assertEq(user2.balance, 88 ether); // 100 - 20 + 8

        console.log("User1 final balance:", user1.balance);
        console.log("User2 final balance:", user2.balance);
    }

    function test_WithdrawalWithSlashing() public {
        // 1. Users deposit ETH
        vm.startPrank(user1);
        uint256 user1Shares = wrapper.deposit(10 ether, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = wrapper.deposit(20 ether, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        uint256 user3Shares = wrapper.deposit(15 ether, user3);
        vm.stopPrank();

        console.log("Initial state:");
        console.log(
            "Vault totalValue:",
            vaultHub.totalValue(address(stakingVault))
        );
        console.log("Wrapper totalAssets:", wrapper.totalAssets());
        console.log("Wrapper totalSupply:", wrapper.totalSupply());
        console.log("ShareRate:", wrapper.calculateShareRate());

        // 2. Users request withdrawals
        vm.startPrank(user1);
        uint256 requestId1 = wrapper.withdraw(5 ether, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 requestId2 = wrapper.withdraw(8 ether, user2, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        uint256 requestId3 = wrapper.withdraw(6 ether, user3, user3);
        vm.stopPrank();

        // 3. Simulate slashing - vault loses 20% of value
        uint256 newTotalValue = (vaultHub.totalValue(address(stakingVault)) *
            80) / 100; // 20% loss
        vaultHub.mock_simulateRewards(address(stakingVault), -200 ether);

        console.log("\nAfter slashing:");
        console.log(
            "Vault totalValue:",
            vaultHub.totalValue(address(stakingVault))
        );
        console.log("Wrapper totalAssets:", wrapper.totalAssets());
        console.log("Wrapper totalSupply:", wrapper.totalSupply());
        console.log("ShareRate:", wrapper.calculateShareRate());

        // 4. Node operator finalizes withdrawals with discounted share rate
        vm.startPrank(nodeOperator);
        uint256 totalRequested = 5 ether + 8 ether + 6 ether; // 19 ETH
        uint256 availableAfterSlashing = (totalRequested * 80) / 100; // 15.2 ETH
        withdrawalQueue.finalize(
            3,
            availableAfterSlashing,
            wrapper.calculateShareRate()
        ); // Finalize all requests
        vm.stopPrank();

        // 5. Check checkpoint with discounted share rate
        WithdrawalQueue.Checkpoint memory checkpoint = withdrawalQueue
            .getCheckpoint(1);
        console.log("Checkpoint shareRate:", checkpoint.shareRate);
        console.log("Expected shareRate (0.8)_:");

        // 6. Users claim their withdrawals (should be discounted)
        uint256 user1Claimable = withdrawalQueue.calculateClaimableAssets(1);
        uint256 user2Claimable = withdrawalQueue.calculateClaimableAssets(2);
        uint256 user3Claimable = withdrawalQueue.calculateClaimableAssets(3);

        console.log("\nClaimable amounts:");
        console.log("User1 (5 ETH):", user1Claimable / 1e18, "ETH");
        console.log("User2 (8 ETH):", user2Claimable / 1e18, "ETH");
        console.log("User3 (6 ETH):", user3Claimable / 1e18, "ETH");

        // 7. Users claim
        vm.startPrank(user1);
        withdrawalQueue.claim(1);
        vm.stopPrank();

        vm.startPrank(user2);
        withdrawalQueue.claim(2);
        vm.stopPrank();

        vm.startPrank(user3);
        withdrawalQueue.claim(3);
        vm.stopPrank();

        // 8. Verify discounted balances
        uint256 expectedUser1Balance = 100 ether -
            10 ether +
            ((5 ether * 80) / 100); // 94 ETH
        uint256 expectedUser2Balance = 100 ether -
            20 ether +
            ((8 ether * 80) / 100); // 86.4 ETH
        uint256 expectedUser3Balance = 100 ether -
            15 ether +
            ((6 ether * 80) / 100); // 89.8 ETH

        console.log("\nFinal balances:");
        console.log(
            "User1 expected: %s ETH, actual: %s ETH",
            expectedUser1Balance,
            user1.balance
        );
        console.log(
            "User2 expected: %s ETH, actual: %s ETH",
            expectedUser2Balance,
            user2.balance
        );
        console.log(
            "User3 expected: %s ETH, actual: %s ETH",
            expectedUser3Balance,
            user3.balance
        );

        assertApproxEqRel(user1.balance, expectedUser1Balance, 0.01e18); // 1% tolerance
        assertApproxEqRel(user2.balance, expectedUser2Balance, 0.01e18);
        assertApproxEqRel(user3.balance, expectedUser3Balance, 0.01e18);
    }

    function test_PartialFinalization() public {
        // 1. Users deposit
        vm.startPrank(user1);
        wrapper.deposit(10 ether, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        wrapper.deposit(20 ether, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        wrapper.deposit(15 ether, user3);
        vm.stopPrank();

        // 2. Users request withdrawals
        vm.startPrank(user1);
        uint256 requestId1 = wrapper.withdraw(5 ether, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 requestId2 = wrapper.withdraw(8 ether, user2, user2);
        vm.stopPrank();

        vm.startPrank(user3);
        uint256 requestId3 = wrapper.withdraw(6 ether, user3, user3);
        vm.stopPrank();

        // 3. Node operator finalizes only first two requests
        vm.startPrank(nodeOperator);
        uint256 totalRequested = 5 ether + 8 ether; // 13 ETH
        withdrawalQueue.finalize(
            2,
            totalRequested,
            wrapper.calculateShareRate()
        ); // Only finalize request1 and request2
        vm.stopPrank();

        // 4. Check state
        assertEq(withdrawalQueue.lastFinalizedRequestId(), 2);

        // 5. Users can claim only finalized requests
        vm.startPrank(user1);
        withdrawalQueue.claim(1);
        vm.stopPrank();

        vm.startPrank(user2);
        withdrawalQueue.claim(2);
        vm.stopPrank();

        // 6. User3 cannot claim yet
        vm.startPrank(user3);
        vm.expectRevert(); // Should revert - not finalized
        withdrawalQueue.claim(3);
        vm.stopPrank();

        // 7. Later, finalize request3
        vm.startPrank(nodeOperator);
        totalRequested = 6 ether;
        withdrawalQueue.finalize(
            3,
            totalRequested,
            wrapper.calculateShareRate()
        );
        vm.stopPrank();

        // 8. Now user3 can claim
        vm.startPrank(user3);
        withdrawalQueue.claim(3);
        vm.stopPrank();
    }

    function test_FIFOOrder() public {
        // 1. Users deposit
        vm.startPrank(user1);
        wrapper.deposit(10 ether, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        wrapper.deposit(20 ether, user2);
        vm.stopPrank();

        // 2. Users request withdrawals in order
        vm.startPrank(user1);
        uint256 requestId1 = wrapper.withdraw(5 ether, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 requestId2 = wrapper.withdraw(8 ether, user2, user2);
        vm.stopPrank();

        // 3. Try to finalize request2 without finalizing request1 (should fail)
        vm.startPrank(nodeOperator);
        vm.expectRevert(); // Should revert - cannot skip request1
        withdrawalQueue.finalize(2, 13 ether, wrapper.calculateShareRate());
        vm.stopPrank();

        // 4. Finalize in correct order
        vm.startPrank(nodeOperator);
        uint256 totalRequested = 5 ether + 8 ether; // 13 ETH
        withdrawalQueue.finalize(
            1,
            totalRequested,
            wrapper.calculateShareRate()
        ); // First finalize request1
        withdrawalQueue.finalize(
            2,
            totalRequested,
            wrapper.calculateShareRate()
        ); // Then finalize request2
        vm.stopPrank();

        // 5. Verify finalization order
        assertEq(withdrawalQueue.lastFinalizedRequestId(), 2);
    }

    function test_ImmediateWithdrawal() public {
        // 1. User deposits
        vm.startPrank(user1);
        wrapper.deposit(10 ether, user1);
        vm.stopPrank();

        // 2. User requests withdrawal (should be immediate)
        vm.startPrank(user1);
        uint256 requestId = wrapper.withdraw(5 ether, user1, user1);
        vm.stopPrank();

        // 3. Check that it was immediate
        assertEq(requestId, 0); // 0 means immediate withdrawal

        // 4. Verify user received ETH immediately
        assertEq(user1.balance, 95 ether); // 100 - 10 + 5
    }
}
