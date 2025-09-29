// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperA} from "./SetupWrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";

contract UnassignedLiabilityTest is Test, SetupWrapperA {
    function test_InitialState_UnassignedLiabilityIsZero() public view {
        assertEq(wrapper.totalUnassignedLiabilityShares(), 0);
    }

    // unassigned liability (UL) tests

    function test_IncreaseWithVaultLiability_UpdatesShares() public {
        uint256 liabilityToTransfer = 100;
        dashboard.mock_increaseLiability(liabilityToTransfer);
        assertEq(wrapper.totalUnassignedLiabilityShares(), liabilityToTransfer);
    }

    // unavailable user operations tests

    function test_RevertOnDeposits() public {
        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        vm.expectRevert(WrapperBase.UnassignedLiabilityOnVault.selector);
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));
    }

    function test_RevertOnTransfers() public {
        vm.prank(userAlice);
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));

        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        vm.expectRevert(WrapperBase.UnassignedLiabilityOnVault.selector);
        wrapper.transfer(userBob, 1);
    }

    // unavailable node operator operations tests

    function test_TODO_RevertsOnWithdrawalsFinalization() public {
        // TODO: implement blocking finalization of withdrawals
    }

    // available user operations tests

    function test_DoNotRevertOnApprove() public {
        vm.prank(userAlice);
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));

        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        wrapper.approve(userBob, 1);
        assertEq(wrapper.allowance(userAlice, userBob), 1);
    }
}
