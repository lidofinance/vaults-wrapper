// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperA} from "./SetupWrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";

contract UnassignedLiabilityTest is Test, SetupWrapperA {
    function test_InitialState_UnassignedLiabilityIsZero() public view {
        assertEq(wrapper.totalUnassignedLiabilityShares(), 0);
    }

    // unassigned liability tests

    function test_TotalUnassignedLiabilityShares() public {
        uint256 liabilityShares = 100;
        dashboard.mock_increaseLiability(liabilityShares);
        assertEq(wrapper.totalUnassignedLiabilityShares(), liabilityShares);
    }

    function test_TotalUnassignedLiabilitySteth() public {
        uint256 liabilityShares = 1000;
        uint256 stethRoundedUp = steth.getPooledEthBySharesRoundUp(liabilityShares);
        dashboard.mock_increaseLiability(liabilityShares);
        assertEq(wrapper.totalUnassignedLiabilitySteth(), stethRoundedUp);
    }

    function test_UnassignedLiabilityDecreasesTotalAssets() public {
        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 liabilityShares = 1000;
        uint256 stethRoundedUp = steth.getPooledEthBySharesRoundUp(liabilityShares);
        dashboard.mock_increaseLiability(liabilityShares);

        assertEq(wrapper.totalAssets(), totalAssetsBefore - stethRoundedUp);
    }

    // unavailable user operations tests

    function test_DoesNotRevertOnDeposits() public {
        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));
    }

    function test_DoesNotRevertOnTransfers() public {
        vm.prank(userAlice);
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));

        dashboard.mock_increaseLiability(100);

        vm.prank(userAlice);
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
