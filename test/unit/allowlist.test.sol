// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {WrapperA} from "src/WrapperA.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock contracts for simple testing
contract MockDashboard {
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");

    address public immutable VAULT_HUB;
    address public immutable stakingVault;

    constructor(address _vaultHub, address _stakingVault) {
        VAULT_HUB = _vaultHub;
        stakingVault = _stakingVault;
    }

    function fund() external payable {
        payable(stakingVault).transfer(msg.value);
    }

    function grantRole(bytes32, address) external {}
}

contract MockVaultHub {
    mapping(address => uint256) public totalValues;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;

    function totalValue(address vault) external view returns (uint256) {
        uint256 value = totalValues[vault];
        return value > 0 ? value : vault.balance;
    }

    function setTotalValue(address vault, uint256 value) external {
        totalValues[vault] = value;
    }

    function isReportFresh(address) external pure returns (bool, bool) {
        return (true, false); // (isFresh, canRequestExit)
    }
}

contract MockStakingVault {
    receive() external payable {}
}

contract AllowListTest is Test {
    WrapperA public wrapperWithAllowList;
    WrapperA public wrapperWithoutAllowList;
    WithdrawalQueue public withdrawalQueue;

    MockDashboard public dashboard;
    MockVaultHub public vaultHub;
    MockStakingVault public stakingVault;

    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public nonAllowListedUser;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        nonAllowListedUser = makeAddr("nonAllowListedUser");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);
        vm.deal(nonAllowListedUser, 10 ether);

        // Deploy mocks
        stakingVault = new MockStakingVault();
        vaultHub = new MockVaultHub();
        dashboard = new MockDashboard(address(vaultHub), address(stakingVault));

        // Fund the staking vault to simulate initial state
        vm.deal(address(stakingVault), 1 ether);

        // Create wrapper with allowlist enabled
        wrapperWithAllowList = new WrapperA(
            address(dashboard),
            owner,
            "AllowListed Staked ETH Vault",
            "wstvETH",
            true // allowlist enabled
        );

        // Create wrapper without allowlist
        wrapperWithoutAllowList = new WrapperA(
            address(dashboard),
            owner,
            "Open Staked ETH Vault",
            "ostvETH",
            false // allowlist disabled
        );

        // Setup withdrawal queue for allowlist wrapper
        vm.startPrank(owner);
        withdrawalQueue = new WithdrawalQueue(wrapperWithAllowList);
        withdrawalQueue.initialize(owner);
        wrapperWithAllowList.setWithdrawalQueue(address(withdrawalQueue));
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), owner);
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), owner);
        withdrawalQueue.resume();
        vm.stopPrank();

        // Grant FUND_ROLE to wrappers
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperWithAllowList));
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperWithoutAllowList));
    }

    // =================================================================================
    // ALLOWLIST MANAGEMENT TESTS
    // =================================================================================

    // Tests that allowlist feature can be enabled/disabled during wrapper deployment
    // Verifies the allowlistEnabled flag is properly set for different wrapper instances
    function test_allowlistEnabled() public view {
        assertEq(wrapperWithAllowList.ALLOWLIST_ENABLED(), true, "AllowList should be enabled");
        assertEq(wrapperWithoutAllowList.ALLOWLIST_ENABLED(), false, "AllowList should be disabled");
    }

    // Tests that newly deployed wrapper with allowlist enabled starts with empty allowlist
    // Verifies initial state has zero allowlisted addresses
    function test_initialAllowListIsEmpty() public view {
        assertEq(wrapperWithAllowList.getAllowListSize(), 0, "Initial allowlist should be empty");
        assertFalse(wrapperWithAllowList.isAllowListed(user1), "User1 should not be allowlisted initially");
    }

    // Tests adding a single address to the allowlist
    // Verifies address becomes allowlisted and appears in allowlist array
    function test_addToAllowList() public {
        vm.startPrank(owner);

        wrapperWithAllowList.addToAllowList(user1);

        assertTrue(wrapperWithAllowList.isAllowListed(user1), "User1 should be allowlisted");
        assertEq(wrapperWithAllowList.getAllowListSize(), 1, "AllowList size should be 1");

        address[] memory allowlistAddresses = wrapperWithAllowList.getAllowListAddresses();
        assertEq(allowlistAddresses.length, 1, "AllowList addresses length should be 1");
        assertEq(allowlistAddresses[0], user1, "First address should be user1");

        vm.stopPrank();
    }

    // Tests adding multiple addresses to the allowlist
    // Verifies all addresses are properly allowlisted and allowlist size increases correctly
    function test_addMultipleToAllowList() public {
        vm.startPrank(owner);

        wrapperWithAllowList.addToAllowList(user1);
        wrapperWithAllowList.addToAllowList(user2);
        wrapperWithAllowList.addToAllowList(user3);

        assertTrue(wrapperWithAllowList.isAllowListed(user1), "User1 should be allowlisted");
        assertTrue(wrapperWithAllowList.isAllowListed(user2), "User2 should be allowlisted");
        assertTrue(wrapperWithAllowList.isAllowListed(user3), "User3 should be allowlisted");
        assertEq(wrapperWithAllowList.getAllowListSize(), 3, "AllowList size should be 3");

        vm.stopPrank();
    }

    // Tests removing an address from the allowlist while preserving order
    // Verifies removed address is no longer allowlisted and array is properly maintained
    function test_removeFromAllowList() public {
        vm.startPrank(owner);

        // Add users
        wrapperWithAllowList.addToAllowList(user1);
        wrapperWithAllowList.addToAllowList(user2);
        wrapperWithAllowList.addToAllowList(user3);

        // Remove user2
        wrapperWithAllowList.removeFromAllowList(user2);

        assertTrue(wrapperWithAllowList.isAllowListed(user1), "User1 should still be allowlisted");
        assertFalse(wrapperWithAllowList.isAllowListed(user2), "User2 should not be allowlisted");
        assertTrue(wrapperWithAllowList.isAllowListed(user3), "User3 should still be allowlisted");
        assertEq(wrapperWithAllowList.getAllowListSize(), 2, "AllowList size should be 2");

        // Check order is maintained (user3 takes user2's place)
        address[] memory allowlistAddresses = wrapperWithAllowList.getAllowListAddresses();
        assertEq(allowlistAddresses[0], user1, "First address should be user1");
        assertEq(allowlistAddresses[1], user3, "Second address should be user3");

        vm.stopPrank();
    }

    // Tests that attempting to add an already allowlisted address reverts
    // Verifies AlreadyAllowListed error is thrown for duplicate additions
    function test_cannotAddDuplicateToAllowList() public {
        vm.startPrank(owner);

        wrapperWithAllowList.addToAllowList(user1);

        vm.expectRevert(abi.encodeWithSelector(AlreadyAllowListed.selector, user1));
        wrapperWithAllowList.addToAllowList(user1);

        vm.stopPrank();
    }

    // Tests that attempting to remove a non-allowlisted address reverts
    // Verifies NotInAllowList error is thrown when removing non-existent addresses
    function test_cannotRemoveNonAllowListedAddress() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(NotInAllowList.selector, user1));
        wrapperWithAllowList.removeFromAllowList(user1);

        vm.stopPrank();
    }

    // Tests that only accounts with ALLOWLIST_MANAGER_ROLE can manage allowlist
    // Verifies unauthorized calls to allowlist management functions revert
    function test_onlyAllowListManagerCanManageAllowList() public {
        // User without role cannot manage allowlist
        vm.startPrank(user1);
        vm.expectRevert();
        wrapperWithAllowList.addToAllowList(user2);
        vm.expectRevert();
        wrapperWithAllowList.removeFromAllowList(user2);
        vm.stopPrank();
        
        // Owner can manage (has role by default)
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user2);
        wrapperWithAllowList.removeFromAllowList(user2);
        vm.stopPrank();
    }
    
    // Tests that ALLOWLIST_MANAGER_ROLE can be delegated to other addresses
    // Verifies role-based access control works correctly for allowlist management
    function test_allowListManagerRoleCanBeDelegated() public {
        bytes32 ALLOWLIST_MANAGER_ROLE = wrapperWithAllowList.ALLOWLIST_MANAGER_ROLE();
        
        // Grant role to user3
        vm.startPrank(owner);
        wrapperWithAllowList.grantRole(ALLOWLIST_MANAGER_ROLE, user3);
        vm.stopPrank();
        
        // User3 can now manage allowlist
        vm.startPrank(user3);
        wrapperWithAllowList.addToAllowList(user1);
        assertTrue(wrapperWithAllowList.isAllowListed(user1), "User1 should be allowlisted");
        wrapperWithAllowList.removeFromAllowList(user1);
        assertFalse(wrapperWithAllowList.isAllowListed(user1), "User1 should not be allowlisted");
        vm.stopPrank();
        
        // Revoke role from user3
        vm.startPrank(owner);
        wrapperWithAllowList.revokeRole(ALLOWLIST_MANAGER_ROLE, user3);
        vm.stopPrank();
        
        // User3 can no longer manage allowlist
        vm.startPrank(user3);
        vm.expectRevert();
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();
    }

    // =================================================================================
    // DEPOSIT RESTRICTION TESTS
    // =================================================================================

    // Tests that allowlisted users can successfully deposit ETH into the wrapper
    // Verifies allowlisted addresses can call depositETH and receive shares
    function test_allowlistedUserCanDeposit() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;
        uint256 sharesBefore = wrapperWithAllowList.balanceOf(user1);

        uint256 shares = wrapperWithAllowList.depositETH{value: depositAmount}(user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithAllowList.balanceOf(user1), sharesBefore + shares, "User1 balance should increase");

        vm.stopPrank();
    }

    // Tests that non-allowlisted users cannot deposit when allowlist is enabled
    // Verifies NotAllowListed error is thrown for unauthorized deposit attempts
    function test_nonAllowListedUserCannotDeposit() public {
        vm.startPrank(nonAllowListedUser);
        uint256 depositAmount = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(NotAllowListed.selector, nonAllowListedUser));
        wrapperWithAllowList.depositETH{value: depositAmount}(nonAllowListedUser);

        vm.stopPrank();
    }

    // Tests that deposits work normally when allowlist feature is disabled
    // Verifies any address can deposit when wrapper is created without allowlist
    function test_depositWorksWithoutAllowList() public {
        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        uint256 shares = wrapperWithoutAllowList.depositETH{value: depositAmount}(user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithoutAllowList.balanceOf(user1), shares, "User1 should have shares");

        vm.stopPrank();
    }

    // Tests that users removed from allowlist cannot make new deposits
    // Verifies existing shares are preserved but new deposits are blocked
    function test_removedUserCannotDeposit() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        // User1 deposits while allowlisted
        vm.startPrank(user1);
        uint256 firstDeposit = 1 ether;
        uint256 shares = wrapperWithAllowList.depositETH{value: firstDeposit}(user1);
        assertGt(shares, 0, "Should receive shares from first deposit");
        vm.stopPrank();

        // Remove user1 from allowlist
        vm.startPrank(owner);
        wrapperWithAllowList.removeFromAllowList(user1);
        vm.stopPrank();

        // User1 tries to deposit again
        vm.startPrank(user1);
        uint256 secondDeposit = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(NotAllowListed.selector, user1));
        wrapperWithAllowList.depositETH{value: secondDeposit}(user1);

        // But user1 still has their shares
        assertEq(wrapperWithAllowList.balanceOf(user1), shares, "User1 should still have shares from first deposit");

        vm.stopPrank();
    }

    // Tests the convenience depositETH function without receiver parameter
    // Verifies deposits work when receiver defaults to msg.sender
    function test_depositETHConvenienceFunction() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        // Test convenience function (no receiver parameter)
        uint256 shares = wrapperWithAllowList.depositETH{value: depositAmount}();

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithAllowList.balanceOf(user1), shares, "User1 should have shares");

        vm.stopPrank();
    }

    // Tests depositing ETH with shares sent to a different receiver address
    // Verifies depositor can send shares to another address during deposit
    function test_depositETHWithDifferentReceiver() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        // Deposit but send shares to user2
        uint256 shares = wrapperWithAllowList.depositETH{value: depositAmount}(user2);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithAllowList.balanceOf(user1), 0, "User1 should have no shares");
        assertEq(wrapperWithAllowList.balanceOf(user2), shares, "User2 should have shares");

        vm.stopPrank();
    }

    // =================================================================================
    // EDGE CASES AND COMPLEX SCENARIOS
    // =================================================================================

    // Tests that proper events are emitted when managing allowlist
    // Verifies AllowListAdded and AllowListRemoved events are emitted correctly
    function test_allowlistEventsEmitted() public {
        vm.startPrank(owner);

        // Test add event
        vm.expectEmit(true, false, false, false);
        emit AllowListAdded(user1);
        wrapperWithAllowList.addToAllowList(user1);

        // Test remove event
        vm.expectEmit(true, false, false, false);
        emit AllowListRemoved(user1);
        wrapperWithAllowList.removeFromAllowList(user1);

        vm.stopPrank();
    }

    // Tests that users can transfer shares even after being removed from allowlist
    // Verifies allowlist only affects deposits, not share transfers
    function test_canTransferSharesAfterRemovalFromAllowList() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        // User1 deposits
        vm.startPrank(user1);
        uint256 shares = wrapperWithAllowList.depositETH{value: 1 ether}(user1);
        vm.stopPrank();

        // Remove from allowlist
        vm.startPrank(owner);
        wrapperWithAllowList.removeFromAllowList(user1);
        vm.stopPrank();

        // User1 can still transfer shares
        vm.startPrank(user1);
        wrapperWithAllowList.transfer(user2, shares / 2);

        assertEq(wrapperWithAllowList.balanceOf(user1), shares / 2, "User1 should have half shares");
        assertEq(wrapperWithAllowList.balanceOf(user2), shares / 2, "User2 should have half shares");

        vm.stopPrank();
    }

    // Tests that allowlist restrictions do not apply to withdrawal operations
    // Verifies removed users can still request withdrawals of their existing shares
    function test_allowlistDoesNotAffectWithdrawals() public {
        vm.startPrank(owner);
        wrapperWithAllowList.addToAllowList(user1);
        vm.stopPrank();

        // User1 deposits while allowlisted
        vm.startPrank(user1);
        uint256 shares = wrapperWithAllowList.depositETH{value: 2 ether}(user1);
        vm.stopPrank();

        // Remove from allowlist
        vm.startPrank(owner);
        wrapperWithAllowList.removeFromAllowList(user1);
        vm.stopPrank();

        // User1 can still request withdrawal
        vm.startPrank(user1);
        wrapperWithAllowList.approve(address(withdrawalQueue), shares);

        uint256 requestId = withdrawalQueue.requestWithdrawal(user1, shares);
        assertGt(requestId, 0, "Should have a valid withdrawal request ID");

        vm.stopPrank();
    }

    // Fuzz test for allowlist operations with random addresses and operations
    // Verifies allowlist management works correctly with various address combinations
    function testFuzz_allowlistOperations(address[5] memory users, uint256 seed) public {
        vm.startPrank(owner);

        // Add some users to allowlist
        uint256 usersToAdd = seed % 5 + 1;
        for (uint256 i = 0; i < usersToAdd; i++) {
            if (users[i] != address(0) && !wrapperWithAllowList.isAllowListed(users[i])) {
                wrapperWithAllowList.addToAllowList(users[i]);
                assertTrue(wrapperWithAllowList.isAllowListed(users[i]), "User should be allowlisted");
            }
        }

        // Remove some users
        uint256 currentSize = wrapperWithAllowList.getAllowListSize();
        if (currentSize > 0) {
            address[] memory allowlistedUsers = wrapperWithAllowList.getAllowListAddresses();
            uint256 indexToRemove = seed % currentSize;
            address userToRemove = allowlistedUsers[indexToRemove];

            wrapperWithAllowList.removeFromAllowList(userToRemove);
            assertFalse(wrapperWithAllowList.isAllowListed(userToRemove), "User should not be allowlisted");
        }

        vm.stopPrank();
    }

    // Events for testing
    event AllowListAdded(address indexed user);
    event AllowListRemoved(address indexed user);
}

// Import errors from Wrapper
error NotAllowListed(address user);
error AlreadyAllowListed(address user);
error NotInAllowList(address user);