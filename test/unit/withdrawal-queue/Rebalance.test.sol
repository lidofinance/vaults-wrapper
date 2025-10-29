// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SetupWithdrawalQueue} from "./SetupWithdrawalQueue.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract FinalizationTest is Test, SetupWithdrawalQueue {
    function setUp() public override {
        super.setUp();
        pool.depositETH{value: 100_000 ether}(address(this), address(0));
    }

    // Initial state

    function test_RebalanceFinalization_InitialState() public view {
        assertEq(withdrawalQueue.getLastRequestId(), 0);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);
        assertEq(withdrawalQueue.unfinalizedRequestNumber(), 0);
        assertEq(withdrawalQueue.unfinalizedAssets(), 0);
        assertEq(withdrawalQueue.unfinalizedStv(), 0);

        assertEq(pool.balanceOf(address(withdrawalQueue)), 0);
        assertEq(pool.totalMintedStethShares(), 0);
    }

    // Basic finalization with rebalance

    function test_RebalanceFinalization_RequestAndFinalization() public {
        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        pool.mintStethShares(mintedStethShares);
        uint256 requestId = pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        // Verify request was created
        assertEq(requestId, 1);
        assertEq(withdrawalQueue.getLastRequestId(), 1);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), 0);

        // Stv and debt are transferred to WQ
        assertEq(pool.totalMintedStethShares(), mintedStethShares);
        assertEq(pool.balanceOf(address(withdrawalQueue)), stvToRequest);
        assertEq(pool.mintedStethSharesOf(address(this)), 0);

        // Check request status - should not be finalized yet
        WithdrawalQueue.WithdrawalRequestStatus memory status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertFalse(status.isFinalized);
        assertEq(status.owner, address(this));

        // Move time forward to pass minimum delay
        vm.warp(block.timestamp + MIN_WITHDRAWAL_DELAY_TIME + 1);

        // Finalize the request
        uint256 totalAssets = pool.previewRedeem(stvToRequest);
        uint256 assetsToRebalance = pool.STETH().getPooledEthBySharesRoundUp(mintedStethShares);
        uint256 stvToRebalance = pool.previewWithdraw(assetsToRebalance);

        vm.prank(finalizeRoleHolder);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalQueue.WithdrawalsFinalized(
            1,
            1,
            totalAssets - assetsToRebalance,
            stvToRequest - stvToRebalance,
            stvToRebalance,
            mintedStethShares,
            block.timestamp
        );
        uint256 finalizedCount = withdrawalQueue.finalize(1);

        // Verify finalization succeeded
        assertEq(finalizedCount, 1);
        assertEq(withdrawalQueue.getLastFinalizedRequestId(), requestId);

        // Check request status is now finalized
        status = withdrawalQueue.getWithdrawalStatus(requestId);
        assertTrue(status.isFinalized);
        assertFalse(status.isClaimed);

        // Check balances after finalization
        assertEq(pool.balanceOf(address(withdrawalQueue)), 0);
        assertEq(pool.totalMintedStethShares(), 0);
    }

    function test_RebalanceFinalization_RewardsWithMultipleRequests() public {
        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;

        // Simulate rewards to increase stvRate
        pool.mintStethShares(5 * mintedStethShares);
        dashboard.mock_simulateRewards(1234566789);

        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        // Finalize all requests
        _finalizeRequests(5);

        // Make sure that rounding issues do not leave dust in WQ
        assertEq(pool.balanceOf(address(withdrawalQueue)), 0);
        assertEq(pool.totalMintedStethShares(), 0);
    }

    // Penalties before finalization

    function test_RebalanceFinalization_SmallPenaltiesDoNotAffectUnrelatedUsers() public {
        vm.prank(userAlice);
        pool.depositETH{value: 10 ether}(address(this), address(0));

        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        pool.mintStethShares(mintedStethShares);

        // Request withdrawal
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        // Simulate small penalties before finalization
        dashboard.mock_simulateRewards(-1 ether);

        // Finalize request
        uint256 strangerAssetsBefore = pool.previewRedeem(pool.balanceOf(address(userAlice)));
        _finalizeRequests(1);
        uint256 strangerAssetsAfter = pool.previewRedeem(pool.balanceOf(address(userAlice)));

        // Make sure that finalization that has rebalance does not affect unrelated users
        assertLe(strangerAssetsBefore, strangerAssetsAfter);
    }

    function test_RebalanceFinalization_HugePenaltiesSocialization() public {
        vm.prank(userAlice);
        pool.depositETH{value: 10 ether}(userAlice, address(0));

        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        pool.mintStethShares(mintedStethShares);

        // Request withdrawal
        uint256 requestId = pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        // Simulate huge penalties before finalization
        // which result in the request exceeding the reserve ratio
        dashboard.mock_simulateRewards(-90_000 ether);

        // Finalize request
        uint256 strangerAssetsBefore = pool.previewRedeem(pool.balanceOf(address(userAlice)));
        _finalizeRequests(1);
        uint256 strangerAssetsAfter = pool.previewRedeem(pool.balanceOf(address(userAlice)));

        // Check that there is nothing to claim
        uint256 claimableEther = withdrawalQueue.getClaimableEther(requestId);
        assertEq(claimableEther, 0);

        // Rebalance should affect unrelated users due to socialization of losses
        assertGt(strangerAssetsBefore, strangerAssetsAfter);
    }

    // Vault rebalance before finalization

    function test_RebalanceFinalization_VaultRebalanceBefore() public {
        uint256 mintedStethShares = 10 ** ASSETS_DECIMALS;
        uint256 stvToRequest = 2 * 10 ** STV_DECIMALS;
        pool.mintStethShares(mintedStethShares);

        // Request withdrawal
        pool.requestWithdrawal(stvToRequest, 0, mintedStethShares, address(this));

        // Simulate vault rebalance before finalization
        assertEq(pool.totalExceedingMintedStethShares(), 0);
        dashboard.rebalanceVaultWithShares(dashboard.liabilityShares());
        assertEq(pool.totalExceedingMintedStethShares(), mintedStethShares);

        // Finalize request
        _finalizeRequests(1);

        // Make sure that exceeding minted shares are used in rebalance
        assertEq(pool.totalMintedStethShares(), 0);
        assertEq(pool.totalExceedingMintedStethShares(), 0);
    }
}
