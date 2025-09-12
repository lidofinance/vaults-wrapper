// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WrapperA} from "src/WrapperA.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockDashboard} from "../mocks/MockDashboard.sol";
import {MockVaultHub} from "../mocks/MockVaultHub.sol";
import {MockStakingVault} from "../mocks/MockStakingVault.sol";
import {MockLazyOracle} from "../mocks/MockLazyOracle.sol";
import {MockUpgradableWq} from "../mocks/MockUpgradableWq.sol";

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
        WrapperA impl = new WrapperA(
            address(dashboard),
            false // allowlist disabled
        );
        bytes memory initData = abi.encodeCall(
            WrapperA.initialize,
            (admin, admin, "Staked ETH Vault Wrapper", "stvETH")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        wrapper = WrapperA(payable(address(proxy)));

        lazyOracle = new MockLazyOracle();
        vm.label(address(lazyOracle), "LazyOracle");

        // Deploy withdrawal queue
        uint256 maxAcceptableWQFinalizationTimeInSeconds = 60 days;
        address withdrawalQueueImpl = address(new WithdrawalQueue(wrapper, address(lazyOracle), maxAcceptableWQFinalizationTimeInSeconds));
        vm.label(address(withdrawalQueue), "WithdrawalQueue");

        address wqInstance = address(
            new OssifiableProxy({
                implementation_: address(withdrawalQueueImpl),
                data_: new bytes(0),
                admin_: admin
            })
        );
        withdrawalQueue = WithdrawalQueue(payable(wqInstance));
        withdrawalQueue.initialize(admin, operator);
        vm.label(address(wqInstance), "WithdrawalQueue");

        // Grant necessary roles to wrapper for dashboard operations
        vm.startPrank(admin);
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

        wrapper.setWithdrawalQueue(address(withdrawalQueue));
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
        uint256 halfUser1Deposit = user1Shares/2;
        uint256 halfuser1Assets = wrapper.previewRedeem(halfUser1Deposit);
        uint256 user1RequestId = wrapper.requestWithdrawal(
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

        console.log("--- finalize ---");
        console.log("emergencyExitActivated", withdrawalQueue.isEmergencyExitActivated());
        assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), false);

        vm.expectRevert();
        withdrawalQueue.finalize(1);

        assertEq(address(withdrawalQueue).balance, 0);

        vm.warp(block.timestamp + 61 days);
        assertEq(withdrawalQueue.isEmergencyExitActivated(), false);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

        vm.prank(user1);
        withdrawalQueue.activateEmergencyExit();

        assertEq(withdrawalQueue.isEmergencyExitActivated(), true);
        assertEq(withdrawalQueue.isWithdrawalQueueStuck(), true);

        uint256 user1BalanceBefore = user1.balance;

        vm.prank(user1);
        uint256 maxRequests = 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawalQueue.InvalidRequestIdRange.selector,
                withdrawalQueue.getLastFinalizedRequestId(),  // from
                withdrawalQueue.getLastFinalizedRequestId() + maxRequests  // to
            )
        );
        withdrawalQueue.finalize(maxRequests);

        //
        vm.prank(user1);
        uint256 finalizedRequests = withdrawalQueue.finalize(1);
        assertEq(finalizedRequests, 0);

        // set latest report timestamp to a time in the future
        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);

        vm.prank(user1);
        finalizedRequests = withdrawalQueue.finalize(1);
        assertEq(finalizedRequests, 1);

        assertEq(address(withdrawalQueue).balance, halfuser1Assets);
        assertEq(address(user1).balance, user1BalanceBefore);

        vm.prank(user1);
        wrapper.claimWithdrawal(user1RequestId, address(0));

        assertEq(address(withdrawalQueue).balance, 0);
        assertEq(address(user1).balance, user1BalanceBefore + halfuser1Assets);
    }

    // Tests withdrawal handling when vault experiences staking rewards/rebases
    // Placeholder for testing share rate changes during withdrawal process
    function test_WithdrawalWithRebase() public {}

    function test_WrapperUpgrade() public {
        MockUpgradableWq mockUpgradableWq = new MockUpgradableWq(address(wrapper));

        vm.prank(address(wrapper));
        withdrawalQueue.upgradeTo(address(mockUpgradableWq));

        assertEq(MockUpgradableWq(address(withdrawalQueue)).getImplementation(), address(mockUpgradableWq));
    }

    function test_revert_WrapperUpgrade_NotWrapper() public {
        MockUpgradableWq mockUpgradableWq = new MockUpgradableWq(address(wrapper));

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.OnlyWrapperCan.selector));
        withdrawalQueue.upgradeTo(address(mockUpgradableWq));
    }
}
