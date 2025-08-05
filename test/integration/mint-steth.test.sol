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
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract MintStethTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;

    // Access to harness components
    Wrapper public wrapper;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    ExampleStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address public user1 = address(0x1001);
    address public user2 = address(0x1002);
    address public user3 = address(0x3);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core));

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

    // Tests that stETH minting respects proportional sharing based on user's vault ownership
    // Verifies users can only mint stETH proportional to their stvToken share of total vault capacity
    function test_mintStETHProportionalSharing() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 20_000 wei;

        // Setup: Both users deposit ETH
        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}(user1);

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}(user2);

        uint256 totalDeposits = user1InitialETH + user2InitialETH + dw.CONNECT_DEPOSIT();
        assertEq(wrapper.totalAssets(), totalDeposits);

        // User shares should be approximately proportional to their deposits
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "user1 shares should be approximately equal to deposit");
        assertTrue(user2StvShares >= user2InitialETH - 1 && user2StvShares <= user2InitialETH, "user2 shares should be approximately equal to deposit");

        // Check initial minting capacity for the entire vault
        uint256 totalMintingCapacity = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Total vault minting capacity:", totalMintingCapacity);

        // User1 should only be able to mint proportional to their share (1/3 of capacity)
        vm.startPrank(user1);
        uint256 user1MintedStethShares = wrapper.mintStETH(user1StvShares);
        vm.stopPrank();

        console.log("User1 minted stETH shares:", user1MintedStethShares);

        // Compare totalMintingCapacityShares and remainingMintingCapacityShares
        uint256 totalMintingCapacityShares = core.dashboard().totalMintingCapacityShares();
        uint256 remainingMintingCapacityShares = core.dashboard().remainingMintingCapacityShares(0);
        console.log("totalMintingCapacityShares:", totalMintingCapacityShares);
        console.log("remainingMintingCapacityShares:", remainingMintingCapacityShares);

        // The remaining capacity should be equal to the total capacity minus what user1 minted
        assertEq(
            remainingMintingCapacityShares,
            totalMintingCapacityShares - user1MintedStethShares,
            "remainingMintingCapacityShares should decrease by user1's minted amount"
        );

        // Calculate expected proportional amount for User1
        // The actual calculation in Escrow.sol: (userEthInPool * totalMintingCapacity) / totalVaultAssets
        uint256 expectedUser1Mintable = (user1InitialETH * totalMintingCapacity) / totalDeposits;
        console.log("Expected User1 mintable:", expectedUser1Mintable);

        // User1 should only get their proportional share (within rounding tolerance)
        assertTrue(
            user1MintedStethShares >= expectedUser1Mintable - 1 && user1MintedStethShares <= expectedUser1Mintable + 1,
            "User1 should only mint proportional to their share"
        );
        assertTrue(user1MintedStethShares < totalMintingCapacity, "User1 should not mint entire vault capacity");

        // Now User2 tries to mint their proportional share
        vm.startPrank(user2);
        uint256 remainingCapacityAfterUser1 = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Remaining capacity after User1:", remainingCapacityAfterUser1);

        uint256 user2MintedStethShares = wrapper.mintStETH(user2StvShares);
        vm.stopPrank();

        console.log("User2 minted stETH shares:", user2MintedStethShares);

        // Calculate expected proportional amount for User2
        uint256 expectedUser2Mintable = (user2InitialETH * totalMintingCapacity) / totalDeposits;
        console.log("Expected User2 mintable:", expectedUser2Mintable);

        // User2 should get their proportional share of the total capacity (within rounding tolerance)
        assertTrue(
            user2MintedStethShares >= expectedUser2Mintable - 1 && user2MintedStethShares <= expectedUser2Mintable + 1,
            "User2 should mint proportional to their share"
        );

        // Both users should have received proportional amounts
        uint256 user1ShareRatio = (user1InitialETH * 10000) / totalDeposits;  // Includes CONNECT_DEPOSIT in total
        uint256 user2ShareRatio = (user2InitialETH * 10000) / totalDeposits;  // Includes CONNECT_DEPOSIT in total

        console.log("User1 share ratio (bp):", user1ShareRatio);
        console.log("User2 share ratio (bp):", user2ShareRatio);

        assertTrue(user2MintedStethShares > user1MintedStethShares, "User2 should mint more than User1 due to larger share");
    }

    // Tests the liability tracking system when users mint stETH against their stvToken collateral
    // Demonstrates Case 3: remainingMintingCapacity < totalMintingCapacity due to outstanding stETH liabilities
    function test_mockLiabilities() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 20_000 wei;

        // Setup: Initial state without any liabilities
        console.log("=== Initial State (No Liabilities) ===");

        // Check initial capacity when vault has no liabilities
        uint256 initialTotalCapacity = core.dashboard().totalMintingCapacityShares();
        uint256 initialRemainingCapacity = core.dashboard().remainingMintingCapacityShares(0);
        uint256 initialLiabilityShares = core.dashboard().liabilityShares();
        uint256 initialUnsettledObligations = core.dashboard().unsettledObligations();

        console.log("Initial total minting capacity:", initialTotalCapacity);
        console.log("Initial remaining capacity:", initialRemainingCapacity);
        console.log("Initial liability shares:", initialLiabilityShares);
        console.log("Initial unsettled obligations:", initialUnsettledObligations);

        // In initial state, remaining should equal total (no liabilities)
        assertEq(initialRemainingCapacity, initialTotalCapacity, "Initially, remaining capacity should equal total capacity");
        assertEq(initialLiabilityShares, 0, "Initially, there should be no liability shares");
        assertEq(initialUnsettledObligations, 0, "Initially, there should be no unsettled obligations");

        // Phase 1: Users deposit ETH
        console.log("=== Phase 1: Users deposit ETH ===");

        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.startPrank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}(user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}(user2);
        vm.stopPrank();

        console.log("User1 deposited:", user1InitialETH, "received shares:", user1StvShares);
        console.log("User2 deposited:", user2InitialETH, "received shares:", user2StvShares);

        // Check capacity after deposits (should still be equal since no stETH minted yet)
        uint256 totalCapacityAfterDeposits = core.dashboard().totalMintingCapacityShares();
        uint256 remainingCapacityAfterDeposits = core.dashboard().remainingMintingCapacityShares(0);

        console.log("Total capacity after deposits:", totalCapacityAfterDeposits);
        console.log("Remaining capacity after deposits:", remainingCapacityAfterDeposits);

        // Should still be equal since no stETH has been minted yet
        assertEq(remainingCapacityAfterDeposits, totalCapacityAfterDeposits, "After deposits, remaining should still equal total (no stETH minted yet)");

        // Phase 2: User1 mints stETH to create liabilities
        console.log("=== Phase 2: User1 mints stETH (creates liabilities) ===");

        vm.startPrank(user1);
        uint256 user1MintedShares = wrapper.mintStETH(user1StvShares);
        vm.stopPrank();

        console.log("User1 minted stETH shares:", user1MintedShares);

        // Check capacity after User1 mints (now we should have liabilities)
        uint256 totalCapacityAfterUser1Mint = core.dashboard().totalMintingCapacityShares();
        uint256 remainingCapacityAfterUser1Mint = core.dashboard().remainingMintingCapacityShares(0);
        uint256 liabilitySharesAfterUser1Mint = core.dashboard().liabilityShares();
        uint256 unsettledObligationsAfterUser1Mint = core.dashboard().unsettledObligations();

        console.log("Total capacity after User1 mint:", totalCapacityAfterUser1Mint);
        console.log("Remaining capacity after User1 mint:", remainingCapacityAfterUser1Mint);
        console.log("Liability shares after User1 mint:", liabilitySharesAfterUser1Mint);
        console.log("Unsettled obligations after User1 mint:", unsettledObligationsAfterUser1Mint);

        // Now we should see the difference: remainingMintingCapacityShares != totalMintingCapacityShares
        console.log("=== Liability Impact Verification ===");

        // The core test: remaining capacity should be less than total capacity due to liabilities
        assertTrue(remainingCapacityAfterUser1Mint < totalCapacityAfterUser1Mint, "CASE 3 CONDITION: remainingMintingCapacityShares should be less than totalMintingCapacityShares due to liabilities");

        // The difference should be related to the liability shares created
        uint256 capacityDifference = totalCapacityAfterUser1Mint - remainingCapacityAfterUser1Mint;
        console.log("Capacity difference due to liabilities:", capacityDifference);

        // The liability shares should now be greater than 0
        assertGt(liabilitySharesAfterUser1Mint, 0, "Liability shares should be created after minting stETH");

        // The difference in capacity should equal the minted stETH shares (the liability)
        assertEq(capacityDifference, user1MintedShares, "Capacity difference should equal the minted stETH shares");

        // Phase 3: User2 mints to further increase liabilities
        console.log("=== Phase 3: User2 mints stETH (increases liabilities) ===");

        vm.startPrank(user2);
        uint256 user2MintedShares = wrapper.mintStETH(user2StvShares);
        vm.stopPrank();

        console.log("User2 minted stETH shares:", user2MintedShares);

        // Check final state
        uint256 finalTotalCapacity = core.dashboard().totalMintingCapacityShares();
        uint256 finalRemainingCapacity = core.dashboard().remainingMintingCapacityShares(0);
        uint256 finalLiabilityShares = core.dashboard().liabilityShares();

        console.log("Final total capacity:", finalTotalCapacity);
        console.log("Final remaining capacity:", finalRemainingCapacity);
        console.log("Final liability shares:", finalLiabilityShares);

        // Final verification
        uint256 totalMintedStETH = user1MintedShares + user2MintedShares;
        uint256 finalCapacityDifference = finalTotalCapacity - finalRemainingCapacity;

        console.log("Total stETH minted by both users:", totalMintedStETH);
        console.log("Final capacity difference:", finalCapacityDifference);

        // The final difference should equal the total stETH minted (total liabilities)
        assertEq(finalCapacityDifference, totalMintedStETH, "Final capacity difference should equal total minted stETH");

        // Summary: This test demonstrates Case 3 from scenarios.md
        console.log("=== Test Summary ===");
        console.log("PASS: Demonstrated that remainingMintingCapacityShares < totalMintingCapacityShares when vault has liabilities");
        console.log("PASS: Liabilities are created by minting stETH against stvToken collateral");
        console.log("PASS: The difference in capacity equals the outstanding stETH shares (liabilities)");
        console.log("PASS: Case 3 condition successfully verified");
    }

    // Tests input validation for stETH minting operations
    // Verifies that attempting to mint with zero shares reverts with ZeroStvShares error
    function test_mintStETHInputValidation() public {
        uint256 user1InitialETH = 10_000 wei;

        // Setup: User deposits ETH
        vm.deal(user1, user1InitialETH);
        vm.startPrank(user1);
        wrapper.depositETH{value: user1InitialETH}(user1);
        vm.stopPrank();

        // Test Case: User tries to mint with 0 shares
        // This should revert with ZeroStvShares custom error
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSignature("ZeroStvShares()"));
        wrapper.mintStETH(0);
        vm.stopPrank();
    }

    // Tests ERC20 token transfer error scenarios during stETH minting
    // Verifies proper reversion when users attempt to mint more than balance or allowance
    function test_mintStETHERC20Errors() public {
        uint256 user1InitialETH = 10_000 wei;

        // Setup: User deposits ETH
        vm.deal(user1, user1InitialETH);
        vm.startPrank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}(user1);
        vm.stopPrank();

        // Test Case 1: User tries to mint more than they own
        // This should revert due to insufficient balance
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert with ERC20 transfer error
        wrapper.mintStETH(user1StvShares + 1);
        vm.stopPrank();
    }

}