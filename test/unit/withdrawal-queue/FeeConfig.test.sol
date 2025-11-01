// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract FeeConfigTest is Test, SetupWithdrawalQueue {
    // Default value

    function test_GetWithdrawalFee_DefaultZero() public view {
        assertEq(withdrawalQueue.getWithdrawalFee(), 0);
    }

    // Setter

    function test_SetWithdrawalFee_UpdatesValue() public {
        uint256 fee = 0.0001 ether;

        vm.prank(finalizeRoleHolder);
        withdrawalQueue.setWithdrawalFee(fee);
        assertEq(withdrawalQueue.getWithdrawalFee(), fee);
    }

    function test_SetWithdrawalFee_RevertAboveMax() public {
        uint256 fee = withdrawalQueue.MAX_WITHDRAWAL_FEE() + 1;

        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.WithdrawalFeeTooLarge.selector, fee));
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.setWithdrawalFee(fee);
    }

    function test_SetWithdrawalFee_MaxValueCanBeSet() public {
        uint256 fee = withdrawalQueue.MAX_WITHDRAWAL_FEE();

        vm.prank(finalizeRoleHolder);
        withdrawalQueue.setWithdrawalFee(fee);
        assertEq(withdrawalQueue.getWithdrawalFee(), fee);
    }

    // Access control

    function test_SetWithdrawalFee_CanBeCalledByFinalizeRole() public {
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.setWithdrawalFee(0.0001 ether);
    }

    function test_SetWithdrawalFee_CantBeCalledStranger() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), withdrawalQueue.FINALIZE_ROLE()
            )
        );
        withdrawalQueue.setWithdrawalFee(0.0001 ether);
    }
}
