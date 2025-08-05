// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Wrapper} from "src/Wrapper.sol";
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

contract WhitelistTest is Test {
    Wrapper public wrapperWithWhitelist;
    Wrapper public wrapperWithoutWhitelist;
    WithdrawalQueue public withdrawalQueue;

    MockDashboard public dashboard;
    MockVaultHub public vaultHub;
    MockStakingVault public stakingVault;

    address public owner;
    address public user1;
    address public user2;
    address public user3;
    address public nonWhitelistedUser;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        nonWhitelistedUser = makeAddr("nonWhitelistedUser");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);
        vm.deal(nonWhitelistedUser, 10 ether);

        // Deploy mocks
        stakingVault = new MockStakingVault();
        vaultHub = new MockVaultHub();
        dashboard = new MockDashboard(address(vaultHub), address(stakingVault));

        // Fund the staking vault to simulate initial state
        vm.deal(address(stakingVault), 1 ether);

        // Create wrapper with whitelist enabled
        wrapperWithWhitelist = new Wrapper(
            address(dashboard),
            owner,
            "Whitelisted Staked ETH Vault",
            "wstvETH",
            true, // whitelist enabled
            false, // minting disabled
            address(0) // no strategy
        );

        // Create wrapper without whitelist
        wrapperWithoutWhitelist = new Wrapper(
            address(dashboard),
            owner,
            "Open Staked ETH Vault",
            "ostvETH",
            false, // whitelist disabled
            false, // minting disabled
            address(0) // no strategy
        );

        // Setup withdrawal queue for whitelist wrapper
        vm.startPrank(owner);
        withdrawalQueue = new WithdrawalQueue(wrapperWithWhitelist);
        withdrawalQueue.initialize(owner);
        wrapperWithWhitelist.setWithdrawalQueue(address(withdrawalQueue));
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), owner);
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), owner);
        withdrawalQueue.resume();
        vm.stopPrank();

        // Grant FUND_ROLE to wrappers
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperWithWhitelist));
        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapperWithoutWhitelist));
    }

    // =================================================================================
    // WHITELIST MANAGEMENT TESTS
    // =================================================================================

    // Tests that whitelist feature can be enabled/disabled during wrapper deployment
    // Verifies the whitelistEnabled flag is properly set for different wrapper instances
    function test_whitelistEnabled() public view {
        assertEq(wrapperWithWhitelist.WHITELIST_ENABLED(), true, "Whitelist should be enabled");
        assertEq(wrapperWithoutWhitelist.WHITELIST_ENABLED(), false, "Whitelist should be disabled");
    }

    // Tests that newly deployed wrapper with whitelist enabled starts with empty whitelist
    // Verifies initial state has zero whitelisted addresses
    function test_initialWhitelistIsEmpty() public view {
        assertEq(wrapperWithWhitelist.getWhitelistSize(), 0, "Initial whitelist should be empty");
        assertFalse(wrapperWithWhitelist.isWhitelisted(user1), "User1 should not be whitelisted initially");
    }

    // Tests adding a single address to the whitelist
    // Verifies address becomes whitelisted and appears in whitelist array
    function test_addToWhitelist() public {
        vm.startPrank(owner);

        wrapperWithWhitelist.addToWhitelist(user1);

        assertTrue(wrapperWithWhitelist.isWhitelisted(user1), "User1 should be whitelisted");
        assertEq(wrapperWithWhitelist.getWhitelistSize(), 1, "Whitelist size should be 1");

        address[] memory whitelistAddresses = wrapperWithWhitelist.getWhitelistAddresses();
        assertEq(whitelistAddresses.length, 1, "Whitelist addresses length should be 1");
        assertEq(whitelistAddresses[0], user1, "First address should be user1");

        vm.stopPrank();
    }

    // Tests adding multiple addresses to the whitelist
    // Verifies all addresses are properly whitelisted and whitelist size increases correctly
    function test_addMultipleToWhitelist() public {
        vm.startPrank(owner);

        wrapperWithWhitelist.addToWhitelist(user1);
        wrapperWithWhitelist.addToWhitelist(user2);
        wrapperWithWhitelist.addToWhitelist(user3);

        assertTrue(wrapperWithWhitelist.isWhitelisted(user1), "User1 should be whitelisted");
        assertTrue(wrapperWithWhitelist.isWhitelisted(user2), "User2 should be whitelisted");
        assertTrue(wrapperWithWhitelist.isWhitelisted(user3), "User3 should be whitelisted");
        assertEq(wrapperWithWhitelist.getWhitelistSize(), 3, "Whitelist size should be 3");

        vm.stopPrank();
    }

    // Tests removing an address from the whitelist while preserving order
    // Verifies removed address is no longer whitelisted and array is properly maintained
    function test_removeFromWhitelist() public {
        vm.startPrank(owner);

        // Add users
        wrapperWithWhitelist.addToWhitelist(user1);
        wrapperWithWhitelist.addToWhitelist(user2);
        wrapperWithWhitelist.addToWhitelist(user3);

        // Remove user2
        wrapperWithWhitelist.removeFromWhitelist(user2);

        assertTrue(wrapperWithWhitelist.isWhitelisted(user1), "User1 should still be whitelisted");
        assertFalse(wrapperWithWhitelist.isWhitelisted(user2), "User2 should not be whitelisted");
        assertTrue(wrapperWithWhitelist.isWhitelisted(user3), "User3 should still be whitelisted");
        assertEq(wrapperWithWhitelist.getWhitelistSize(), 2, "Whitelist size should be 2");

        // Check order is maintained (user3 takes user2's place)
        address[] memory whitelistAddresses = wrapperWithWhitelist.getWhitelistAddresses();
        assertEq(whitelistAddresses[0], user1, "First address should be user1");
        assertEq(whitelistAddresses[1], user3, "Second address should be user3");

        vm.stopPrank();
    }

    // Tests that attempting to add an already whitelisted address reverts
    // Verifies AlreadyWhitelisted error is thrown for duplicate additions
    function test_cannotAddDuplicateToWhitelist() public {
        vm.startPrank(owner);

        wrapperWithWhitelist.addToWhitelist(user1);

        vm.expectRevert(abi.encodeWithSelector(AlreadyWhitelisted.selector, user1));
        wrapperWithWhitelist.addToWhitelist(user1);

        vm.stopPrank();
    }

    // Tests that attempting to remove a non-whitelisted address reverts
    // Verifies NotInWhitelist error is thrown when removing non-existent addresses
    function test_cannotRemoveNonWhitelistedAddress() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(NotInWhitelist.selector, user1));
        wrapperWithWhitelist.removeFromWhitelist(user1);

        vm.stopPrank();
    }

    // Tests that only the wrapper owner can add/remove addresses from whitelist
    // Verifies non-owner calls to whitelist management functions revert
    function test_onlyOwnerCanManageWhitelist() public {
        vm.startPrank(user1);

        vm.expectRevert();
        wrapperWithWhitelist.addToWhitelist(user2);

        vm.expectRevert();
        wrapperWithWhitelist.removeFromWhitelist(user2);

        vm.stopPrank();
    }

    // Tests that whitelist enforces maximum size limit
    // Verifies WhitelistFull error when attempting to exceed MAX_WHITELIST_SIZE
    function test_whitelistSizeLimit() public {
        vm.startPrank(owner);

        uint256 maxSize = wrapperWithWhitelist.MAX_WHITELIST_SIZE();

        // Add maximum number of addresses
        for (uint256 i = 0; i < maxSize; i++) {
            address userAddr = address(uint160(i + 1));
            wrapperWithWhitelist.addToWhitelist(userAddr);
        }

        assertEq(wrapperWithWhitelist.getWhitelistSize(), maxSize, "Whitelist should be at max size");

        // Try to add one more
        address extraUser = address(uint160(maxSize + 1));
        vm.expectRevert(WhitelistFull.selector);
        wrapperWithWhitelist.addToWhitelist(extraUser);

        vm.stopPrank();
    }

    // =================================================================================
    // DEPOSIT RESTRICTION TESTS
    // =================================================================================

    // Tests that whitelisted users can successfully deposit ETH into the wrapper
    // Verifies whitelisted addresses can call depositETH and receive shares
    function test_whitelistedUserCanDeposit() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;
        uint256 sharesBefore = wrapperWithWhitelist.balanceOf(user1);

        uint256 shares = wrapperWithWhitelist.depositETH{value: depositAmount}(user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithWhitelist.balanceOf(user1), sharesBefore + shares, "User1 balance should increase");

        vm.stopPrank();
    }

    // Tests that non-whitelisted users cannot deposit when whitelist is enabled
    // Verifies NotWhitelisted error is thrown for unauthorized deposit attempts
    function test_nonWhitelistedUserCannotDeposit() public {
        vm.startPrank(nonWhitelistedUser);
        uint256 depositAmount = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, nonWhitelistedUser));
        wrapperWithWhitelist.depositETH{value: depositAmount}(nonWhitelistedUser);

        vm.stopPrank();
    }

    // Tests that deposits work normally when whitelist feature is disabled
    // Verifies any address can deposit when wrapper is created without whitelist
    function test_depositWorksWithoutWhitelist() public {
        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        uint256 shares = wrapperWithoutWhitelist.depositETH{value: depositAmount}(user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithoutWhitelist.balanceOf(user1), shares, "User1 should have shares");

        vm.stopPrank();
    }

    // Tests that users removed from whitelist cannot make new deposits
    // Verifies existing shares are preserved but new deposits are blocked
    function test_removedUserCannotDeposit() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        // User1 deposits while whitelisted
        vm.startPrank(user1);
        uint256 firstDeposit = 1 ether;
        uint256 shares = wrapperWithWhitelist.depositETH{value: firstDeposit}(user1);
        assertGt(shares, 0, "Should receive shares from first deposit");
        vm.stopPrank();

        // Remove user1 from whitelist
        vm.startPrank(owner);
        wrapperWithWhitelist.removeFromWhitelist(user1);
        vm.stopPrank();

        // User1 tries to deposit again
        vm.startPrank(user1);
        uint256 secondDeposit = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(NotWhitelisted.selector, user1));
        wrapperWithWhitelist.depositETH{value: secondDeposit}(user1);

        // But user1 still has their shares
        assertEq(wrapperWithWhitelist.balanceOf(user1), shares, "User1 should still have shares from first deposit");

        vm.stopPrank();
    }

    // Tests the convenience depositETH function without receiver parameter
    // Verifies deposits work when receiver defaults to msg.sender
    function test_depositETHConvenienceFunction() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        // Test convenience function (no receiver parameter)
        uint256 shares = wrapperWithWhitelist.depositETH{value: depositAmount}();

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithWhitelist.balanceOf(user1), shares, "User1 should have shares");

        vm.stopPrank();
    }

    // Tests depositing ETH with shares sent to a different receiver address
    // Verifies depositor can send shares to another address during deposit
    function test_depositETHWithDifferentReceiver() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        vm.startPrank(user1);
        uint256 depositAmount = 1 ether;

        // Deposit but send shares to user2
        uint256 shares = wrapperWithWhitelist.depositETH{value: depositAmount}(user2);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapperWithWhitelist.balanceOf(user1), 0, "User1 should have no shares");
        assertEq(wrapperWithWhitelist.balanceOf(user2), shares, "User2 should have shares");

        vm.stopPrank();
    }

    // =================================================================================
    // EDGE CASES AND COMPLEX SCENARIOS
    // =================================================================================

    // Tests that proper events are emitted when managing whitelist
    // Verifies WhitelistAdded and WhitelistRemoved events are emitted correctly
    function test_whitelistEventsEmitted() public {
        vm.startPrank(owner);

        // Test add event
        vm.expectEmit(true, false, false, false);
        emit WhitelistAdded(user1);
        wrapperWithWhitelist.addToWhitelist(user1);

        // Test remove event
        vm.expectEmit(true, false, false, false);
        emit WhitelistRemoved(user1);
        wrapperWithWhitelist.removeFromWhitelist(user1);

        vm.stopPrank();
    }

    // Tests that users can transfer shares even after being removed from whitelist
    // Verifies whitelist only affects deposits, not share transfers
    function test_canTransferSharesAfterRemovalFromWhitelist() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        // User1 deposits
        vm.startPrank(user1);
        uint256 shares = wrapperWithWhitelist.depositETH{value: 1 ether}(user1);
        vm.stopPrank();

        // Remove from whitelist
        vm.startPrank(owner);
        wrapperWithWhitelist.removeFromWhitelist(user1);
        vm.stopPrank();

        // User1 can still transfer shares
        vm.startPrank(user1);
        wrapperWithWhitelist.transfer(user2, shares / 2);

        assertEq(wrapperWithWhitelist.balanceOf(user1), shares / 2, "User1 should have half shares");
        assertEq(wrapperWithWhitelist.balanceOf(user2), shares / 2, "User2 should have half shares");

        vm.stopPrank();
    }

    // Tests that whitelist restrictions do not apply to withdrawal operations
    // Verifies removed users can still request withdrawals of their existing shares
    function test_whitelistDoesNotAffectWithdrawals() public {
        vm.startPrank(owner);
        wrapperWithWhitelist.addToWhitelist(user1);
        vm.stopPrank();

        // User1 deposits while whitelisted
        vm.startPrank(user1);
        uint256 shares = wrapperWithWhitelist.depositETH{value: 2 ether}(user1);
        vm.stopPrank();

        // Remove from whitelist
        vm.startPrank(owner);
        wrapperWithWhitelist.removeFromWhitelist(user1);
        vm.stopPrank();

        // User1 can still request withdrawal
        vm.startPrank(user1);
        wrapperWithWhitelist.approve(address(withdrawalQueue), shares);

        uint256 requestId = withdrawalQueue.requestWithdrawal(user1, shares);
        assertGt(requestId, 0, "Should have a valid withdrawal request ID");

        vm.stopPrank();
    }

    // Fuzz test for whitelist operations with random addresses and operations
    // Verifies whitelist management works correctly with various address combinations
    function testFuzz_whitelistOperations(address[5] memory users, uint256 seed) public {
        vm.startPrank(owner);

        // Add some users to whitelist
        uint256 usersToAdd = seed % 5 + 1;
        for (uint256 i = 0; i < usersToAdd; i++) {
            if (users[i] != address(0) && !wrapperWithWhitelist.isWhitelisted(users[i])) {
                wrapperWithWhitelist.addToWhitelist(users[i]);
                assertTrue(wrapperWithWhitelist.isWhitelisted(users[i]), "User should be whitelisted");
            }
        }

        // Remove some users
        uint256 currentSize = wrapperWithWhitelist.getWhitelistSize();
        if (currentSize > 0) {
            address[] memory whitelistedUsers = wrapperWithWhitelist.getWhitelistAddresses();
            uint256 indexToRemove = seed % currentSize;
            address userToRemove = whitelistedUsers[indexToRemove];

            wrapperWithWhitelist.removeFromWhitelist(userToRemove);
            assertFalse(wrapperWithWhitelist.isWhitelisted(userToRemove), "User should not be whitelisted");
        }

        vm.stopPrank();
    }

    // Events for testing
    event WhitelistAdded(address indexed user);
    event WhitelistRemoved(address indexed user);
}

// Import errors from Wrapper
error NotWhitelisted(address user);
error WhitelistFull();
error AlreadyWhitelisted(address user);
error NotInWhitelist(address user);