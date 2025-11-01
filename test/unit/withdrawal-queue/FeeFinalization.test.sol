// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {Test} from "forge-std/Test.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract FeeFinalizationTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();

        vm.deal(address(this), 200_000 ether);
        vm.deal(finalizeRoleHolder, 10 ether);

        pool.depositETH{value: 100_000 ether}(address(this), address(0));
    }

    function _setWithdrawalFee(uint256 fee) internal {
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.setWithdrawalFee(fee);
    }

    function test_FinalizeFee_ZeroFeeDoesNotPayFinalizer() public {
        uint256 initialBalance = finalizeRoleHolder.balance;
        _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        assertEq(finalizeRoleHolder.balance, initialBalance);
    }

    function test_FinalizeFee_PaysFinalizerWhenSet() public {
        uint256 fee = 0.0005 ether;
        uint256 initialBalance = finalizeRoleHolder.balance;

        _setWithdrawalFee(fee);
        _requestWithdrawalAndFinalize(10 ** STV_DECIMALS);

        assertEq(finalizeRoleHolder.balance, initialBalance + fee);
    }

    function test_FinalizeFee_ReducesClaimByFee() public {
        uint256 fee = 0.0005 ether;
        _setWithdrawalFee(fee);

        uint256 stvToRequest = 10 ** STV_DECIMALS;
        uint256 requestId = withdrawalQueue.requestWithdrawal(address(this), stvToRequest, 0);
        uint256 expectedAssets = pool.previewRedeem(stvToRequest);
        _finalizeRequests(1);

        uint256 balanceBefore = address(this).balance;
        uint256 claimed = withdrawalQueue.claimWithdrawal(address(this), requestId);

        assertEq(claimed, expectedAssets - fee);
        assertEq(address(this).balance, balanceBefore + claimed);
    }

    function test_FinalizeFee_ReducesClaimableByFee() public {
        uint256 fee = 0.0005 ether;
        _setWithdrawalFee(fee);

        uint256 stvToRequest = 10 ** STV_DECIMALS;
        uint256 requestId = withdrawalQueue.requestWithdrawal(address(this), stvToRequest, 0);
        uint256 expectedAssets = pool.previewRedeem(stvToRequest);
        _finalizeRequests(1);

        assertEq(withdrawalQueue.getClaimableEther(requestId), expectedAssets - fee);
    }

    function test_FinalizeFee_RequestWithRebalance() public {
        uint256 fee = 0.0005 ether;
        _setWithdrawalFee(fee);

        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        pool.mintStethShares(mintedStethShares);

        uint256 totalAssets = pool.previewRedeem(stvToRequest);
        uint256 assetsToRebalance = pool.STETH().getPooledEthBySharesRoundUp(mintedStethShares);
        uint256 expectedClaimable = totalAssets - assetsToRebalance - fee;
        assertGt(expectedClaimable, 0);

        uint256 requestId = withdrawalQueue.requestWithdrawal(address(this), stvToRequest, mintedStethShares);
        _finalizeRequests(1);

        assertEq(withdrawalQueue.getClaimableEther(requestId), expectedClaimable);
    }

    function test_FinalizeFee_FeeCapsToRemainingAssets() public {
        uint256 fee = withdrawalQueue.MAX_WITHDRAWAL_FEE();
        _setWithdrawalFee(fee);

        uint256 stvToRequest = (10 ** STV_DECIMALS / 1 ether) * fee;
        uint256 totalAssets = pool.previewRedeem(stvToRequest);
        assertEq(totalAssets, fee);

        uint256 requestId = withdrawalQueue.requestWithdrawal(address(this), stvToRequest, 0);
        dashboard.mock_simulateRewards(-int256(1 ether));
        uint256 expectedAssets = pool.previewRedeem(stvToRequest);

        uint256 finalizerBalanceBefore = finalizeRoleHolder.balance;
        _finalizeRequests(1);
        uint256 finalizerBalanceAfter = finalizeRoleHolder.balance;

        assertGt(finalizerBalanceAfter, finalizerBalanceBefore);
        assertLt(finalizerBalanceAfter - finalizerBalanceBefore, fee);

        assertEq(withdrawalQueue.getClaimableEther(requestId), 0);
    }

    // Receive ETH for claiming tests
    receive() external payable {}
}
