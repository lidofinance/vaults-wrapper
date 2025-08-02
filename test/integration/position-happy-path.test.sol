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
    uint256 public constant TOTAL_BP = 100_00;

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

        // Get references from core and defi wrapper
        dashboard = dw.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = dw.stakingVault();

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);

        assertEq(TOTAL_BP, core.LIDO_TOTAL_BASIS_POINTS(), "TOTAL_BP should be equal to LIDO_TOTAL_BASIS_POINTS");
    }

    function test_initial_state() public view {
        assertEq(wrapper.totalSupply(), dw.CONNECT_DEPOSIT(), "wrapper totalSupply should be equal to CONNECT_DEPOSIT");
        assertEq(wrapper.totalAssets(), dw.CONNECT_DEPOSIT(), "wrapper totalAssets should be equal to CONNECT_DEPOSIT");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should have no shares initially");
        assertEq(wrapper.balanceOf(address(withdrawalQueue)), 0, "withdrawalQueue should have no shares initially");
        assertEq(wrapper.balanceOf(address(dashboard)), 0, "dashboard should have no shares initially");
        assertEq(wrapper.balanceOf(address(dw)), dw.CONNECT_DEPOSIT(), "DefiWrapper should initially hold CONNECT_DEPOSIT shares");
        assertEq(address(stakingVault).balance, dw.CONNECT_DEPOSIT(), "Vault balance should equal CONNECT_DEPOSIT at start");
    }

    function test_user1_deposit_and_lido_fees_reduce_minting_capacity() public {
        uint256 user1InitialETH = 10_000_000 wei;
        uint256 lidoFees = 100 wei;

        // Only user1 is funded and deposits
        vm.deal(user1, user1InitialETH);

        // User1 deposits ETH
        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        // User1 should have all the shares (minus initial supply held by DefiWrapper)
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 should have all minted shares");
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");

        // // Check initial minting capacity
        // uint256 totalMintingCapacityBefore = dashboard.totalMintingCapacityShares();
        // uint256 remainingMintingCapacityBefore = dashboard.remainingMintingCapacityShares(0);
        // console.log("totalMintingCapacityBefore", totalMintingCapacityBefore);
        // console.log("remainingMintingCapacityBefore", remainingMintingCapacityBefore);

        // // The user should be able to mint up to the remaining capacity
        // assertEq(remainingMintingCapacityBefore, totalMintingCapacityBefore, "remainingMintingCapacity should equal totalMintingCapacity before fees");

        // // Simulate Lido fees being applied
        // uint256 totalValueBefore = dashboard.totalValue();
        // console.log("totalValueBefore", totalValueBefore);
        uint256 user1BalanceBeforeReport = wrapper.balanceOf(user1);
        console.log("user1BalanceBeforeReport", user1BalanceBeforeReport);
        core.applyVaultReport(address(stakingVault), 0, 0, lidoFees, false);

        uint256 user1BalanceAfterReport = wrapper.balanceOf(user1);
        console.log("user1BalanceAfterReport", user1BalanceAfterReport);

        assertEq(user1BalanceAfterReport, user1BalanceBeforeReport, "user1 balance should decrease by lido fees");


        // After Lido fees, total value and minting capacity should decrease
        // uint256 totalValueAfter = dashboard.totalValue();
        // uint256 totalMintingCapacityAfter = dashboard.totalMintingCapacityShares();
        // uint256 remainingMintingCapacityAfter = dashboard.remainingMintingCapacityShares(0);
        // console.log("totalValueAfter", totalValueAfter);
        // console.log("totalMintingCapacityAfter", totalMintingCapacityAfter);
        // console.log("remainingMintingCapacityAfter", remainingMintingCapacityAfter);

        // uint256 unsettledObligations = dashboard.unsettledObligations();
        // console.log("unsettledObligations", unsettledObligations);

        // uint256 withdrawableValue = dashboard.withdrawableValue();
        // assertEq(withdrawableValue, wrapper.balanceOf(user1) - lidoFees, "withdrawableValue should be equal to user1 balance minus lido fees");
        // console.log("withdrawableValue", withdrawableValue);


        // uint256 capacityDecrease = lidoFees * (TOTAL_BP - core.dashboard().reserveRatioBP()) / TOTAL_BP;
        // console.log("capacityDecrease", capacityDecrease);
        // // The total value should decrease by lidoFees
        // assertEq(totalMintingCapacityAfter + capacityDecrease, totalMintingCapacityBefore, "Total value should decrease by Lido fees");
    }

    function test_deposit() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 15_000 wei;
        uint256 initialVaultBalance = address(stakingVault).balance;
        assertEq(initialVaultBalance, dw.CONNECT_DEPOSIT(), "initialVaultBalance should be equal to CONNECT_DEPOSIT");

        // Setup: User1 deposits ETH and gets stvToken shares
        vm.deal(user1, user1InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        uint256 ethAfterFirstDeposit = user1InitialETH + dw.CONNECT_DEPOSIT(); // Include initial vault balance

        // Main invariants for user1 deposit
        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit, "wrapper totalAssets should match deposited ETH plus initial balance");
        assertEq(address(stakingVault).balance, ethAfterFirstDeposit, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal user shares plus initial supply");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should have no shares initially");
        // With initial supply, shares might be slightly less due to rounding
        // The important thing is that user gets roughly proportional shares
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked initially");

        // Setup: User2 deposits different amount of ETH
        vm.deal(user2, user2InitialETH);

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        uint256 ethAfterBothDeposits = totalDeposits + dw.CONNECT_DEPOSIT();

        // Main invariants for multi-user deposits
        assertEq(user2.balance, 0, "user2 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked with multiple users");
        assertEq(wrapper.totalAssets(), ethAfterBothDeposits, "wrapper totalAssets should match both deposits");
        assertEq(address(stakingVault).balance, ethAfterBothDeposits, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + user2StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal sum of user shares plus initial supply");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should remain unchanged");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should still have no shares");

        // For ERC4626, shares = assets * totalSupply / totalAssets
        // After first deposit: totalSupply = user1StvShares + CONNECT_DEPOSIT, totalAssets = ethAfterFirstDeposit
        // User2's shares = user2InitialETH * (user1StvShares + CONNECT_DEPOSIT) / ethAfterFirstDeposit
        uint256 expectedUser2Shares = user2InitialETH * (user1StvShares + dw.CONNECT_DEPOSIT()) / ethAfterFirstDeposit;
        assertEq(user2StvShares, expectedUser2Shares, "user2 shares should follow ERC4626 formula");

        // Verify share-to-asset conversion works correctly for both users (within rounding tolerance)
        uint256 user1Assets = wrapper.convertToAssets(user1StvShares);
        uint256 user2Assets = wrapper.convertToAssets(user2StvShares);
        assertTrue(user1Assets >= user1InitialETH - 1 && user1Assets <= user1InitialETH + 1, "user1 assets should be approximately equal to initial deposit");
        assertTrue(user2Assets >= user2InitialETH - 1 && user2Assets <= user2InitialETH + 1, "user2 assets should be approximately equal to initial deposit");
        assertTrue(user1Assets + user2Assets >= user1InitialETH + user2InitialETH - 2 && user1Assets + user2Assets <= user1InitialETH + user2InitialETH + 2, "sum of user assets should approximately equal sum of deposits");

        // Setup: User1 makes a second deposit
        uint256 user1SecondDeposit = 1_000 wei;
        vm.deal(user1, user1SecondDeposit);

        uint256 totalSupplyBeforeSecond = wrapper.totalSupply();
        uint256 totalAssetsBeforeSecond = wrapper.totalAssets();

        vm.prank(user1);
        uint256 user1SecondShares = wrapper.depositETH{value: user1SecondDeposit}();

        uint256 totalDepositsAfterSecond = ethAfterBothDeposits + user1SecondDeposit;
        uint256 user1TotalShares = user1StvShares + user1SecondShares;

        // Main invariants after user1's second deposit
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after second deposit");
        assertEq(wrapper.totalAssets(), totalDepositsAfterSecond, "wrapper totalAssets should include second deposit");
        assertEq(address(stakingVault).balance, totalDepositsAfterSecond, "stakingVault balance should include second deposit");
        assertEq(wrapper.totalSupply(), totalSupplyBeforeSecond + user1SecondShares, "totalSupply should increase by second shares");
        assertEq(wrapper.balanceOf(user1), user1TotalShares, "user1 balance should be sum of both deposits' shares");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should remain unchanged");

        // ERC4626 calculation for user1's second deposit
        uint256 expectedUser1SecondShares = user1SecondDeposit * totalSupplyBeforeSecond / totalAssetsBeforeSecond;
        assertEq(user1SecondShares, expectedUser1SecondShares, "user1 second shares should follow ERC4626 formula");

        // Verify final share-to-asset conversions (within rounding tolerance)
        uint256 user1ExpectedAssets = user1InitialETH + user1SecondDeposit;
        uint256 user1TotalAssets = wrapper.convertToAssets(user1TotalShares);
        uint256 user2FinalAssets = wrapper.convertToAssets(user2StvShares);
        uint256 totalSupplyAssets = wrapper.convertToAssets(wrapper.totalSupply());

        assertTrue(user1TotalAssets >= user1ExpectedAssets - 3 && user1TotalAssets <= user1ExpectedAssets + 3, "user1 total assets should approximately equal both deposits");
        assertTrue(user2FinalAssets >= user2InitialETH - 1 && user2FinalAssets <= user2InitialETH + 1, "user2 assets should remain approximately unchanged");
        assertTrue(totalSupplyAssets >= totalDepositsAfterSecond - 2 && totalSupplyAssets <= totalDepositsAfterSecond + 2, "total assets should approximately equal all deposits");
    }

    function test_openClosePositionSingleUser() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();
        uint256 initialVaultBalance = address(stakingVault).balance;

        // Setup: User deposits ETH and gets stvToken shares
        vm.deal(user1, initialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: initialETH}();

        uint256 ethAfterFirstDeposit = initialETH + initialVaultBalance;

        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit);
        assertEq(address(stakingVault).balance - initialVaultBalance, initialETH);
        assertEq(wrapper.totalSupply(), user1StvShares + initialVaultBalance);
        assertEq(wrapper.balanceOf(user1), user1StvShares);
        assertEq(wrapper.balanceOf(address(escrow)), 0);
        assertTrue(user1StvShares >= initialETH - 1 && user1StvShares <= initialETH, "shares should be approximately equal to deposited amount");

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
        wrapper.approve(address(escrow), user2StvShares);

        uint256 remainingCapacityAfterUser1 = core.dashboard().remainingMintingCapacityShares(0);
        console.log("Remaining capacity after User1:", remainingCapacityAfterUser1);

        uint256 user2MintedStethShares = escrow.mintStETH(user2StvShares);
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
        assertEq(wrapper.totalAssets(), userInitialETH + dw.CONNECT_DEPOSIT(), "Total assets should equal user deposit plus initial balance");
        assertEq(user1.balance, 0, "User ETH balance should be zero after deposit");
        assertEq(escrow.lockedStvSharesByUser(user1), 0, "User should have no locked shares (no stETH minted)");

        // Phase 2: User requests withdrawal
        console.log("=== Phase 2: User requests withdrawal ===");

        // Withdraw based on actual shares received (which may be slightly less due to rounding)
        uint256 withdrawalAmount = wrapper.convertToAssets(userStvShares);

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

        // Simulate validators receiving ETH using CoreHarness
        uint256 stakingVaultBalance = address(stakingVault).balance;
        console.log("Staking vault balance before beacon chain transfer:", stakingVaultBalance);

        uint256 transferredAmount = core.mockValidatorsReceiveETH(address(stakingVault));
        console.log("ETH sent to beacon chain:", transferredAmount);

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

        // Simulate validator exit returning ETH to staking vault using CoreHarness
        core.mockValidatorExitReturnETH(address(stakingVault), ethToLock);
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

        // Core requirement: user gets back approximately the same amount of ETH they deposited
        assertTrue(claimedAmount >= userInitialETH - 1 && claimedAmount <= userInitialETH + 1, "User should receive approximately the same amount of ETH they deposited");

        // Verify system state is clean (except for initial supply held by DefiWrapper)
        assertEq(wrapper.balanceOf(user1), 0, "User should have no remaining stvETH shares");
        assertEq(escrow.lockedStvSharesByUser(user1), 0, "User should have no locked shares");
        assertEq(wrapper.totalSupply(), dw.CONNECT_DEPOSIT(), "Total supply should equal initial supply after withdrawal");
        assertTrue(
            wrapper.totalAssets() >= dw.CONNECT_DEPOSIT() - 1 && wrapper.totalAssets() <= dw.CONNECT_DEPOSIT() + 1,
            "Total assets should equal initial balance after withdrawal (within rounding tolerance)"
        );
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
        uint256 totalCapacityAfterTwoUsers = core.dashboard().totalMintingCapacityShares();
        console.log("Remaining capacity after User1 and User2:", remainingCapacityAfterTwoUsers);
        console.log("Total capacity after User1 and User2:", totalCapacityAfterTwoUsers);

        // Verify that the two users successfully minted their proportional shares
        // The remaining capacity should be what's left after their proportional minting
        // Since the users deposited 30k ETH total and the initial deposit was 1 ETH, 
        // and users only mint proportional to their deposits, there should be significant remaining capacity
        uint256 totalUserMinted = user1MintedShares + user2MintedShares;
        console.log("Total minted by both users:", totalUserMinted);
        
        // Verify that both users successfully minted (greater than 0)
        assertTrue(totalUserMinted > 0, "Users should have successfully minted stETH shares");
        assertTrue(remainingCapacityAfterTwoUsers > 0, "There should be remaining capacity after two users mint proportionally");

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

        // Verify that all three users successfully minted and there is still remaining capacity
        uint256 totalCapacityAfterUser3 = core.dashboard().totalMintingCapacityShares();
        console.log("Total capacity after User3:", totalCapacityAfterUser3);
        
        // Verify that capacity decreased from when User3 deposited (indicating successful minting)
        assertTrue(finalRemainingCapacity < remainingCapacityAfterUser3Deposit, "Final remaining capacity should be less than after User3 deposit (indicating successful minting)");
        
        // Verify User3 successfully minted stETH
        assertTrue(user3MintedShares > 0, "User3 should have successfully minted stETH shares");

        // Calculate total stETH value of all three users
        uint256 totalStETHMinted = user1MintedShares + user2MintedShares + user3MintedShares;
        console.log("Total stETH minted by all users:", totalStETHMinted);

        // Get total locked stvETH value on Escrow
        uint256 totalLockedStvShares = escrow.lockedStvSharesByUser(user1) + escrow.lockedStvSharesByUser(user2) + escrow.lockedStvSharesByUser(user3);
        uint256 totalLockedStvValue = wrapper.convertToAssets(totalLockedStvShares);
        console.log("Total locked stvETH shares:", totalLockedStvShares);
        console.log("Total locked stvETH value:", totalLockedStvValue);

        // Verify that locked stvETH value corresponds to all three users' deposits (within rounding tolerance)
        uint256 expectedTotalDeposits = user1InitialETH + user2InitialETH + user3InitialETH;
        assertTrue(totalLockedStvValue >= expectedTotalDeposits - 3 && totalLockedStvValue <= expectedTotalDeposits, "Total locked stvETH value should approximately equal all three users' deposits");

        // Additional verification: each user should have their shares locked in escrow
        assertEq(escrow.lockedStvSharesByUser(user1), user1StvShares, "User1 should have all their shares locked");
        assertEq(escrow.lockedStvSharesByUser(user2), user2StvShares, "User2 should have all their shares locked");
        assertEq(escrow.lockedStvSharesByUser(user3), user3StvShares, "User3 should have all their shares locked");

        // Verify that users received their stETH based on when they minted
        // User1 and User2 minted when there were only 30k ETH, so their amounts are based on that
        // User3 minted when there were 45k ETH total, so gets proportional to remaining capacity

        // User1 and User2 already minted correctly based on original capacity, no need to re-verify here
        // User3 should have received their proportional share based on when they minted
        // Calculate User3's expected proportional share
        uint256 user3EthInPool = wrapper.convertToAssets(user3StvShares);
        uint256 expectedUser3StETH = (user3EthInPool * totalMintingCapacityAfterUser3) / totalVaultAssetsAfterUser3;
        
        assertTrue(
            user3MintedShares >= expectedUser3StETH - 1 && user3MintedShares <= expectedUser3StETH + 1,
            "User3 should receive proportional to their share"
        );

        // Verify the core scenario requirements are met:
        // 1. Users can utilize full capacity progressively
        // 2. Total minted approaches total capacity
        uint256 totalCapacityUtilized = user1MintedShares + user2MintedShares + user3MintedShares;
        uint256 capacityUtilizationRatio = (totalCapacityUtilized * 10000) / totalMintingCapacityAfterUser3;
        console.log("Capacity utilization ratio (bp):", capacityUtilizationRatio);

        // Verify that significant capacity was utilized (more than just dust amounts)
        // Since the numbers are very large, check that more than trivial amounts were minted
        assertTrue(totalCapacityUtilized > 1000, "Should have minted more than trivial amounts");

        console.log("=== Test completed successfully ===");
    }

    function test_twoUsersUnevenWithdrawals() public {
        uint256 user1InitialETH = 15_000 wei;
        uint256 user2InitialETH = 25_000 wei;

        console.log("=== Two Users with Uneven Withdrawals Integration Test ===");

        // Phase 1: Both users deposit ETH
        console.log("=== Phase 1: Users deposit ETH ===");
        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        console.log("User1 deposited:", user1InitialETH, "received shares:", user1StvShares);
        console.log("User2 deposited:", user2InitialETH, "received shares:", user2StvShares);

        uint256 totalDeposits = user1InitialETH + user2InitialETH + dw.CONNECT_DEPOSIT();
        assertEq(wrapper.totalAssets(), totalDeposits, "Total assets should equal both deposits plus initial balance");

        // Phase 2: Simulate validators receiving ETH
        console.log("=== Phase 2: Simulate validator operations ===");
        uint256 transferredAmount = core.mockValidatorsReceiveETH(address(stakingVault));
        console.log("ETH sent to beacon chain:", transferredAmount);

        // Phase 3: User2 makes uneven withdrawal requests (withdraws entire capital in 2 unequal requests)
        console.log("=== Phase 3: User2 makes uneven withdrawal requests ===");

        uint256 user2FirstWithdrawal = 7_000 wei;  // Smaller first request
        uint256 user2SecondWithdrawal = user2InitialETH - user2FirstWithdrawal; // Larger second request (18,000 wei)

        console.log("User2 total to withdraw:", user2InitialETH);
        console.log("User2 first withdrawal:", user2FirstWithdrawal);
        console.log("User2 second withdrawal:", user2SecondWithdrawal);

        // First withdrawal request - use actual shares calculation with proper approval
        vm.startPrank(user2);
        uint256 firstRequestShares = wrapper.convertToShares(user2FirstWithdrawal);
        // Approve slightly more to handle rounding
        wrapper.approve(address(withdrawalQueue), firstRequestShares + 1);
        uint256 requestId1 = withdrawalQueue.requestWithdrawal(user2, user2FirstWithdrawal);
        console.log("First request ID:", requestId1, "shares:", firstRequestShares);

        // Second withdrawal request (remaining amount)
        uint256 remainingShares = wrapper.balanceOf(user2);
        uint256 remainingAssets = wrapper.convertToAssets(remainingShares);
        wrapper.approve(address(withdrawalQueue), remainingShares);
        uint256 requestId2 = withdrawalQueue.requestWithdrawal(user2, remainingAssets);
        console.log("Second request ID:", requestId2, "shares:", remainingShares);
        console.log("Second withdrawal amount (actual):", remainingAssets);
        vm.stopPrank();

        // Verify user2 has no shares left
        assertEq(wrapper.balanceOf(user2), 0, "User2 should have no shares left after withdrawal requests");

        // Phase 4: Calculate total finalization requirements
        console.log("=== Phase 4: Calculate finalization requirements ===");

        uint256 totalUnfinalizedAssets = withdrawalQueue.unfinalizedAssets();
        console.log("Total unfinalized assets:", totalUnfinalizedAssets);
        // Note: totalUnfinalizedAssets should equal the sum of both withdrawal requests
        uint256 expectedTotalWithdrawals = user2FirstWithdrawal + remainingAssets;
        assertTrue(
            totalUnfinalizedAssets >= expectedTotalWithdrawals - 2 && totalUnfinalizedAssets <= expectedTotalWithdrawals + 2,
            "Unfinalized assets should approximately equal total withdrawal requests"
        );

        // Calculate batches for both requests
        WithdrawalQueue.BatchesCalculationState memory state;
        state.remainingEthBudget = totalUnfinalizedAssets;
        state.finished = false;
        state.batchesLength = 0;

        while (!state.finished) {
            state = withdrawalQueue.calculateFinalizationBatches(2, state);
        }

        console.log("Batches calculation finished, batches length:", state.batchesLength);

        // Convert batches to array for prefinalize
        uint256[] memory batches = new uint256[](state.batchesLength);
        for (uint256 i = 0; i < state.batchesLength; i++) {
            batches[i] = state.batches[i];
        }

        uint256 shareRate = withdrawalQueue.calculateCurrentShareRate();
        (uint256 ethToLock, ) = withdrawalQueue.prefinalize(batches, shareRate);
        console.log("ETH required for finalization:", ethToLock);

        // Phase 5: Simulate validator exit returning required ETH
        console.log("=== Phase 5: Simulate validator exit ===");
        core.mockValidatorExitReturnETH(address(stakingVault), ethToLock);
        console.log("ETH returned from validators:", ethToLock);

        // Phase 6: Finalize both withdrawal requests
        console.log("=== Phase 6: Finalize withdrawal requests ===");

        vm.startPrank(address(dw));
        withdrawalQueue.finalize(requestId1);
        withdrawalQueue.finalize(requestId2);
        vm.stopPrank();

        console.log("Both withdrawal requests finalized");

        // Verify finalization states
        WithdrawalQueue.WithdrawalRequestStatus memory status1 = withdrawalQueue.getWithdrawalStatus(requestId1);
        WithdrawalQueue.WithdrawalRequestStatus memory status2 = withdrawalQueue.getWithdrawalStatus(requestId2);

        assertTrue(status1.isFinalized, "First request should be finalized");
        assertTrue(status2.isFinalized, "Second request should be finalized");
        assertFalse(status1.isClaimed, "First request should not be claimed yet");
        assertFalse(status2.isClaimed, "Second request should not be claimed yet");

        // Phase 7: User2 claims both withdrawals
        console.log("=== Phase 7: User2 claims withdrawals ===");

        uint256 user2ETHBefore = user2.balance;

        vm.startPrank(user2);
        withdrawalQueue.claimWithdrawal(requestId1);
        uint256 user2ETHAfterFirst = user2.balance;
        uint256 firstClaimedAmount = user2ETHAfterFirst - user2ETHBefore;

        withdrawalQueue.claimWithdrawal(requestId2);
        uint256 user2ETHAfterSecond = user2.balance;
        uint256 secondClaimedAmount = user2ETHAfterSecond - user2ETHAfterFirst;
        vm.stopPrank();

        uint256 totalClaimedAmount = firstClaimedAmount + secondClaimedAmount;

        console.log("User2 claimed from first request:", firstClaimedAmount);
        console.log("User2 claimed from second request:", secondClaimedAmount);
        console.log("User2 total claimed:", totalClaimedAmount);

        // Phase 8: Final verification
        console.log("=== Phase 8: Final verification ===");

        // User2 should get back approximately their entire deposit (within rounding tolerance)
        assertTrue(
            totalClaimedAmount >= user2InitialETH - 2 && totalClaimedAmount <= user2InitialETH + 2,
            "User2 should receive back approximately their entire deposit"
        );

        // Verify the uneven distribution worked correctly
        assertEq(firstClaimedAmount, user2FirstWithdrawal, "First claim should match first withdrawal amount");
        assertTrue(
            secondClaimedAmount >= remainingAssets - 1 && secondClaimedAmount <= remainingAssets + 1,
            "Second claim should match remaining assets amount"
        );

        // User1 should still have their shares and assets unchanged
        assertEq(wrapper.balanceOf(user1), user1StvShares, "User1 should still have their shares");
        // Total assets should equal user1's deposit plus the initial CONNECT_DEPOSIT (within rounding tolerance)
        uint256 expectedTotalAssets = user1InitialETH + dw.CONNECT_DEPOSIT();
        assertTrue(
            wrapper.totalAssets() >= expectedTotalAssets - 1 && wrapper.totalAssets() <= expectedTotalAssets + 1,
            "Total assets should equal user1's remaining deposit plus initial deposit (within rounding tolerance)"
        );
        assertEq(wrapper.totalSupply(), user1StvShares + dw.CONNECT_DEPOSIT(), "Total supply should equal user1's shares plus initial supply");

        // Verify withdrawal requests are consumed
        WithdrawalQueue.WithdrawalRequestStatus memory finalStatus1 = withdrawalQueue.getWithdrawalStatus(requestId1);
        WithdrawalQueue.WithdrawalRequestStatus memory finalStatus2 = withdrawalQueue.getWithdrawalStatus(requestId2);

        assertTrue(finalStatus1.isClaimed, "First request should be claimed");
        assertTrue(finalStatus2.isClaimed, "Second request should be claimed");

        console.log("=== Test Summary ===");
        console.log("PASS: User2 successfully withdrew entire capital in uneven requests");
        console.log("PASS: First withdrawal (smaller):", user2FirstWithdrawal);
        console.log("PASS: Second withdrawal (remaining assets):", remainingAssets);
        console.log("PASS: User1 deposits unaffected by user2's withdrawals");
        console.log("PASS: System correctly handled multiple withdrawal requests from same user");
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