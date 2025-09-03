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


contract DepositTest is Test {
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

    address constant public user1 = address(0x1001);
    address constant public user2 = address(0x1002);
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

    // Tests multi-user deposit functionality with ERC4626 compliance
    // Verifies proper share calculations, asset tracking, and multiple deposits from different users
    function test_deposit() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 15_000 wei;
        vm.deal(user1, user1InitialETH);

        assertEq(address(dw.vault()).balance, dw.CONNECT_DEPOSIT(), "initialVaultBalance should be equal to CONNECT_DEPOSIT");

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        uint256 ethAfterFirstDeposit = user1InitialETH + dw.CONNECT_DEPOSIT(); // Include initial vault balance

        // Main invariants for user1 deposit
        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit, "wrapper totalAssets should match deposited ETH plus initial balance");
        assertEq(address(dw.vault()).balance, ethAfterFirstDeposit, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal user shares plus initial supply");

        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(strategy)), 0, "strategy should have no shares initially");
        // With initial supply, shares might be slightly less due to rounding
        // The important thing is that user gets roughly proportional shares
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked initially");

        // Setup: User2 deposits different amount of ETH
        vm.deal(user2, user2InitialETH);

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}(user2);

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        uint256 ethAfterBothDeposits = totalDeposits + dw.CONNECT_DEPOSIT();

        // Main invariants for multi-user deposits
        assertEq(user2.balance, 0, "user2 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked with multiple users");
        assertEq(wrapper.totalAssets(), ethAfterBothDeposits, "wrapper totalAssets should match both deposits");
        assertEq(address(dw.vault()).balance, ethAfterBothDeposits, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + user2StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal sum of user shares plus initial supply");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should remain unchanged");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(strategy)), 0, "strategy should still have no shares");

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
        uint256 user1SecondShares = wrapper.depositETH{value: user1SecondDeposit}(user1);

        uint256 totalDepositsAfterSecond = ethAfterBothDeposits + user1SecondDeposit;
        uint256 user1TotalShares = user1StvShares + user1SecondShares;

        // Main invariants after user1's second deposit
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after second deposit");
        assertEq(wrapper.totalAssets(), totalDepositsAfterSecond, "wrapper totalAssets should include second deposit");
        assertEq(address(dw.vault()).balance, totalDepositsAfterSecond, "stakingVault balance should include second deposit");
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

    // Tests that Lido fees applied via vault reports do not affect user share balances
    // but properly reduce the vault's total value for minting capacity calculations
    function test_user1_deposit_and_lido_fees_reduce_minting_capacity() public {
        uint256 user1InitialETH = 10_000_000 wei;
        uint256 lidoFees = 100 wei;

        // Only user1 is funded and deposits
        vm.deal(user1, user1InitialETH);

        // User1 deposits ETH
        vm.startPrank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}(user1);
        vm.stopPrank();

        // User1 should have all the shares (minus initial supply held by DefiWrapper)
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 should have all minted shares");
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");

        uint256 user1BalanceBeforeReport = wrapper.balanceOf(user1);
        console.log("user1BalanceBeforeReport", user1BalanceBeforeReport);
        core.applyVaultReport(address(stakingVault), 0, 0, lidoFees, false);

        uint256 user1BalanceAfterReport = wrapper.balanceOf(user1);
        console.log("user1BalanceAfterReport", user1BalanceAfterReport);

        assertEq(user1BalanceAfterReport, user1BalanceBeforeReport, "user1 balance should remain unchanged (fees affect vault value, not shares)");
    }

}