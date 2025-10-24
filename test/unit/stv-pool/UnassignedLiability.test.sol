// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupStvPool} from "./SetupStvPool.sol";
import {BasePool} from "src/BasePool.sol";

contract UnassignedLiabilityTest is Test, SetupStvPool {
    function test_InitialState_UnassignedLiabilityIsZero() public view {
        assertEq(pool.totalUnassignedLiabilityShares(), 0);
    }

    // unassigned liability tests

    function test_TotalUnassignedLiabilityShares() public {
        uint256 liabilityShares = 100;
        dashboard.mock_increaseLiability(liabilityShares);
        assertEq(pool.totalUnassignedLiabilityShares(), liabilityShares);
    }

    function test_TotalUnassignedLiabilitySteth() public {
        uint256 liabilityShares = 1000;
        uint256 stethRoundedUp = steth.getPooledEthBySharesRoundUp(liabilityShares);
        dashboard.mock_increaseLiability(liabilityShares);
        assertEq(pool.totalUnassignedLiabilitySteth(), stethRoundedUp);
    }

    function test_UnassignedLiabilityDecreasesTotalAssets() public {
        uint256 totalAssetsBefore = pool.totalAssets();
        uint256 liabilityShares = 1000;
        uint256 stethRoundedUp = steth.getPooledEthBySharesRoundUp(liabilityShares);
        dashboard.mock_increaseLiability(liabilityShares);

        assertEq(pool.totalAssets(), totalAssetsBefore - stethRoundedUp);
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
