// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupStvPool} from "./SetupStvPool.sol";
import {BasePool} from "src/BasePool.sol";

contract RebalanceUnassignedWithSharesTest is Test, SetupStvPool {
    function test_DecreasesUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        uint256 liabilityToRebalance = 15;

        dashboard.mock_increaseLiability(liabilityToTransfer);
        pool.rebalanceUnassignedLiability(liabilityToRebalance);

        assertEq(pool.totalUnassignedLiabilityShares(), liabilityToTransfer - liabilityToRebalance);
    }

    function test_DecreasesTotalValue() public {
        uint256 liabilityToTransfer = 100;
        uint256 totalAssetsBefore = pool.totalAssets();

        dashboard.mock_increaseLiability(liabilityToTransfer);
        pool.rebalanceUnassignedLiability(liabilityToTransfer);

        uint256 expectedEthToWithdraw = steth.getPooledEthBySharesRoundUp(liabilityToTransfer);
        assertEq(pool.totalAssets(), totalAssetsBefore - expectedEthToWithdraw);
    }

    function test_RevertIfMoreThanUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        dashboard.mock_increaseLiability(liabilityToTransfer);

        vm.expectRevert(BasePool.NotEnoughToRebalance.selector);
        pool.rebalanceUnassignedLiability(liabilityToTransfer + 1);
    }

    function test_RevertIfZeroShares() public {
        dashboard.mock_increaseLiability(100);

        vm.expectRevert(BasePool.NotEnoughToRebalance.selector);
        pool.rebalanceUnassignedLiability(0);
    }
}
