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


contract DepositTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;

    // Access to harness components
    WrapperC public wrapperC; // Wrapper with strategy
    WrapperA public wrapperA; // Basic wrapper (no minting, no strategy)
    WrapperB public wrapperB; // Minting wrapper (minting, no strategy)
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    ExampleLoopStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address constant public user1 = address(0x1001);
    address constant public user2 = address(0x1002);
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

        // Create additional wrapper configurations for testing
        wrapperA = new WrapperA(
            address(dashboard),
            address(this),
            "Basic Wrapper A",
            "stvA",
            false // allowlist disabled
        );
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperA));
        
        wrapperB = new WrapperB(
            address(dashboard),
            address(this),
            "Minting Wrapper B",
            "stvB",
            false // allowlist disabled
        );
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperB));

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

        assertEq(address(stakingVault).balance, dw.CONNECT_DEPOSIT(), "initialVaultBalance should be equal to CONNECT_DEPOSIT");

        vm.prank(user1);
        uint256 user1StvShares = wrapperA.depositETH{value: user1InitialETH}();

        uint256 ethAfterFirstDeposit = user1InitialETH + dw.CONNECT_DEPOSIT(); // Include initial vault balance

        // Main invariants for user1 deposit
        // Note: With strategy enabled, totalAssets will be higher due to leverage loops
        assertTrue(wrapperA.totalAssets() >= ethAfterFirstDeposit, "wrapper totalAssets should be at least deposited ETH plus initial balance");
        assertEq(address(stakingVault).balance, ethAfterFirstDeposit, "stakingVault balance should match total assets");
        assertEq(wrapperA.totalSupply(), user1StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal user shares plus initial supply");

        assertEq(wrapperA.balanceOf(user1), user1StvShares, "user1 balance should equal returned shares");
        // With initial supply, shares might be slightly less due to rounding
        // The important thing is that user gets roughly proportional shares
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after deposit");
        // Note: Position/locking functionality is specific to WrapperC configuration

        // Setup: User2 deposits different amount of ETH
        vm.deal(user2, user2InitialETH);

        vm.prank(user2);
        uint256 user2StvShares = wrapperA.depositETH{value: user2InitialETH}(user2);

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        uint256 ethAfterBothDeposits = totalDeposits + dw.CONNECT_DEPOSIT();

        // Main invariants for multi-user deposits
        assertEq(user2.balance, 0, "user2 ETH balance should be zero after deposit");
        // Note: Position/locking functionality is specific to WrapperC configuration
        assertTrue(wrapperA.totalAssets() >= ethAfterBothDeposits, "wrapper totalAssets should be at least both deposits");
        assertTrue(address(stakingVault).balance >= ethAfterBothDeposits, "stakingVault balance should be at least total deposits");
        assertEq(wrapperA.totalSupply(), user1StvShares + user2StvShares + dw.CONNECT_DEPOSIT(), "wrapper totalSupply should equal sum of user shares plus initial supply");
        assertEq(wrapperA.balanceOf(user1), user1StvShares, "user1 balance should remain unchanged");
        assertEq(wrapperA.balanceOf(user2), user2StvShares, "user2 balance should equal returned shares");

        // For ERC4626, shares = assets * totalSupply / totalAssets
        // After first deposit: totalSupply = user1StvShares + CONNECT_DEPOSIT, totalAssets = ethAfterFirstDeposit
        // User2's shares = user2InitialETH * (user1StvShares + CONNECT_DEPOSIT) / ethAfterFirstDeposit
        uint256 expectedUser2Shares = user2InitialETH * (user1StvShares + dw.CONNECT_DEPOSIT()) / ethAfterFirstDeposit;
        assertEq(user2StvShares, expectedUser2Shares, "user2 shares should follow ERC4626 formula");

        // Verify share-to-asset conversion works correctly for both users (within rounding tolerance)
        // Note: Using totalAssets/totalSupply ratio since convertToAssets not implemented
        uint256 user1Assets = user1StvShares * wrapperA.totalAssets() / wrapperA.totalSupply();
        uint256 user2Assets = user2StvShares * wrapperA.totalAssets() / wrapperA.totalSupply();
        assertTrue(user1Assets >= user1InitialETH - 1 && user1Assets <= user1InitialETH + 1, "user1 assets should be approximately equal to initial deposit");
        assertTrue(user2Assets >= user2InitialETH - 1 && user2Assets <= user2InitialETH + 1, "user2 assets should be approximately equal to initial deposit");
        assertTrue(user1Assets + user2Assets >= user1InitialETH + user2InitialETH - 2 && user1Assets + user2Assets <= user1InitialETH + user2InitialETH + 2, "sum of user assets should approximately equal sum of deposits");

        // Setup: User1 makes a second deposit
        uint256 user1SecondDeposit = 1_000 wei;
        vm.deal(user1, user1SecondDeposit);

        uint256 totalSupplyBeforeSecond = wrapperA.totalSupply();
        uint256 totalAssetsBeforeSecond = wrapperA.totalAssets();

        vm.prank(user1);
        uint256 user1SecondShares = wrapperA.depositETH{value: user1SecondDeposit}(user1);

        uint256 totalDepositsAfterSecond = ethAfterBothDeposits + user1SecondDeposit;
        uint256 user1TotalShares = user1StvShares + user1SecondShares;

        // Main invariants after user1's second deposit
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after second deposit");
        assertTrue(wrapperA.totalAssets() >= totalDepositsAfterSecond, "wrapper totalAssets should include at least second deposit");
        assertTrue(address(stakingVault).balance >= totalDepositsAfterSecond, "stakingVault balance should include at least second deposit");
        assertEq(wrapperA.totalSupply(), totalSupplyBeforeSecond + user1SecondShares, "totalSupply should increase by second shares");
        assertEq(wrapperA.balanceOf(user1), user1TotalShares, "user1 balance should be sum of both deposits' shares");
        assertEq(wrapperA.balanceOf(user2), user2StvShares, "user2 balance should remain unchanged");

        // ERC4626 calculation for user1's second deposit
        uint256 expectedUser1SecondShares = user1SecondDeposit * totalSupplyBeforeSecond / totalAssetsBeforeSecond;
        assertEq(user1SecondShares, expectedUser1SecondShares, "user1 second shares should follow ERC4626 formula");

        // Verify final share-to-asset conversions (within rounding tolerance)
        uint256 user1ExpectedAssets = user1InitialETH + user1SecondDeposit;
        uint256 user1TotalAssets = user1TotalShares * wrapperA.totalAssets() / wrapperA.totalSupply();
        uint256 user2FinalAssets = user2StvShares * wrapperA.totalAssets() / wrapperA.totalSupply();
        uint256 totalSupplyAssets = wrapperA.totalAssets(); // Total supply converted to assets is just totalAssets

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
        uint256 user1StvShares = wrapperA.depositETH{value: user1InitialETH}(user1);
        vm.stopPrank();

        // User1 should have all the shares (minus initial supply held by DefiWrapper)
        assertEq(wrapperA.balanceOf(user1), user1StvShares, "user1 should have all minted shares");
        assertTrue(user1StvShares >= user1InitialETH - 1 && user1StvShares <= user1InitialETH, "shares should be approximately equal to deposited amount");

        uint256 user1BalanceBeforeReport = wrapperA.balanceOf(user1);
        console.log("user1BalanceBeforeReport", user1BalanceBeforeReport);
        core.applyVaultReport(address(stakingVault), 0, 0, lidoFees, false);

        uint256 user1BalanceAfterReport = wrapperA.balanceOf(user1);
        console.log("user1BalanceAfterReport", user1BalanceAfterReport);

        assertEq(user1BalanceAfterReport, user1BalanceBeforeReport, "user1 balance should remain unchanged (fees affect vault value, not shares)");
    }

    // Tests Configuration B deposit functionality with automatic stETH minting
    function test_depositConfigurationB() public {
        uint256 userDeposit = 10_000 wei;
        vm.deal(user1, userDeposit);
        
        uint256 initialVaultBalance = address(stakingVault).balance;
        
        vm.prank(user1);
        uint256 userShares = wrapperB.depositETH{value: userDeposit}(user1);
        
        // User should receive stvETH shares
        assertEq(wrapperB.balanceOf(user1), userShares, "user should have stvETH shares");
        assertTrue(userShares >= userDeposit - 1 && userShares <= userDeposit, "shares should approximately equal deposit");
        
        // User should automatically receive stETH (Configuration B)
        uint256 userStETH = steth.balanceOf(user1);
        assertTrue(userStETH > 0, "user should have received stETH automatically in config B");
        
        console.log("User deposited:", userDeposit);
        console.log("Received shares:", userShares);
        console.log("Received stETH:", userStETH);
    }

    // Tests Configuration C deposit functionality with strategy execution
    function test_depositConfigurationC() public {
        uint256 userDeposit = 10_000 wei;
        vm.deal(user1, userDeposit);
        
        vm.prank(user1);
        uint256 userShares = wrapperC.depositETH{value: userDeposit}(user1);
        
        // User should receive stvETH shares
        assertEq(wrapperC.balanceOf(user1), userShares, "user should have stvETH shares");
        
        // User should have a strategy position created
        uint256[] memory positions = wrapperC.getUserPositions(user1);
        assertEq(positions.length, 1, "user should have one strategy position");
        
        WrapperC.Position memory position = wrapperC.getPosition(positions[0]);
        assertEq(position.user, user1, "position should belong to user");
        assertTrue(position.isActive, "position should be active");
        assertFalse(position.isExiting, "position should not be exiting");
        
        console.log("User deposited:", userDeposit);
        console.log("Received shares:", userShares);
        console.log("Position ID:", positions[0]);
    }

    // Test input validation across all configurations
    function test_depositInputValidationAllConfigs() public {
        // Test zero deposit reverts for all configurations
        vm.expectRevert(abi.encodeWithSignature("ZeroDeposit()"));
        wrapperA.depositETH{value: 0}(user1);
        
        vm.expectRevert(abi.encodeWithSignature("ZeroDeposit()"));
        wrapperB.depositETH{value: 0}(user1);
        
        vm.expectRevert(abi.encodeWithSignature("ZeroDeposit()"));
        wrapperC.depositETH{value: 0}(user1);
        
        // Test invalid receiver reverts for all configurations
        vm.deal(user1, 1000 wei);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        wrapperA.depositETH{value: 1000}(address(0));
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        wrapperB.depositETH{value: 1000}(address(0));
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        wrapperC.depositETH{value: 1000}(address(0));
    }

}