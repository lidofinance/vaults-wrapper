// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupStvPool} from "./SetupStvPool.sol";
import {BasePool} from "src/BasePool.sol";

contract UnassignedLiabilityTest is Test, SetupStvPool {
    function test_InitialState_UnassignedLiabilityIsZero() public view {
        assertEq(pool.totalUnassignedLiabilityShares(), 0);
    }

    // unassigned liability (UL) tests

    function test_IncreaseWithVaultLiability_UpdatesShares() public {
        uint256 liabilityToTransfer = 100;
        dashboard.mock_increaseLiability(liabilityToTransfer);
        assertEq(pool.totalUnassignedLiabilityShares(), liabilityToTransfer);
    }

    // unavailable user operations tests

    function test_RevertOnDeposits() public {
        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        vm.expectRevert(BasePool.UnassignedLiabilityOnVault.selector);
        pool.depositETH{value: 1 ether}(userAlice, address(0));
    }

    function test_RevertOnTransfers() public {
        vm.prank(userAlice);
        pool.depositETH{value: 1 ether}(userAlice, address(0));

        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        vm.expectRevert(BasePool.UnassignedLiabilityOnVault.selector);
        pool.transfer(userBob, 1);
    }

    // unavailable node operator operations tests

    function test_TODO_RevertsOnWithdrawalsFinalization() public {
        // TODO: implement blocking finalization of withdrawals
    }

    // available user operations tests

    function test_DoNotRevertOnApprove() public {
        vm.prank(userAlice);
        pool.depositETH{value: 1 ether}(userAlice, address(0));

        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        pool.approve(userBob, 1);
        assertEq(pool.allowance(userAlice, userBob), 1);
    }
}
