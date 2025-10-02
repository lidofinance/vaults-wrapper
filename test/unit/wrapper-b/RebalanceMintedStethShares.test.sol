// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console, stdError} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperBase} from "src/WrapperBase.sol";
import {WrapperB} from "src/WrapperB.sol";

contract RebalanceMintedStethSharesTest is Test, SetupWrapperB {
    uint256 ethToDeposit = 10 ether;
    uint256 unlimitedStvToBurn = type(uint256).max;

    function setUp() public override {
        super.setUp();
        // Deposit ETH and mint shares directly on WithdrawalQueue for testing
        wrapper.depositETH{value: ethToDeposit}(withdrawalQueue, address(0));
    }

    function _mintStethSharesToWQ(uint256 _amount) internal {
        vm.prank(withdrawalQueue);
        wrapper.mintStethShares(_amount);
    }

    // Access control tests

    function test_RebalanceMintedStethShares_RevertOnCallFromStranger() public {
        vm.prank(userAlice);
        vm.expectRevert(WrapperBase.NotWithdrawalQueue.selector);
        wrapper.rebalanceMintedStethShares(1, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_SuccessfulCallFromWithdrawalQueue() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqMintedBefore = wrapper.mintedStethSharesOf(withdrawalQueue);
        uint256 wqBalanceBefore = wrapper.balanceOf(withdrawalQueue);

        // Call from withdrawal queue
        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        // Verify withdrawal queue's shares were rebalanced
        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), wqMintedBefore - sharesToMint);
        assertLt(wrapper.balanceOf(withdrawalQueue), wqBalanceBefore);
    }

    // Error validation tests

    function test_RebalanceMintedStethShares_RevertOnZeroAmount() public {
        vm.prank(withdrawalQueue);
        vm.expectRevert(WrapperB.ZeroArgument.selector);
        wrapper.rebalanceMintedStethShares(0, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_RevertOnInsufficientMintedShares() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        vm.prank(withdrawalQueue);
        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.rebalanceMintedStethShares(sharesToMint + 1, unlimitedStvToBurn);
    }

    function test_RebalanceMintedStethShares_RevertOnNoMintedShares() public {
        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), 0);

        vm.prank(withdrawalQueue);
        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.rebalanceMintedStethShares(10 ** 18, unlimitedStvToBurn);
    }

    // Basic functionality test

    function test_RebalanceMintedStethShares_BasicFunctionality() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqBalanceBefore = wrapper.balanceOf(withdrawalQueue);
        uint256 wqMintedSharesBefore = wrapper.mintedStethSharesOf(withdrawalQueue);
        uint256 totalSupplyBefore = wrapper.totalSupply();

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), wqMintedSharesBefore - sharesToMint);
        assertLt(wrapper.balanceOf(withdrawalQueue), wqBalanceBefore);
        assertLt(wrapper.totalSupply(), totalSupplyBefore);
    }

    function test_RebalanceMintedStethShares_EmitsCorrectEvent() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Only check that event is emitted with correct shares parameter (without exact stv amount)
        vm.expectEmit(true, true, false, false);
        emit WrapperB.StethSharesRebalanced(sharesToMint, 0);

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);
    }

    // Exceeding shares scenarios

    function test_RebalanceMintedStethShares_WithExceedingShares() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Create exceeding shares by external rebalancing
        dashboard.rebalanceVaultWithShares(sharesToMint / 2);

        uint256 exceedingBefore = wrapper.totalExceedingMintedStethShares();
        assertGt(exceedingBefore, 0); // Should have exceeding shares

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, unlimitedStvToBurn);

        // Should rebalance shares
        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), 0);
    }

    // Socialization scenarios

    function test_RebalanceMintedStethShares_SocializationWhenMaxStvExceeded() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        // Set very low maxStvToBurn to trigger socialization
        uint256 maxStvToBurn = 1 wei;

        // Only check that SocializedLoss event is emitted (without exact amounts)
        vm.expectEmit(false, false, false, false);
        emit WrapperB.SocializedLoss(0, 0);

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, maxStvToBurn);

        // Verify shares were still rebalanced
        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), 0);
    }

    function test_RebalanceMintedStethShares_ZeroMaxStvToBurn_FullSocialization() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 maxStvToBurn = 0; // No burning allowed
        uint256 wqBalanceBefore = wrapper.balanceOf(withdrawalQueue);

        // Only check that SocializedLoss event is emitted (without exact amounts)
        vm.expectEmit(false, false, false, false);
        emit WrapperB.SocializedLoss(0, 0);

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToMint, maxStvToBurn);

        // No STV should be burned
        assertEq(wrapper.balanceOf(withdrawalQueue), wqBalanceBefore);
        // But shares should still be rebalanced
        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), 0);
    }

    // Partial rebalance scenarios

    function test_RebalanceMintedStethShares_PartialRebalance() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 2;
        _mintStethSharesToWQ(sharesToMint);

        uint256 sharesToRebalance = sharesToMint / 2;
        uint256 wqBalanceBefore = wrapper.balanceOf(withdrawalQueue);
        uint256 wqMintedBefore = wrapper.mintedStethSharesOf(withdrawalQueue);

        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(sharesToRebalance, unlimitedStvToBurn);

        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), wqMintedBefore - sharesToRebalance);
        assertLt(wrapper.balanceOf(withdrawalQueue), wqBalanceBefore); // Some STV burned
    }

    function test_RebalanceMintedStethShares_MinimalAmount() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(withdrawalQueue) / 4;
        _mintStethSharesToWQ(sharesToMint);

        uint256 wqBalanceBefore = wrapper.balanceOf(withdrawalQueue);

        // Rebalance minimal amount (1 wei)
        vm.prank(withdrawalQueue);
        wrapper.rebalanceMintedStethShares(1, unlimitedStvToBurn);

        assertEq(wrapper.mintedStethSharesOf(withdrawalQueue), sharesToMint - 1);
        assertLt(wrapper.balanceOf(withdrawalQueue), wqBalanceBefore);
    }
}
