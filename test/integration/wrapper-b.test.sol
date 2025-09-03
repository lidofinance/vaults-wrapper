// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {WrapperB} from "src/WrapperB.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperBTest
 * @notice Integration tests for WrapperB (minting, no strategy)
 */
contract WrapperBTest is Test {
    CoreHarness public core;

    WrapperB public wrapper;
    WithdrawalQueue public withdrawalQueue;

    IDashboard public dashboard;
    IStakingVault public vault;

    // Core contracts
    ILido public steth;
    IVaultHub public vaultHub;

    // Test users
    address public constant USER1 = address(0x1001);
    address public constant USER2 = address(0x1002);
    address public constant USER3 = address(0x1003);

    address public constant NODE_OPERATOR = address(0x1004);

    // Test constants
    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public CONNECT_DEPOSIT;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 0; // 0%
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;
    uint256 public constant RESERVE_RATIO_BP = 20_00; // not configurable
    uint256 public immutable EXTRA_BASE = 10 ** (27 - 18); // not configurable

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        steth = core.steth();
        vaultHub = core.vaultHub();
        address vaultFactory = core.locator().vaultFactory();
        CONNECT_DEPOSIT = vaultHub.CONNECT_DEPOSIT();


        vm.deal(NODE_OPERATOR, 1000 ether);

        Factory factory = new Factory(vaultFactory, address(steth));

        vm.startPrank(NODE_OPERATOR);
        (address vault_, address dashboard_, address payable wrapper_, address withdrawalQueue_) = factory.createVaultWithWrapper{value: CONNECT_DEPOSIT}(
            NODE_OPERATOR, NODE_OPERATOR, NODE_OPERATOR_FEE_RATE, CONFIRM_EXPIRY, Factory.WrapperConfiguration.MINTING_NO_STRATEGY, address(0), false
        );
        vm.stopPrank();

        wrapper = WrapperB(payable(wrapper_));
        withdrawalQueue = WithdrawalQueue(payable(withdrawalQueue_));

        vault = IStakingVault(vault_);
        dashboard = IDashboard(payable(dashboard_));

        vm.startPrank(NODE_OPERATOR);
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), NODE_OPERATOR);
        withdrawalQueue.resume();
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), NODE_OPERATOR);
        vm.stopPrank();


        core.setStethShareRatio(1 ether + 10 ** 17); // 1.1 ETH

        core.applyVaultReport(address(vault), 0, 0, 0, 0, true);

        // // Setup test users with ETH
        // vm.deal(USER1, 1000 ether);
        // vm.deal(USER2, 1000 ether);
        // vm.deal(USER3, 1000 ether);
        // vm.deal(address(this), 10 ether);

        // _deployWrapperBConfiguration();
    }

    // function _deployWrapperBConfiguration() internal {
    //     IVaultFactory vaultFactory = IVaultFactory(core.locator().vaultFactory());

    //     // Deploy Configuration B: minting, no strategy
    //     (address vaultBAddr, address dashboardBAddr) = vaultFactory.createVaultWithDashboard{value: CONNECT_DEPOSIT}(
    //         address(this), address(this), address(this), 0, CONFIRM_EXPIRY, new IVaultFactory.RoleAssignment[](0)
    //     );
    //     vaultB = IStakingVault(vaultBAddr);
    //     dashboardB = IDashboard(payable(dashboardBAddr));
    //     dashboardB.grantRole(dashboardB.DEFAULT_ADMIN_ROLE(), address(this));
    //     core.applyVaultReport(address(vaultB), 0, 0, 0, true);
    //     dashboardB.setNodeOperatorFeeRate(NODE_OPERATOR_FEE_RATE);

    //     wrapperB = new WrapperB(address(dashboardB), address(steth), false);
    //     queueB = new WithdrawalQueue(address(wrapperB));
    //     // queueB.initialize(address(this));

    //     // wrapperB.setWithdrawalQueue(address(queueB));

    //     // queueB.grantRole(queueB.FINALIZE_ROLE(), address(this));
    //     // queueB.resume();
    //     // dashboardB.grantRole(dashboardB.FUND_ROLE(), address(wrapperB));
    //     // dashboardB.grantRole(dashboardB.WITHDRAW_ROLE(), address(queueB));
    // }

    // ========================================================================
    // Case 1: Two users can mint up to the full vault capacity
    // ========================================================================

    function test_initial_state() public {

        console.log("=== Initial State ===");
        assertEq(dashboard.reserveRatioBP(), RESERVE_RATIO_BP, "Reserve ratio should match RESERVE_RATIO_BP constant");
        assertEq(wrapper.EXTRA_DECIMALS_BASE(), EXTRA_BASE, "EXTRA_DECIMALS_BASE should match EXTRA_DECIMALS_BASE constant");

        assertEq(wrapper.totalSupply(), CONNECT_DEPOSIT * EXTRA_BASE, "Total stvETH supply should be equal to CONNECT_DEPOSIT");
        // assertEq(wrapper.totalSupply(), 0, "Total stvETH supply should be equal to CONNECT_DEPOSIT");
        assertEq(wrapper.balanceOf(address(wrapper)), CONNECT_DEPOSIT * EXTRA_BASE, "Wrapper stvETH balance should be equal to CONNECT_DEPOSIT");
        // assertEq(wrapper.balanceOf(address(wrapper)), 0, "Wrapper stvETH balance should be equal to CONNECT_DEPOSIT");

        assertEq(wrapper.balanceOf(NODE_OPERATOR), 0, "stvETH balance of NODE_OPERATOR should be zero");
        assertEq(steth.balanceOf(NODE_OPERATOR), 0, "stETH balance of node operator should be zero");

        assertEq(dashboard.locked(), CONNECT_DEPOSIT, "Vault's locked should be zero");
        assertEq(dashboard.maxLockableValue(), CONNECT_DEPOSIT, "Vault's total value should be CONNECT_DEPOSIT");
        assertEq(dashboard.withdrawableValue(), 0, "Vault's withdrawable value should be zero");
        assertEq(dashboard.liabilityShares(), 0, "Vault's liability shares should be zero");
        assertEq(dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be zero");
        assertEq(dashboard.totalMintingCapacityShares(), 0, "Total minting capacity should be zero");

        assertEq(steth.getPooledEthByShares(1 ether), 1 ether + 10 ** 17, "ETH for 1e18 stETH shares should be 1.1 ETH");

        console.log("Reserve ratio:", dashboard.reserveRatioBP());

        console.log("ETH for 1e18 stETH shares: ", steth.getPooledEthByShares(1 ether));

        assertEq(wrapper._calcMaxMintableStETHSharesForDeposit(10_000 wei), 7272, "Max mintable stETH shares for 10_000 wei should be 9090");

        _assertUniversalInvariants("Initial state");

        // TODO: check NO cannot withdraw the eth
    }


    function _assertUniversalInvariants(string memory _context) internal {

        assertEq(
            wrapper.previewRedeem(wrapper.totalSupply()),
            wrapper.totalAssets(),
            _contextMsg(_context, "previewRedeem(totalSupply) should equal totalAssets")
        );

        address[] memory holders = new address[](5);
        holders[0] = USER1;
        holders[1] = USER2;
        holders[2] = USER3;
        holders[3] = address(wrapper);
        holders[4] = address(withdrawalQueue);

        {
            uint256 totalBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalBalance += wrapper.balanceOf(holders[i]);
            }
            assertEq(
                totalBalance,
                wrapper.totalSupply(),
                _contextMsg(_context, "Sum of all holders' balances should equal totalSupply")
            );
        }

        {   // TODO: what's about 1 wei accuracy?
            uint256 totalPreviewRedeem = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalPreviewRedeem += wrapper.previewRedeem(wrapper.balanceOf(holders[i]));
            }
            uint256 totalAssets = wrapper.totalAssets();
            uint256 diff = totalPreviewRedeem > totalAssets
                ? totalPreviewRedeem - totalAssets
                : totalAssets - totalPreviewRedeem;
            assertTrue(
                diff <= 1,
                _contextMsg(_context, "Sum of previewRedeem of all holders should equal totalAssets (within 1 wei accuracy)")
            );
        }

        {
            uint256 totalStSharesToReturn = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                vm.prank(holders[i]);
                totalStSharesToReturn += wrapper.stSharesToReturn();
            }
            assertEq(
                totalStSharesToReturn,
                dashboard.liabilityShares(),
                _contextMsg(_context, "Sum of stSharesToReturn of all holders should equal stSharesToReturn")
            );
        }

        // Assert for each user: wrapper.stSharesForWithdrawal(wrapper.balanceOf(user)) == stSharesToReturn() called by the user
        for (uint256 i = 0; i < holders.length; i++) {
            address user = holders[i];
            uint256 stvBalance = wrapper.balanceOf(user);
            vm.startPrank(user);
            uint256 stSharesForWithdrawal = wrapper.stSharesForWithdrawal(stvBalance);
            uint256 stSharesToReturn = wrapper.stSharesToReturn();
            vm.stopPrank();
            assertEq(
                stSharesForWithdrawal,
                stSharesToReturn,
                _contextMsg(_context, string(abi.encodePacked("stSharesForWithdrawal(balanceOf(user)) == stSharesToReturn() for user ", vm.toString(user))))
            );
        }

    }

    function test_scenario_1() public {
        console.log("=== Scenario 1 (all fees are zero) ===");

        // Step 1: User1 deposits

        uint256 user1Deposit = 10_000 wei;
        wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 1");

        uint256 wrapperConnectDepositStvShares = CONNECT_DEPOSIT * EXTRA_BASE;
        uint256 expectedUser1StvShares = user1Deposit * EXTRA_BASE - 1;
        uint256 expectedUser1Steth = user1Deposit * (TOTAL_BASIS_POINTS - RESERVE_RATIO_BP) / TOTAL_BASIS_POINTS - 1; // 7999
        uint256 expectedUser1StethShares = steth.getSharesByPooledEth(expectedUser1Steth + 1); // 7272

        assertEq(wrapper.totalAssets(), user1Deposit + CONNECT_DEPOSIT, "Wrapper total assets should be equal to user deposit plus CONNECT_DEPOSIT");
        assertEq(wrapper.totalSupply(), wrapperConnectDepositStvShares + expectedUser1StvShares, "Wrapper total supply should be equal to user deposit plus CONNECT_DEPOSIT");

        assertEq(wrapper.balanceOf(USER1), expectedUser1StvShares, "Wrapper balance of USER1 should be equal to user deposit");
        assertEq(steth.sharesOf(USER1), expectedUser1StethShares, "stETH shares balance of USER1 should be equal to user deposit");
        assertEq(steth.balanceOf(USER1), expectedUser1Steth, "stETH balance of USER1 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER1)), user1Deposit, "Preview redeem should be equal to user deposit");

        assertEq(address(vault).balance, CONNECT_DEPOSIT + user1Deposit, "Vault's balance should be equal to CONNECT_DEPOSIT + user1Deposit");
        assertEq(dashboard.totalValue(), address(vault).balance, "Vault's total value should be equal to its balance");
        assertEq(dashboard.maxLockableValue(), address(vault).balance, "Vault's total value should be equal to its balance");
        assertEq(dashboard.locked(), CONNECT_DEPOSIT + 8000, "Vault's locked should be equal to CONNECT_DEPOSIT");
        assertEq(dashboard.withdrawableValue(), 2000, "Vault's withdrawable value should be zero");
        assertEq(dashboard.liabilityShares(), 7272, "Vault's liability shares should be zero");
        assertEq(dashboard.totalMintingCapacityShares(), 9090, "Total minting capacity should be 9090");
        assertEq(dashboard.remainingMintingCapacityShares(0), 9090 - 7272, "Remaining minting capacity should be zero");

        // Step 2: First update the report to reflect the current vault balance (with deposits)
        // This ensures the quarantine check has the correct baseline

        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(vault), address(vault).balance, 0, 0, 0, false);
        assertEq(dashboard.totalValue(), address(vault).balance, "Vault's total value should be equal to its balance");

        _assertUniversalInvariants("Step 2");

        // Step 3: Now apply the 1% performance increase

        core.setStethShareRatio(((1 ether + 10**17) * 101) / 100); // 1.111 ETH

        uint256 newTotalValue = (CONNECT_DEPOSIT + user1Deposit) * 101 / 100;
        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(vault), newTotalValue, 0, 0, 0, false);

        _assertUniversalInvariants("Step 3");

        assertEq(address(vault).balance, CONNECT_DEPOSIT + user1Deposit, "Vault's balance should be equal to CONNECT_DEPOSIT + user1Deposit");
        assertEq(dashboard.totalValue(), newTotalValue, "Vault's total value should be equal to its balance");
        assertEq(dashboard.maxLockableValue(), newTotalValue, "Vault's total value should be equal to its balance");
        assertEq(wrapper.totalAssets(), newTotalValue, "Wrapper total assets should be equal to new total value minus CONNECT_DEPOSIT");

        assertEq(wrapper.balanceOf(USER1), user1Deposit * EXTRA_BASE - 1, "Wrapper balance of USER1 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER1)), user1Deposit * 101 / 100 - 1, "Preview redeem should be equal to user deposit * 101 / 100");

        // Step 4: User2 deposits

        uint256 user2Deposit = 10_000 wei;
        wrapper.depositETH{value: user2Deposit}(USER2);

        _assertUniversalInvariants("Step 4");

        uint256 expectedUser2StvShares = 9900990099009;
        uint256 expectedUser2Steth = user2Deposit * (TOTAL_BASIS_POINTS - RESERVE_RATIO_BP) / TOTAL_BASIS_POINTS - 1; // 7999
        uint256 expectedUser2StethShares = steth.getSharesByPooledEth(expectedUser2Steth + 1); // 7200

        assertEq(steth.sharesOf(USER2), expectedUser2StethShares, "stETH shares balance of USER2 should be equal to user deposit");
        assertEq(steth.balanceOf(USER2), expectedUser2Steth, "stETH balance of USER2 should be equal to user deposit");
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(USER2)), user2Deposit, "Preview redeem should be equal to user deposit");
        assertEq(wrapper.balanceOf(USER2), expectedUser2StvShares, "Wrapper balance of USER2 should be equal to user deposit");

        assertEq(wrapper.totalSupply(), wrapperConnectDepositStvShares + expectedUser1StvShares + expectedUser2StvShares, "Wrapper total supply should be equal to user deposit plus CONNECT_DEPOSIT");
        assertEq(wrapper.previewRedeem(wrapper.totalSupply()), newTotalValue + user2Deposit, "Preview redeem should be equal to new total value plus user2Deposit");

        // Step 5: User1 deposits the same amount of ETH as before

        wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 5");

        // Step 6: User1 withdraws half of his stvShares

        uint256 user1StvShares = wrapper.balanceOf(USER1);
        uint256 user1StSharesToWithdraw = user1StvShares / 2;
        uint256 user1ExpectedEthWithdrawn = wrapper.previewRedeem(user1StSharesToWithdraw);

        // User1 requests withdrawal of half his shares, expect ALLOWANCE_EXCEEDED revert
        vm.expectRevert("ALLOWANCE_EXCEEDED");
        vm.prank(USER1);
        wrapper.requestWithdrawal(user1StSharesToWithdraw);

        _assertUniversalInvariants("Step 6.1");

        vm.startPrank(USER1);
        uint256 user1StSharesToReturn = wrapper.stSharesForWithdrawal(user1StSharesToWithdraw);
        uint256 user1StethToApprove = 1000 * steth.getPooledEthByShares(user1StSharesToReturn) + 1;
        // NB: allowance is nominated in stETH not its shares
        steth.approve(address(wrapper), user1StethToApprove);
        uint256 requestId = wrapper.requestWithdrawal(user1StSharesToWithdraw);

        vm.expectRevert("RequestNotFoundOrNotFinalized(1)");
        withdrawalQueue.claimWithdrawal(requestId);

        vm.stopPrank();

        vm.prank(NODE_OPERATOR);
        withdrawalQueue.finalize(requestId);

        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized, "Withdrawal request should be finalized");
        assertEq(status.amountOfAssets, user1ExpectedEthWithdrawn, "Withdrawal request amount should match previewRedeem");
        // TODO: check status.amountOfShares

        uint256 user1EthBalanceBeforeClaim = USER1.balance;
        vm.prank(USER1); withdrawalQueue.claimWithdrawal(requestId);

        status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isClaimed, "Withdrawal request should be claimed after claimWithdrawal");

        // TODO: make this check pass
        // _assertUniversalInvariants("Step 6.2");

    }

    // ========================================================================
    // Helper functions
    // ========================================================================

    function _contextMsg(string memory _context, string memory _msg) internal pure returns (string memory) {
        return string(abi.encodePacked(_context, ": ", _msg));
    }

    // function _simulateValidatorExit(IStakingVault vault, WithdrawalQueue queue, uint256 ethNeeded) internal {
    //     // Mock validator exit by sending ETH directly to the vault
    //     uint256 currentBalance = address(vault).balance;
    //     uint256 requiredETH = ethNeeded + currentBalance;

    //     // Use CoreHarness to simulate validator return
    //     core.mockValidatorExitReturnETH(address(vault), ethNeeded);

    //     console.log("Simulated validator exit, returned ETH:", ethNeeded);
    // }
}