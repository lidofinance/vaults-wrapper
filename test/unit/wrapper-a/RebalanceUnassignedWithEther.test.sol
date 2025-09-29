// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {SetupWrapperA} from "./SetupWrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";

contract RebalanceUnassignedWithEtherTest is Test, SetupWrapperA {
    function test_DecreasesUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        uint256 ethToRebalance = 15;

        dashboard.mock_increaseLiability(liabilityToTransfer);
        wrapper.rebalanceUnassignedLiabilityWithEther{value: ethToRebalance}();

        uint256 expectedLiabilityDecrease = steth.getSharesByPooledEth(ethToRebalance);
        assertEq(wrapper.totalUnassignedLiabilityShares(), liabilityToTransfer - expectedLiabilityDecrease);
    }

    function test_DoesNotDecreaseTotalValue() public {
        uint256 totalAssetsBefore = wrapper.totalAssets();

        dashboard.mock_increaseLiability(100);
        wrapper.rebalanceUnassignedLiabilityWithEther{value: 50}();

        assertEq(wrapper.totalAssets(), totalAssetsBefore);
    }

    function test_RevertIfMoreThanUnassignedLiability() public {
        uint256 liabilityToTransfer = 100;
        dashboard.mock_increaseLiability(liabilityToTransfer);

        uint256 liabilityInEth = steth.getPooledEthBySharesRoundUp(liabilityToTransfer);

        vm.expectRevert(WrapperBase.NotEnoughToRebalance.selector);
        // 2 wei extra to account for rounding errors
        wrapper.rebalanceUnassignedLiabilityWithEther{value: liabilityInEth + 2}();
    }

    function test_RevertIfZeroShares() public {
        dashboard.mock_increaseLiability(100);

        vm.expectRevert(WrapperBase.NotEnoughToRebalance.selector);
        wrapper.rebalanceUnassignedLiabilityWithEther{value: 0}();
    }
}
