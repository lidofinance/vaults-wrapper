// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SetupAllowList} from "./SetupAllowList.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {AllowList} from "src/AllowList.sol";

contract AllowListManagementTest is Test, SetupAllowList {
    function test_WithAllowList_UserIsAllowListed() public view {
        assertTrue(poolWithAllowList.isAllowListed(userAllowListed));
    }

    function test_WithAllowList_UserIsNotAllowListed() public view {
        assertFalse(poolWithAllowList.isAllowListed(userNotAllowListed));
    }

    function test_WithoutAllowList_NotAllowListed() public view {
        assertFalse(poolWithoutAllowList.isAllowListed(userAny));
    }

    // Owner list management

    function test_AllowListManagement_AddToListByOwner() public {
        vm.prank(owner);
        poolWithAllowList.addToAllowList(userNotAllowListed);
    }

    function test_AllowListManagement_RemoveFromListByOwner() public {
        vm.prank(owner);
        poolWithAllowList.removeFromAllowList(userAllowListed);
    }

    // Unauthorized list management

    function test_AllowListManagement_AddToListByNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAny,
                poolWithAllowList.ALLOW_LIST_MANAGER_ROLE()
            )
        );
        vm.prank(userAny);
        poolWithAllowList.addToAllowList(userNotAllowListed);
    }

    function test_AllowListManagement_RemoveFromListByNonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAny,
                poolWithAllowList.ALLOW_LIST_MANAGER_ROLE()
            )
        );
        vm.prank(userAny);
        poolWithAllowList.removeFromAllowList(userAllowListed);
    }

    // Events

    function test_AllowListManagement_AddToList_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListAdded(userNotAllowListed);

        vm.prank(owner);
        poolWithAllowList.addToAllowList(userNotAllowListed);
    }

    function test_AllowListManagement_RemoveFromList_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListRemoved(userAllowListed);

        vm.prank(owner);
        poolWithAllowList.removeFromAllowList(userAllowListed);
    }

    // Batch operations - ensureAllowListed

    function test_EnsureAllowListed_AddMultipleUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);

        assertTrue(poolWithAllowList.isAllowListed(user1));
        assertTrue(poolWithAllowList.isAllowListed(user2));
        assertTrue(poolWithAllowList.isAllowListed(user3));
    }

    function test_EnsureAllowListed_IdempotentWithAlreadyAllowListed() public {
        address[] memory users = new address[](1);
        users[0] = userAllowListed;

        // Should not revert even though user is already allowlisted
        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);

        assertTrue(poolWithAllowList.isAllowListed(userAllowListed));
    }

    function test_EnsureAllowListed_MixedState() public {
        address newUser = makeAddr("newUser");
        address[] memory users = new address[](2);
        users[0] = userAllowListed; // Already allowlisted
        users[1] = newUser; // Not allowlisted

        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);

        assertTrue(poolWithAllowList.isAllowListed(userAllowListed));
        assertTrue(poolWithAllowList.isAllowListed(newUser));
    }

    function test_EnsureAllowListed_EmitsEventOnlyForNewUsers() public {
        address newUser = makeAddr("newUser");
        address[] memory users = new address[](2);
        users[0] = userAllowListed; // Already allowlisted - no event expected
        users[1] = newUser; // Not allowlisted - event expected

        // Only expect event for newUser, not for userAllowListed
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListAdded(newUser);

        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);
    }

    function test_EnsureAllowListed_EmptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);
    }

    function test_EnsureAllowListed_UnauthorizedUser() public {
        address[] memory users = new address[](1);
        users[0] = userNotAllowListed;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAny,
                poolWithAllowList.ALLOW_LIST_MANAGER_ROLE()
            )
        );
        vm.prank(userAny);
        poolWithAllowList.ensureAllowListed(users);
    }

    function test_EnsureAllowListed_DuplicateAddresses() public {
        address newUser = makeAddr("newUser");
        address[] memory users = new address[](3);
        users[0] = newUser;
        users[1] = newUser; // Duplicate
        users[2] = newUser; // Duplicate

        // Should only emit one event (first occurrence adds, rest skip)
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListAdded(newUser);

        vm.prank(owner);
        poolWithAllowList.ensureAllowListed(users);

        // Verify user was added
        assertTrue(poolWithAllowList.isAllowListed(newUser));
    }

    // Batch operations - ensureNotAllowListed

    function test_EnsureNotAllowListed_RemoveMultipleUsers() public {
        // First add some users
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        vm.startPrank(owner);
        poolWithAllowList.addToAllowList(user1);
        poolWithAllowList.addToAllowList(user2);
        poolWithAllowList.addToAllowList(user3);
        vm.stopPrank();

        // Now remove them all in batch
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);

        assertFalse(poolWithAllowList.isAllowListed(user1));
        assertFalse(poolWithAllowList.isAllowListed(user2));
        assertFalse(poolWithAllowList.isAllowListed(user3));
    }

    function test_EnsureNotAllowListed_IdempotentWithNotAllowListed() public {
        address[] memory users = new address[](1);
        users[0] = userNotAllowListed;

        // Should not revert even though user is not in allowlist
        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);

        assertFalse(poolWithAllowList.isAllowListed(userNotAllowListed));
    }

    function test_EnsureNotAllowListed_MixedState() public {
        address[] memory users = new address[](2);
        users[0] = userAllowListed; // Is allowlisted
        users[1] = userNotAllowListed; // Not allowlisted

        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);

        assertFalse(poolWithAllowList.isAllowListed(userAllowListed));
        assertFalse(poolWithAllowList.isAllowListed(userNotAllowListed));
    }

    function test_EnsureNotAllowListed_EmitsEventOnlyForRemovedUsers() public {
        address[] memory users = new address[](2);
        users[0] = userAllowListed; // Is allowlisted - event expected
        users[1] = userNotAllowListed; // Not allowlisted - no event expected

        // Only expect event for userAllowListed, not for userNotAllowListed
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListRemoved(userAllowListed);

        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);
    }

    function test_EnsureNotAllowListed_EmptyArray() public {
        address[] memory users = new address[](0);

        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);
    }

    function test_EnsureNotAllowListed_UnauthorizedUser() public {
        address[] memory users = new address[](1);
        users[0] = userAllowListed;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                userAny,
                poolWithAllowList.ALLOW_LIST_MANAGER_ROLE()
            )
        );
        vm.prank(userAny);
        poolWithAllowList.ensureNotAllowListed(users);
    }

    function test_EnsureNotAllowListed_DuplicateAddresses() public {
        address[] memory users = new address[](3);
        users[0] = userAllowListed;
        users[1] = userAllowListed; // Duplicate
        users[2] = userAllowListed; // Duplicate

        // Should only emit one event (first occurrence removes, rest skip)
        vm.expectEmit(true, false, false, false);
        emit AllowList.AllowListRemoved(userAllowListed);

        vm.prank(owner);
        poolWithAllowList.ensureNotAllowListed(users);

        // Verify user was removed
        assertFalse(poolWithAllowList.isAllowListed(userAllowListed));
    }
}
