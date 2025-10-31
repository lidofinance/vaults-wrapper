// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {SetupStvStETHPool} from "./SetupStvStETHPool.sol";
import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";

contract RebalanceMintedStethSharesTest is Test, SetupStvStETHPool {
    uint256 ethToDeposit = 10 ether;
    uint256 unlimitedStvToBurn = type(uint256).max;

    function setUp() public override {
        super.setUp();
        // Deposit ETH and mint shares directly on WithdrawalQueue for testing
        pool.depositETH{value: ethToDeposit}(withdrawalQueue, address(0));
    }

    function _mintStethSharesToWQ(uint256 _amount) internal {
        vm.prank(withdrawalQueue);
        pool.mintStethShares(_amount);
    }

    // Access control tests

    function test_RebalanceMintedStethShares_RevertOnCallFromStranger() public {
        vm.prank(userAlice);
        vm.expectRevert(StvPool.NotWithdrawalQueue.selector);
        pool.rebalanceMintedStethShares(1, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_SuccessfulCallFromWithdrawalQueue() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqMintedBefore = pool.mintedStethSharesOf(withdrawalQueue);
        uint256 wqBalanceBefore = pool.balanceOf(withdrawalQueue);

        // Call from withdrawal queue
        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        // Verify withdrawal queue's shares were rebalanced
        assertEq(pool.mintedStethSharesOf(withdrawalQueue), wqMintedBefore - sharesToMint);
        assertLt(pool.balanceOf(withdrawalQueue), wqBalanceBefore);
    }

    // Error validation tests

    function test_RebalanceMintedStethShares_RevertOnZeroAmount() public {
        vm.prank(withdrawalQueue);
        vm.expectRevert(StvStETHPool.ZeroArgument.selector);
        pool.rebalanceMintedStethShares(0, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_RevertOnInsufficientMintedShares() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        vm.prank(withdrawalQueue);
        vm.expectRevert(StvStETHPool.InsufficientMintedShares.selector);
        pool.rebalanceMintedStethShares(sharesToMint + 1, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_RevertOnNoMintedShares() public {
        assertEq(pool.mintedStethSharesOf(withdrawalQueue), 0);

        vm.prank(withdrawalQueue);
        vm.expectRevert(StvStETHPool.InsufficientMintedShares.selector);
        pool.rebalanceMintedStethShares(10 ** 18, unlimitedStvToBurn);
    }

    // Basic functionality test

    function test_RebalanceMintedStethShares_BasicFunctionality() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqBalanceBefore = pool.balanceOf(withdrawalQueue);
        uint256 wqMintedSharesBefore = pool.mintedStethSharesOf(withdrawalQueue);
        uint256 totalSupplyBefore = pool.totalSupply();

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        assertEq(pool.mintedStethSharesOf(withdrawalQueue), wqMintedSharesBefore - sharesToMint);
        assertLt(pool.balanceOf(withdrawalQueue), wqBalanceBefore);
        assertLt(pool.totalSupply(), totalSupplyBefore);
    }

    function test_RebalanceMintedStethShares_EmitsCorrectEvent() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Only check that event is emitted with correct shares parameter (without exact stv amount)
        vm.expectEmit(true, true, true, false);
        emit StvStETHPool.StethSharesRebalanced(withdrawalQueue, sharesToMint, 0);

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);
    }

    // Exceeding shares scenarios

    function test_RebalanceMintedStethShares_WithExceedingShares() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Create exceeding shares by external rebalancing
        dashboard.rebalanceVaultWithShares(sharesToMint / 2);

        uint256 exceedingBefore = pool.totalExceedingMintedStethShares();
        assertGt(exceedingBefore, 0); // Should have exceeding shares

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        // Should rebalance shares
        assertEq(pool.mintedStethSharesOf(withdrawalQueue), 0);
    }

    // Socialization scenarios

    function test_RebalanceMintedStethShares_SocializationWhenMaxStvExceeded() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Set very low maxStvToBurn to trigger socialization
        uint256 maxStvToBurn = 1 wei;

        // Only check that SocializedLoss event is emitted (without exact amounts)
        vm.expectEmit(false, false, false, false);
        emit StvStETHPool.SocializedLoss(0, 0);

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, maxStvToBurn);

        // Verify shares were still rebalanced
        assertEq(pool.mintedStethSharesOf(withdrawalQueue), 0);
    }

    function test_RebalanceMintedStethShares_ZeroMaxStvToBurn_FullSocialization() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 maxStvToBurn = 0; // No burning allowed
        uint256 wqBalanceBefore = pool.balanceOf(withdrawalQueue);

        // Only check that SocializedLoss event is emitted (without exact amounts)
        vm.expectEmit(false, false, false, false);
        emit StvStETHPool.SocializedLoss(0, 0);

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToMint, maxStvToBurn);

        // No STV should be burned
        assertEq(pool.balanceOf(withdrawalQueue), wqBalanceBefore);
        // But shares should still be rebalanced
        assertEq(pool.mintedStethSharesOf(withdrawalQueue), 0);
    }

    // Partial rebalance scenarios

    function test_RebalanceMintedStethShares_PartialRebalance() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 2;
        _mintStethSharesToWQ(sharesToMint);

        uint256 sharesToRebalance = sharesToMint / 2;
        uint256 wqBalanceBefore = pool.balanceOf(withdrawalQueue);
        uint256 wqMintedBefore = pool.mintedStethSharesOf(withdrawalQueue);

        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(sharesToRebalance, unlimitedStvToBurn);

        assertEq(pool.mintedStethSharesOf(withdrawalQueue), wqMintedBefore - sharesToRebalance);
        assertLt(pool.balanceOf(withdrawalQueue), wqBalanceBefore); // Some STV burned
    }

    function test_RebalanceMintedStethShares_MinimalAmount() public {
        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(withdrawalQueue, 0) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqBalanceBefore = pool.balanceOf(withdrawalQueue);

        // Rebalance minimal amount (1 wei)
        vm.prank(withdrawalQueue);
        pool.rebalanceMintedStethShares(1, unlimitedStvToBurn);

        assertEq(pool.mintedStethSharesOf(withdrawalQueue), sharesToMint - 1);
        assertLt(pool.balanceOf(withdrawalQueue), wqBalanceBefore);
    }
}
