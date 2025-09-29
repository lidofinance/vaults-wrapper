// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console, stdError} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract RebalanceMintedStethSharesTest is Test, SetupWrapperB {
    uint256 ethToDeposit = 10 ether;

    function setUp() public override {
        super.setUp();
        wrapper.depositETH{value: ethToDeposit}();
    }

    // Error validation tests

    function test_RebalanceMintedStethShares_RevertOnZeroAmount() public {
        vm.expectRevert(WrapperB.ZeroArgument.selector);
        wrapper.rebalanceMintedStethShares(0);
    }

    function test_RebalanceMintedStethShares_RevertOnInsufficientMintedShares() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.rebalanceMintedStethShares(sharesToMint + 1);
    }

    function test_RebalanceMintedStethShares_RevertOnNoMintedShares() public {
        // Try to rebalance without having any minted shares
        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.rebalanceMintedStethShares(10 ** 18);
    }

    function test_RebalanceMintedStethShares_RevertOnStaleReport() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        // Set report as stale
        dashboard.VAULT_HUB().mock_setReportFreshness(dashboard.STAKING_VAULT(), false);

        vm.expectRevert(WrapperB.VaultReportStale.selector);
        wrapper.rebalanceMintedStethShares(sharesToMint);
    }

    function test_RebalanceMintedStethShares_EmitsCorrectEvent() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        vm.expectEmit(true, false, false, true);
        emit WrapperB.StethSharesRebalanced(address(this), sharesToMint);

        wrapper.rebalanceMintedStethShares(sharesToMint);
    }

    // Basic functionality tests

    function test_RebalanceMintedStethShares_BasicFunctionality() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        uint256 balanceBefore = wrapper.balanceOf(address(this));
        uint256 mintedSharesBefore = wrapper.mintedStethSharesOf(address(this));
        uint256 totalSupplyBefore = wrapper.totalSupply();

        wrapper.rebalanceMintedStethShares(sharesToMint);

        assertEq(wrapper.mintedStethSharesOf(address(this)), mintedSharesBefore - sharesToMint);
        assertLt(wrapper.balanceOf(address(this)), balanceBefore);
        assertLt(wrapper.totalSupply(), totalSupplyBefore);
    }

    // Exceeding shares scenarios

    function test_RebalanceMintedStethShares_WithExceedingShares_FullyInternal() public {
        // Setup: Create exceeding shares by simulating vault rebalancing
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        // Simulate external vault rebalance that creates exceeding shares
        dashboard.rebalanceVaultWithShares(sharesToMint);

        // Verify we have exceeding shares
        assertEq(wrapper.totalExceedingMintedStethShares(), sharesToMint);

        uint256 balanceBefore = wrapper.balanceOf(address(this));

        // Rebalance amount that can be handled fully internally
        wrapper.rebalanceMintedStethShares(sharesToMint);

        // Verify: should only burn STV, no external dashboard call needed
        assertEq(wrapper.totalExceedingMintedStethShares(), 0);
        assertLt(wrapper.balanceOf(address(this)), balanceBefore);
        assertEq(wrapper.mintedStethSharesOf(address(this)), 0);
    }

    function test_RebalanceMintedStethShares_WithExceedingShares_PartiallyInternal() public {
        // Create scenario where rebalance amount exceeds internal capacity
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToMint);

        // Create smaller exceeding shares
        uint256 exceedingShares = sharesToMint / 4;
        dashboard.rebalanceVaultWithShares(exceedingShares);

        uint256 dashboardLiabilityBefore = dashboard.liabilityShares();
        uint256 balanceBefore = wrapper.balanceOf(address(this));

        // Rebalance more than exceeding shares
        uint256 rebalanceAmount = exceedingShares + (sharesToMint / 4);
        wrapper.rebalanceMintedStethShares(rebalanceAmount);

        // Verify: should handle exceeding internally, rest via dashboard
        assertEq(wrapper.totalExceedingMintedStethShares(), 0);
        assertLt(dashboard.liabilityShares(), dashboardLiabilityBefore); // Dashboard was called
        assertLt(wrapper.balanceOf(address(this)), balanceBefore); // STV burned
    }

    function test_RebalanceMintedStethShares_NoExceedingShares_CallsDashboard() public {
        // Setup: Normal scenario without exceeding shares
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        uint256 dashboardLiabilityBefore = dashboard.liabilityShares();

        wrapper.rebalanceMintedStethShares(sharesToMint);

        // Should call dashboard to rebalance vault
        assertLt(dashboard.liabilityShares(), dashboardLiabilityBefore);
    }

    // Edge cases and partial operations

    function test_RebalanceMintedStethShares_PartialRebalance() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToMint);

        uint256 sharesToRebalance = sharesToMint / 2;
        uint256 balanceBefore = wrapper.balanceOf(address(this));
        uint256 mintedBefore = wrapper.mintedStethSharesOf(address(this));

        wrapper.rebalanceMintedStethShares(sharesToRebalance);

        assertEq(wrapper.mintedStethSharesOf(address(this)), mintedBefore - sharesToRebalance);
        assertLt(wrapper.balanceOf(address(this)), balanceBefore); // Some STV burned
    }

    function test_RebalanceMintedStethShares_MinimalAmount() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        uint256 balanceBefore = wrapper.balanceOf(address(this));

        // Rebalance minimal amount (1 wei)
        wrapper.rebalanceMintedStethShares(1);

        assertEq(wrapper.mintedStethSharesOf(address(this)), sharesToMint - 1);
        assertLt(wrapper.balanceOf(address(this)), balanceBefore);
    }

    // Multi-user scenarios

    function test_RebalanceMintedStethShares_MultipleUsers_IndependentRebalancing() public {
        // Alice and Bob deposit and mint
        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        vm.prank(userBob);
        wrapper.depositETH{value: ethToDeposit}(userBob, address(0));

        uint256 aliceMintCapacity = wrapper.mintingCapacitySharesOf(userAlice);
        uint256 bobMintCapacity = wrapper.mintingCapacitySharesOf(userBob);

        vm.prank(userAlice);
        wrapper.mintStethShares(aliceMintCapacity / 2);

        vm.prank(userBob);
        wrapper.mintStethShares(bobMintCapacity / 4);

        uint256 aliceMintedBefore = wrapper.mintedStethSharesOf(userAlice);
        uint256 bobMintedBefore = wrapper.mintedStethSharesOf(userBob);

        // Alice rebalances some of her shares
        uint256 aliceRebalanceAmount = aliceMintedBefore / 2;
        vm.prank(userAlice);
        wrapper.rebalanceMintedStethShares(aliceRebalanceAmount);

        // Verify Alice's debt decreased but Bob's unchanged
        assertEq(wrapper.mintedStethSharesOf(userAlice), aliceMintedBefore - aliceRebalanceAmount);
        assertEq(wrapper.mintedStethSharesOf(userBob), bobMintedBefore); // Unchanged
    }
}
