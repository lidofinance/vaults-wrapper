// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperA} from "./SetupWrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";

contract RebalanceUnassignedWithSharesTest is Test, SetupWrapperA {
    function test_DecreasesUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        uint256 liabilityToRebalance = 15;

        dashboard.mock_increaseLiability(liabilityToTransfer);
        wrapper.rebalanceUnassignedLiability(liabilityToRebalance);

        assertEq(wrapper.totalUnassignedLiabilityShares(), liabilityToTransfer - liabilityToRebalance);
    }

    function test_DecreasesTotalValue() public {
        uint256 liabilityToTransfer = 100;
        uint256 totalAssetsBefore = wrapper.totalAssets();

        dashboard.mock_increaseLiability(liabilityToTransfer);
        wrapper.rebalanceUnassignedLiability(liabilityToTransfer);

        uint256 expectedEthToWithdraw = steth.getPooledEthBySharesRoundUp(liabilityToTransfer);
        assertEq(wrapper.totalAssets(), totalAssetsBefore - expectedEthToWithdraw);
    }

    function test_RevertIfMoreThanUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        dashboard.mock_increaseLiability(liabilityToTransfer);

        vm.expectRevert(WrapperBase.NotEnoughToRebalance.selector);
        wrapper.rebalanceUnassignedLiability(liabilityToTransfer + 1);
    }

    function test_RevertIfZeroShares() public {
        dashboard.mock_increaseLiability(100);

        vm.expectRevert(WrapperBase.NotEnoughToRebalance.selector);
        wrapper.rebalanceUnassignedLiability(0);
    }
}
