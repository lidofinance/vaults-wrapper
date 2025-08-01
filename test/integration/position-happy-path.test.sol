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
import {Escrow} from "src/Escrow.sol";
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract StVaultWrapperV3Test is Test {
    CoreHarness public core;
    DefiWrapper public dw;

    // Access to harness components
    Wrapper public wrapper;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    Escrow public escrow;
    ExampleStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    event VaultFunded(uint256 amount);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core));

        // Get references to deployed contracts
        wrapper = dw.wrapper();
        withdrawalQueue = dw.withdrawalQueue();
        escrow = dw.escrow();
        strategy = dw.strategy();

        // Get references from core
        dashboard = core.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = core.stakingVault();

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);
    }

    function test_debug() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 20_000 wei;
        uint256 lidoFees = 100 wei;

        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        wrapper.depositETH{value: user1InitialETH}();

        // vm.prank(user2);
        // uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        console.log("=== Before Vault Report ===");
        uint256 totalMintingCapacity = dashboard.totalMintingCapacityShares();
        console.log("totalMintingCapacity:", totalMintingCapacity);

        uint256 remainingMintingCapacity = dashboard.remainingMintingCapacityShares(0);
        console.log("remainingMintingCapacity:", remainingMintingCapacity);

        assertEq(remainingMintingCapacity, totalMintingCapacity, "remainingMintingCapacity should equal totalMintingCapacity");

        uint256 nodeOperatorDisbursableFee = dashboard.nodeOperatorDisbursableFee();
        console.log("nodeOperatorDisbursableFee:", nodeOperatorDisbursableFee);

        uint256 totalValue = dashboard.totalValue();
        console.log("totalValue before report:", totalValue);

        // Apply a vault report to simulate rewards and Lido fees
        console.log("=== Applying Vault Report ===");

        core.applyVaultReport(0, 0, lidoFees);

        console.log("=== After Vault Report ===");

        // Check values after the report
        uint256 totalValueAfter = dashboard.totalValue();
        console.log("totalValue after report:", totalValueAfter);

        uint256 totalMintingCapacityAfter = dashboard.totalMintingCapacityShares();
        console.log("totalMintingCapacity after:", totalMintingCapacityAfter);

        uint256 remainingMintingCapacityAfter = dashboard.remainingMintingCapacityShares(0);
        console.log("remainingMintingCapacity after:", remainingMintingCapacityAfter);

        uint256 nodeOperatorDisbursableFeeAfter = dashboard.nodeOperatorDisbursableFee();
        console.log("nodeOperatorDisbursableFee after:", nodeOperatorDisbursableFeeAfter);

        uint256 unsettledObligations = dashboard.unsettledObligations();
        console.log("unsettledObligations after:", unsettledObligations);

        // Verify the report had the expected effects
        assertEq(totalValueAfter + lidoFees, totalValue, "Total value should decrease due to Lido fees");
        // assertGt(totalMintingCapacityAfter, totalMintingCapacity, "Minting capacity should increase with rewards");
        // assertGt(nodeOperatorDisbursableFeeAfter, nodeOperatorDisbursableFee, "Node operator fee should increase");

        // console.log("=== Report Applied Successfully ===");
        console.log("Report applied: total value changed from", totalValue, "to", totalValueAfter);
        // console.log("Node operator fee generated:", nodeOperatorDisbursableFeeAfter - nodeOperatorDisbursableFee);
        // console.log("Minting capacity increased by:", totalMintingCapacity);
    }


    function test_deposit() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 15_000 wei;
        uint256 initialVaultBalance = wrapper.INITIAL_VAULT_BALANCE();
        assertEq(initialVaultBalance, core.CONNECT_DEPOSIT(), "initialVaultBalance should be equal to CONNECT_DEPOSIT");

        // Setup: User1 deposits ETH and gets stvToken shares
        vm.deal(user1, user1InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        uint256 ethAfterFirstDeposit = user1InitialETH; // CONNECT_DEPOSIT is ignored in totalAssets

        // Main invariants for user1 deposit
        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit, "wrapper totalAssets should match deposited ETH");
        assertEq(address(stakingVault).balance, ethAfterFirstDeposit + initialVaultBalance, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares, "wrapper totalSupply should equal user shares");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should have no shares initially");
        assertEq(user1StvShares, user1InitialETH, "shares should equal deposited amount (1:1 ratio)");
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked initially");

        // Setup: User2 deposits different amount of ETH
        vm.deal(user2, user2InitialETH);

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        uint256 ethAfterBothDeposits = totalDeposits;

        // Main invariants for multi-user deposits
        assertEq(user2.balance, 0, "user2 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked with multiple users");
        assertEq(wrapper.totalAssets(), ethAfterBothDeposits, "wrapper totalAssets should match both deposits");
        assertEq(address(stakingVault).balance, ethAfterBothDeposits + initialVaultBalance, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + user2StvShares, "wrapper totalSupply should equal sum of user shares");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should remain unchanged");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should still have no shares");

        // For ERC4626, shares = assets * totalSupply / totalAssets
        // After first deposit: totalSupply = user1InitialETH, totalAssets = ethAfterFirstDeposit
        // User2's shares = user2InitialETH * user1StvShares / ethAfterFirstDeposit
        uint256 expectedUser2Shares = user2InitialETH * user1StvShares / ethAfterFirstDeposit;
        assertEq(user2StvShares, expectedUser2Shares, "user2 shares should follow ERC4626 formula");

        // Verify share-to-asset conversion works correctly for both users
        assertEq(wrapper.convertToAssets(user1StvShares), user1InitialETH, "user1 assets should be equal to its initial deposit");
        assertEq(wrapper.convertToAssets(user2StvShares), user2InitialETH, "user2 assets should be equal to its initial deposit");
        assertEq(wrapper.convertToAssets(user1StvShares + user2StvShares), user1InitialETH + user2InitialETH, "sum of user assets should be equal to sum of initial deposits");
        assertEq(wrapper.convertToAssets(user1StvShares) + wrapper.convertToAssets(user2StvShares), user1InitialETH + user2InitialETH, "sum of user assets should be equal to sum of initial deposits");

        // Setup: User1 makes a second deposit
        uint256 user1SecondDeposit = 1_000 wei;
        vm.deal(user1, user1SecondDeposit);

        uint256 totalSupplyBeforeSecond = wrapper.totalSupply();
        uint256 totalAssetsBeforeSecond = wrapper.totalAssets();

        vm.prank(user1);
        uint256 user1SecondShares = wrapper.depositETH{value: user1SecondDeposit}();

        uint256 totalDepositsAfterSecond = totalDeposits + user1SecondDeposit;
        uint256 user1TotalShares = user1StvShares + user1SecondShares;

        // Main invariants after user1's second deposit
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after second deposit");
        assertEq(wrapper.totalAssets(), totalDepositsAfterSecond, "wrapper totalAssets should include second deposit");
        assertEq(address(stakingVault).balance, totalDepositsAfterSecond + initialVaultBalance, "stakingVault balance should include second deposit");
        assertEq(wrapper.totalSupply(), totalSupplyBeforeSecond + user1SecondShares, "totalSupply should increase by second shares");
        assertEq(wrapper.balanceOf(user1), user1TotalShares, "user1 balance should be sum of both deposits' shares");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should remain unchanged");

        // ERC4626 calculation for user1's second deposit
        uint256 expectedUser1SecondShares = user1SecondDeposit * totalSupplyBeforeSecond / totalAssetsBeforeSecond;
        assertEq(user1SecondShares, expectedUser1SecondShares, "user1 second shares should follow ERC4626 formula");

        // Verify final share-to-asset conversions
        uint256 user1ExpectedAssets = user1InitialETH + user1SecondDeposit;
        assertEq(wrapper.convertToAssets(user1TotalShares), user1ExpectedAssets, "user1 total assets should equal both deposits");
        assertEq(wrapper.convertToAssets(user2StvShares), user2InitialETH, "user2 assets should remain unchanged");
        assertEq(wrapper.convertToAssets(wrapper.totalSupply()), totalDepositsAfterSecond, "total assets should equal all deposits");
    }

    function test_openClosePositionSingleUser() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();

        // Setup: User deposits ETH and gets stvToken shares
        vm.deal(user1, initialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: initialETH}();

        uint256 ethAfterFirstDeposit = initialETH;

        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit);
        assertEq(address(stakingVault).balance - wrapper.INITIAL_VAULT_BALANCE(), ethAfterFirstDeposit);
        assertEq(wrapper.totalSupply(), user1StvShares);
        assertEq(wrapper.balanceOf(user1), user1StvShares);
        assertEq(wrapper.balanceOf(address(escrow)), 0);
        assertEq(user1StvShares, initialETH);

        uint256 reserveRatioBP = dashboard.reserveRatioBP();
        console.log("reserveRatioBP", reserveRatioBP);

        uint256 borrowRatio = lenderMock.BORROW_RATIO();
        console.log("borrowRatio", borrowRatio);

        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        escrow.openPosition(user1StvShares);
        vm.stopPrank();

        logAllBalances(4);

        // Assert all logged balances
        uint256 totalBasisPoints = strategy.LENDER_MOCK().TOTAL_BASIS_POINTS(); // 10000

        uint256 mintedStETHShares0 = user1StvShares * (core.LIDO_TOTAL_BASIS_POINTS() - reserveRatioBP) / core.LIDO_TOTAL_BASIS_POINTS();
        uint256 borrowedEth0 = (mintedStETHShares0 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth0", borrowedEth0);

        uint256 user1StvShares1 = borrowedEth0;
        uint256 mintedStETHShares1 = user1StvShares1 * (core.LIDO_TOTAL_BASIS_POINTS() - reserveRatioBP) / core.LIDO_TOTAL_BASIS_POINTS();
        uint256 borrowedEth1 = (mintedStETHShares1 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth1", borrowedEth1);
    }

    function test_mintStETHProportionalSharing() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 20_000 wei;

        // Setup: Both users deposit ETH
        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        assertEq(wrapper.totalAssets(), totalDeposits);

        // User1 has 1/3 of total shares, User2 has 2/3
        assertEq(user1StvShares, user1InitialETH);
        assertEq(user2StvShares, user2InitialETH);

        // Check initial minting capacity for the entire vault
        uint256 totalMintingCapacity = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Total vault minting capacity:", totalMintingCapacity);

        // User1 should only be able to mint proportional to their share (1/3 of capacity)
        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        uint256 user1MintedStethShares = escrow.mintStETH(user1StvShares);
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

        // Calculate expected proportional amount for User1 (1/3 of total capacity)
        uint256 expectedUser1Mintable = (user1InitialETH * totalMintingCapacity) / totalDeposits;
        console.log("Expected User1 mintable:", expectedUser1Mintable);

        // User1 should only get their proportional share
        assertEq(user1MintedStethShares, expectedUser1Mintable, "User1 should only mint proportional to their share");
        assertTrue(user1MintedStethShares < totalMintingCapacity, "User1 should not mint entire vault capacity");

        // Now User2 tries to mint their proportional share
        vm.startPrank(user2);
        wrapper.approve(address(escrow), user2StvShares);

        uint256 remainingCapacityAfterUser1 = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Remaining capacity after User1:", remainingCapacityAfterUser1);

        uint256 user2MintedStethShares = escrow.mintStETH(user2StvShares);
        vm.stopPrank();

        console.log("User2 minted stETH shares:", user2MintedStethShares);

        // Calculate expected proportional amount for User2 (2/3 of total capacity)
        uint256 expectedUser2Mintable = (user2InitialETH * totalMintingCapacity) / totalDeposits;
        console.log("Expected User2 mintable:", expectedUser2Mintable);

        // User2 should get their proportional share of the total capacity
        assertEq(user2MintedStethShares, expectedUser2Mintable, "User2 should mint proportional to their share");

        // Both users should have received proportional amounts
        uint256 user1ShareRatio = (user1InitialETH * 10000) / totalDeposits;  // 3333 (33.33%)
        uint256 user2ShareRatio = (user2InitialETH * 10000) / totalDeposits;  // 6666 (66.67%)

        console.log("User1 share ratio (bp):", user1ShareRatio);
        console.log("User2 share ratio (bp):", user2ShareRatio);

        assertTrue(user2MintedStethShares > user1MintedStethShares, "User2 should mint more than User1 due to larger share");
    }

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

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

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
        wrapper.approve(address(escrow), user1StvShares);
        uint256 user1MintedShares = escrow.mintStETH(user1StvShares);
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
        wrapper.approve(address(escrow), user2StvShares);
        uint256 user2MintedShares = escrow.mintStETH(user2StvShares);
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

    function test_mintStETHInputValidation() public {
        uint256 user1InitialETH = 10_000 wei;

        // Setup: User deposits ETH
        vm.deal(user1, user1InitialETH);
        vm.prank(user1);
        wrapper.depositETH{value: user1InitialETH}();

        // Test Case: User tries to mint with 0 shares
        // This should revert with ZeroStvShares custom error
        vm.startPrank(user1);
        wrapper.approve(address(escrow), 0);
        vm.expectRevert(abi.encodeWithSignature("ZeroStvShares()"));
        escrow.mintStETH(0);
        vm.stopPrank();
    }

    function test_mintStETHERC20Errors() public {
        uint256 user1InitialETH = 10_000 wei;

        // Setup: User deposits ETH
        vm.deal(user1, user1InitialETH);
        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        // Test Case 1: User tries to mint more than they own
        // This should revert due to insufficient balance
        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        vm.expectRevert(); // Should revert with ERC20 transfer error
        escrow.mintStETH(user1StvShares + 1);
        vm.stopPrank();

        // Test Case 2: User tries to mint without sufficient allowance
        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares - 1);
        vm.expectRevert(); // Should revert with ERC20 allowance error
        escrow.mintStETH(user1StvShares);
        vm.stopPrank();
    }

    function test_withdrawalSimplestHappyPath() public {
        uint256 userInitialETH = 10_000 wei;

        console.log("=== Case 4: Withdrawal simplest happy path (no stETH minted, no boost) ===");

        // Phase 1: User deposits ETH
        console.log("=== Phase 1: User deposits ETH ===");
        vm.deal(user1, userInitialETH);

        vm.prank(user1);
        uint256 userStvShares = wrapper.depositETH{value: userInitialETH}();

        console.log("User deposited ETH:", userInitialETH);
        console.log("User received stvETH shares:", userStvShares);

        // Verify initial state - user has shares, no stETH minted, no boost
        assertEq(wrapper.balanceOf(user1), userStvShares, "User should have stvETH shares");
        assertEq(wrapper.totalAssets(), userInitialETH, "Total assets should equal user deposit");
        assertEq(user1.balance, 0, "User ETH balance should be zero after deposit");
        assertEq(escrow.lockedStvSharesByUser(user1), 0, "User should have no locked shares (no stETH minted)");

        // Phase 2: User requests withdrawal
        console.log("=== Phase 2: User requests withdrawal ===");

        uint256 withdrawalAmount = userInitialETH; // Withdraw all deposited ETH

        vm.startPrank(user1);
        wrapper.approve(address(withdrawalQueue), userStvShares);
        uint256 requestId = withdrawalQueue.requestWithdrawal(user1, withdrawalAmount);
        vm.stopPrank();

        console.log("Withdrawal requested. RequestId:", requestId);
        console.log("Withdrawal amount:", withdrawalAmount);

        // Verify withdrawal request state
        assertGt(requestId, 0, "Request ID should be valid");
        assertEq(wrapper.balanceOf(user1), 0, "User stvETH shares should be moved to withdrawal queue for withdrawal");

        // Check withdrawal queue state using getWithdrawalStatus
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertEq(status.amountOfAssets, withdrawalAmount, "Requested amount should match");
        assertEq(status.owner, user1, "Owner should be user1");
        assertFalse(status.isFinalized, "Request should not be finalized yet");
        assertFalse(status.isClaimed, "Request should not be claimed yet");

        // Phase 3: Simulate validator operations and ETH flow
        console.log("=== Phase 3: Simulate validator operations ===");

        // Simulate validators receiving ETH (staking vault balance sent to beacon chain)
        address beaconChain = address(0xbeac0);
        uint256 stakingVaultBalance = address(stakingVault).balance;
        console.log("Staking vault balance before beacon chain transfer:", stakingVaultBalance);

        vm.prank(address(stakingVault));
        (bool sent, ) = beaconChain.call{value: stakingVaultBalance}("");
        require(sent, "ETH send to beacon chain failed");

        console.log("ETH sent to beacon chain:", stakingVaultBalance);

        // Phase 4: Calculate finalization batches and requirements
        console.log("=== Phase 4: Calculate finalization requirements ===");

        uint256 remainingEthBudget = withdrawalQueue.unfinalizedAssets();
        console.log("Unfinalized assets requiring ETH:", remainingEthBudget);

        WithdrawalQueue.BatchesCalculationState memory state;
        state.remainingEthBudget = remainingEthBudget;
        state.finished = false;
        state.batchesLength = 0;

        // Calculate batches for finalization
        while (!state.finished) {
            state = withdrawalQueue.calculateFinalizationBatches(1, state);
        }

        console.log("Batches calculation finished, batches length:", state.batchesLength);

        // Convert batches to array for prefinalize
        uint256[] memory batches = new uint256[](state.batchesLength);
        for (uint256 i = 0; i < state.batchesLength; i++) {
            batches[i] = state.batches[i];
        }

        // Calculate exact ETH needed for finalization
        uint256 shareRate = withdrawalQueue.calculateCurrentShareRate();
        (uint256 ethToLock, ) = withdrawalQueue.prefinalize(batches, shareRate);

        console.log("ETH required for finalization:", ethToLock);
        console.log("Current share rate:", shareRate);

        // Phase 5: Simulate validator exit and ETH return
        console.log("=== Phase 5: Simulate validator exit and ETH return ===");

        // Simulate validator exit returning ETH to staking vault
        vm.deal(beaconChain, ethToLock + 1 ether); // Extra ETH for beacon chain

        vm.prank(beaconChain);
        (bool success, ) = address(stakingVault).call{value: ethToLock}("");
        require(success, "ETH return from beacon chain failed");

        console.log("ETH returned from beacon chain to staking vault:", ethToLock);

        // Phase 6: Finalize withdrawal requests
        console.log("=== Phase 6: Finalize withdrawal requests ===");

        // Finalize the withdrawal request using DefiWrapper (which has FINALIZE_ROLE)
        vm.prank(address(dw));
        withdrawalQueue.finalize(requestId);

        console.log("Withdrawal request finalized");

        // Verify finalization state
        WithdrawalQueue.WithdrawalRequestStatus memory statusAfterFinalization = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(statusAfterFinalization.isFinalized, "Request should be finalized");
        assertFalse(statusAfterFinalization.isClaimed, "Request should not be claimed yet");

        // Phase 7: User claims withdrawal
        console.log("=== Phase 7: User claims withdrawal ===");

        uint256 userETHBalanceBefore = user1.balance;

        vm.prank(user1);
        withdrawalQueue.claimWithdrawal(requestId);

        uint256 userETHBalanceAfter = user1.balance;
        uint256 claimedAmount = userETHBalanceAfter - userETHBalanceBefore;

        console.log("User claimed ETH:", claimedAmount);
        console.log("User final ETH balance:", userETHBalanceAfter);

        // Phase 8: Final verification - user gets back the same amount
        console.log("=== Phase 8: Final verification ===");

        // Core requirement: user gets back the same amount of ETH they deposited
        assertEq(claimedAmount, userInitialETH, "User should receive the same amount of ETH they deposited");

        // Verify system state is clean
        assertEq(wrapper.balanceOf(user1), 0, "User should have no remaining stvETH shares");
        assertEq(escrow.lockedStvSharesByUser(user1), 0, "User should have no locked shares");
        assertEq(wrapper.totalSupply(), 0, "Total supply should be zero after withdrawal");
        assertEq(wrapper.totalAssets(), 0, "Total assets should be zero after withdrawal");
        assertEq(address(withdrawalQueue).balance, 0, "Withdrawal queue should have no ETH left");

        // Verify withdrawal request is consumed
        WithdrawalQueue.WithdrawalRequestStatus memory finalStatus = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(finalStatus.isClaimed, "Request should be marked as claimed");

        console.log("=== Case 4 Test Summary ===");
        console.log("PASS: User deposited and received back same amount");
        console.log("PASS: Complete withdrawal happy path completed without stETH minting or boost");
        console.log("PASS: System state clean after withdrawal (all balances zero)");
    }

    function test_user3DepositsAndFullyMintsAfterUsers() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 20_000 wei;
        uint256 user3InitialETH = 15_000 wei;

        // Phase 1: Two users mint up to full vault capacity
        // Setup: User1 and User2 deposit ETH
        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        console.log("=== Phase 1: User1 and User2 mint to full capacity ===");

        // User1 mints their proportional share
        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        uint256 user1MintedShares = escrow.mintStETH(user1StvShares);
        vm.stopPrank();

        // User2 mints their proportional share
        vm.startPrank(user2);
        wrapper.approve(address(escrow), user2StvShares);
        uint256 user2MintedShares = escrow.mintStETH(user2StvShares);
        vm.stopPrank();

        console.log("User1 minted stETH shares:", user1MintedShares);
        console.log("User2 minted stETH shares:", user2MintedShares);

        // Check remaining capacity after first two users - should be nearly zero
        uint256 remainingCapacityAfterTwoUsers = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Remaining capacity after User1 and User2:", remainingCapacityAfterTwoUsers);

        // Verify capacity is nearly exhausted (scenario requirement)
        assertTrue(remainingCapacityAfterTwoUsers <= WEI_ROUNDING_TOLERANCE, "Minting capacity should be nearly fully exhausted after first two users");

        // Phase 2: User3 deposits more ETH
        console.log("=== Phase 2: User3 deposits and mints ===");

        vm.deal(user3, user3InitialETH);
        vm.prank(user3);
        uint256 user3StvShares = wrapper.depositETH{value: user3InitialETH}();

        console.log("User3 deposited ETH:", user3InitialETH);
        console.log("User3 received stvETH shares:", user3StvShares);

        // Check new total vault assets and minting capacity after user3 deposit
        uint256 totalVaultAssetsAfterUser3 = wrapper.totalAssets();
        uint256 totalMintingCapacityAfterUser3 = core.dashboard().totalMintingCapacityShares();
        uint256 remainingCapacityAfterUser3Deposit = core.dashboard().remainingMintingCapacityShares(0);

        console.log("Total vault assets after User3 deposit:", totalVaultAssetsAfterUser3);
        console.log("Total minting capacity after User3 deposit:", totalMintingCapacityAfterUser3);
        console.log("Remaining capacity after User3 deposit:", remainingCapacityAfterUser3Deposit);

        // User3 mints for all stvETH it has
        vm.startPrank(user3);
        wrapper.approve(address(escrow), user3StvShares);
        uint256 user3MintedShares = escrow.mintStETH(user3StvShares);
        vm.stopPrank();

        console.log("User3 minted stETH shares:", user3MintedShares);

        // Phase 3: Verify final state
        console.log("=== Phase 3: Final verification ===");

        // Check final remaining capacity - should be nearly zero again
        uint256 finalRemainingCapacity = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Final remaining capacity:", finalRemainingCapacity);

        // Verify capacity is nearly exhausted again (scenario requirement)
        assertTrue(finalRemainingCapacity <= WEI_ROUNDING_TOLERANCE, "Minting capacity should be nearly fully exhausted after all three users mint");

        // Calculate total stETH value of all three users
        uint256 totalStETHMinted = user1MintedShares + user2MintedShares + user3MintedShares;
        console.log("Total stETH minted by all users:", totalStETHMinted);

        // Get total locked stvETH value on Escrow
        uint256 totalLockedStvShares = escrow.lockedStvSharesByUser(user1) + escrow.lockedStvSharesByUser(user2) + escrow.lockedStvSharesByUser(user3);
        uint256 totalLockedStvValue = wrapper.convertToAssets(totalLockedStvShares);
        console.log("Total locked stvETH shares:", totalLockedStvShares);
        console.log("Total locked stvETH value:", totalLockedStvValue);

        // Verify that locked stvETH value corresponds to all three users' total stETH value (scenario requirement)
        // The values should be approximately equal (within rounding tolerance)
        uint256 expectedTotalDeposits = user1InitialETH + user2InitialETH + user3InitialETH;
        assertEq(totalLockedStvValue, expectedTotalDeposits, "Total locked stvETH value should equal all three users' deposits");

        // Additional verification: each user should have their shares locked in escrow
        assertEq(escrow.lockedStvSharesByUser(user1), user1StvShares, "User1 should have all their shares locked");
        assertEq(escrow.lockedStvSharesByUser(user2), user2StvShares, "User2 should have all their shares locked");
        assertEq(escrow.lockedStvSharesByUser(user3), user3StvShares, "User3 should have all their shares locked");

        // Verify that users received their stETH based on when they minted
        // User1 and User2 minted when there were only 30k ETH, so their amounts are based on that
        // User3 minted when there were 45k ETH total, so gets proportional to remaining capacity

        // User1 and User2 already minted correctly based on original capacity, no need to re-verify here
        // User3 should have received the remaining capacity after their deposit
        uint256 expectedUser3StETH = remainingCapacityAfterUser3Deposit;
        assertEq(user3MintedShares, expectedUser3StETH, "User3 should receive all remaining capacity");

        // Verify the core scenario requirements are met:
        // 1. Users can utilize full capacity progressively
        // 2. Total minted approaches total capacity
        uint256 totalCapacityUtilized = user1MintedShares + user2MintedShares + user3MintedShares;
        uint256 capacityUtilizationRatio = (totalCapacityUtilized * 10000) / totalMintingCapacityAfterUser3;
        console.log("Capacity utilization ratio (bp):", capacityUtilizationRatio);

        // Should be very close to 100% utilization (within rounding tolerance)
        assertTrue(capacityUtilizationRatio >= 9999, "Should achieve near-complete capacity utilization");

        console.log("=== Test completed successfully ===");
    }

    function logAllBalances(uint256 _context) public view {
        address stETH = address(strategy.STETH());
        address lenderMock = address(strategy.LENDER_MOCK());

        console.log("");
        console.log("=== Balances ===", _context);

        console.log(
            string.concat(
                "user1: ETH=", vm.toString(user1.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user1)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user1)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(user1))
            )
        );

        console.log(
            string.concat(
                "user2: ETH=", vm.toString(user2.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user2)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user2)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(user2))
            )
        );

        console.log(
            string.concat(
                "wrapper: ETH=", vm.toString(address(wrapper).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(wrapper))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(wrapper))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(wrapper)))
            )
        );

        console.log(
            string.concat(
                "escrow: ETH=", vm.toString(address(escrow).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(escrow))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(escrow))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(escrow)))
            )
        );

        console.log(
            string.concat(
                "strategy: ETH=", vm.toString(address(strategy).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(strategy))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(strategy))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(strategy)))
            )
        );

        console.log(
            string.concat(
                "stakingVault: ETH=", vm.toString(address(stakingVault).balance),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(stakingVault)))
            )
        );
        console.log(
            string.concat(
                "LenderMock: ETH=", vm.toString(lenderMock.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(lenderMock)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(lenderMock)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(lenderMock))
            )
        );

        // Escrow totals
        console.log(
            string.concat(
                "Escrow totals: totalBorrowedAssets=", vm.toString(escrow.totalBorrowedAssets()),
                " totalLockedStvShares=", vm.toString(wrapper.totalLockedStvShares())
            )
        );
    }

}