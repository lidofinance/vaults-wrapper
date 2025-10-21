// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract ViewsTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();
    }

    function test_CalculateCurrentStvRate_InitialMatchesFormula() public view {
        assertEq(withdrawalQueue.calculateCurrentStvRate(), 10 ** 27);
    }

    function test_CalculateCurrentStvRate_TracksAssetsAfterRewardsAndPenalties() public {
        dashboard.mock_simulateRewards(1 ether);
        assertEq(withdrawalQueue.calculateCurrentStvRate(), 10 ** 27 * 2);

        dashboard.mock_simulateRewards(-1 ether);
        assertEq(withdrawalQueue.calculateCurrentStvRate(), 10 ** 27);
    }

    function test_CalculateCurrentStethShareRate_FollowsOracleValue() public {
        uint256 precision = withdrawalQueue.E27_PRECISION_BASE();
        steth.mock_setTotalPooled(10, 20);
        assertEq(withdrawalQueue.calculateCurrentStethShareRate(), precision / 2);

        steth.mock_setTotalPooled(90, 30);
        assertEq(withdrawalQueue.calculateCurrentStethShareRate(), precision * 3);
    }

    function test_GetWithdrawalStatus_ArrayMatchesSingle() public {
        wrapper.depositETH{value: 100 ether}();
        uint256 requestId1 = wrapper.requestWithdrawal(10 ** STV_DECIMALS);
        uint256 requestId2 = wrapper.requestWithdrawal(2 * 10 ** STV_DECIMALS);

        uint256[] memory ids = new uint256[](2);
        ids[0] = requestId1;
        ids[1] = requestId2;

        WithdrawalQueue.WithdrawalRequestStatus[] memory statuses = withdrawalQueue.getWithdrawalsStatus(ids);
        assertEq(statuses.length, 2);
        assertEq(statuses[0].amountOfStv, 10 ** STV_DECIMALS);
        assertEq(statuses[1].amountOfStv, 2 * 10 ** STV_DECIMALS);
        assertFalse(statuses[0].isFinalized);
        assertFalse(statuses[1].isFinalized);

        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.finalize(1);

        WithdrawalQueue.WithdrawalRequestStatus memory statusSingle = withdrawalQueue.getWithdrawalStatus(requestId1);
        assertTrue(statusSingle.isFinalized);
        assertFalse(statusSingle.isClaimed);

        statuses = withdrawalQueue.getWithdrawalsStatus(ids);
        assertTrue(statuses[0].isFinalized);
        assertFalse(statuses[0].isClaimed);
        assertFalse(statuses[1].isFinalized);
    }

    function test_GetWithdrawalStatus_RevertOnInvalidRequestId() public {
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.InvalidRequestId.selector, 0));
        withdrawalQueue.getWithdrawalStatus(0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(WithdrawalQueue.InvalidRequestId.selector, 0));
        withdrawalQueue.getWithdrawalsStatus(ids);
    }

    function test_GetClaimableEther_ViewLifecycle() public {
        wrapper.depositETH{value: 100 ether}();
        uint256 requestId = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);

        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.finalize(1);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = withdrawalQueue.findCheckpointHints(
            requestIds,
            1,
            withdrawalQueue.getLastCheckpointIndex()
        );

        uint256 claimable = withdrawalQueue.getClaimableEther(requestId);
        assertGt(claimable, 0);

        uint256[] memory batchClaimable = withdrawalQueue.getClaimableEther(requestIds, hints);
        assertEq(batchClaimable[0], claimable);

        wrapper.claimWithdrawal(requestId, address(this));
        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);

        batchClaimable = withdrawalQueue.getClaimableEther(requestIds, hints);
        assertEq(batchClaimable[0], 0);
    }

    function test_GetClaimableEtherBatch_ReturnsZeroForUnfinalized() public {
        wrapper.depositETH{value: 100 ether}();
        uint256 requestId = wrapper.requestWithdrawal(10 ** STV_DECIMALS);

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = requestId;
        uint256[] memory hints = new uint256[](1);
        hints[0] = 0;

        uint256[] memory claimable = withdrawalQueue.getClaimableEther(requestIds, hints);
        assertEq(claimable[0], 0);

        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);
    }

    receive() external payable {}
}
