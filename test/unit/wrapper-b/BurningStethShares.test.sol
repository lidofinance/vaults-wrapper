// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";

contract BurningStethSharesTest is Test, SetupWrapperB {
    uint256 ethToDeposit = 4 ether;
    uint256 stethSharesToMint = 1 * 10 ** 18; // 1 stETH share

    function setUp() public override {
        super.setUp();
        // Deposit ETH and mint stETH shares for testing burn functionality
        wrapper.depositETH{value: ethToDeposit}();
        wrapper.mintStethShares(stethSharesToMint);

        // Mint stETH to the test contract so it can burn shares
        vm.deal(address(this), 100 ether);
        steth.submit{value: 10 ether}(address(this));

        // Approve wrapper to spend stETH shares for burning
        steth.approve(address(wrapper), type(uint256).max);
    }

    // Initial state tests

    function test_InitialState_HasMintedStethShares() public view {
        assertEq(wrapper.totalMintedStethShares(), stethSharesToMint);
        assertEq(wrapper.mintedStethSharesOf(address(this)), stethSharesToMint);
    }

    function test_InitialState_HasStethBalance() public view {
        assertGe(steth.sharesOf(address(this)), stethSharesToMint);
    }

    // burn stETH shares tests

    function test_BurnStethShares_DecreasesTotalMintedShares() public {
        uint256 totalBefore = wrapper.totalMintedStethShares();
        uint256 sharesToBurn = stethSharesToMint / 2;

        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.totalMintedStethShares(), totalBefore - sharesToBurn);
    }

    function test_BurnStethShares_DecreasesUserMintedShares() public {
        uint256 userMintedBefore = wrapper.mintedStethSharesOf(address(this));
        uint256 sharesToBurn = stethSharesToMint / 2;

        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.mintedStethSharesOf(address(this)), userMintedBefore - sharesToBurn);
    }

    function test_BurnStethShares_EmitsEvent() public {
        uint256 sharesToBurn = stethSharesToMint / 2;

        vm.expectEmit(true, false, false, true);
        emit WrapperB.StethSharesBurned(address(this), sharesToBurn);

        wrapper.burnStethShares(sharesToBurn);
    }

    function test_BurnStethShares_CallsDashboardBurnShares() public {
        uint256 sharesToBurn = stethSharesToMint / 2;

        vm.expectCall(address(dashboard), abi.encodeWithSelector(dashboard.burnShares.selector, sharesToBurn));

        wrapper.burnStethShares(sharesToBurn);
    }

    function test_BurnStethShares_TransfersStethFromUser() public {
        uint256 sharesToBurn = stethSharesToMint / 2;
        uint256 userBalanceBefore = steth.sharesOf(address(this));

        wrapper.burnStethShares(sharesToBurn);

        assertEq(steth.sharesOf(address(this)), userBalanceBefore - sharesToBurn);
    }

    function test_BurnStethShares_DoesNotLeaveStethOnWrapper() public {
        uint256 sharesToBurn = stethSharesToMint / 2;

        wrapper.burnStethShares(sharesToBurn);

        assertEq(steth.sharesOf(address(wrapper)), 0);
    }

    function test_BurnStethShares_IncreasesAvailableCapacity() public {
        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));
        uint256 sharesToBurn = stethSharesToMint / 2;

        wrapper.burnStethShares(sharesToBurn);

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore + sharesToBurn);
    }

    function test_BurnStethShares_PartialBurn() public {
        uint256 sharesToBurn = stethSharesToMint / 4;

        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.mintedStethSharesOf(address(this)), stethSharesToMint - sharesToBurn);
        assertEq(wrapper.totalMintedStethShares(), stethSharesToMint - sharesToBurn);
    }

    function test_BurnStethShares_FullBurn() public {
        wrapper.burnStethShares(stethSharesToMint);

        assertEq(wrapper.mintedStethSharesOf(address(this)), 0);
        assertEq(wrapper.totalMintedStethShares(), 0);
    }

    function test_BurnStethShares_MultipleBurns() public {
        uint256 firstBurn = stethSharesToMint / 3;
        uint256 secondBurn = stethSharesToMint / 3;

        wrapper.burnStethShares(firstBurn);
        wrapper.burnStethShares(secondBurn);

        assertEq(wrapper.mintedStethSharesOf(address(this)), stethSharesToMint - firstBurn - secondBurn);
        assertEq(wrapper.totalMintedStethShares(), stethSharesToMint - firstBurn - secondBurn);
    }

    // Error cases

    function test_BurnStethShares_RevertOnZeroAmount() public {
        vm.expectRevert(WrapperB.ZeroArgument.selector);
        wrapper.burnStethShares(0);
    }

    function test_BurnStethShares_RevertOnInsufficientMintedShares() public {
        uint256 excessiveAmount = stethSharesToMint + 1;

        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.burnStethShares(excessiveAmount);
    }

    function test_BurnStethShares_RevertOnInsufficientStethBalance() public {
        // Transfer away stETH so user doesn't have enough
        steth.transfer(userAlice, steth.balanceOf(address(this)));

        vm.expectRevert(); // Should revert on transferSharesFrom
        wrapper.burnStethShares(stethSharesToMint);
    }

    function test_BurnStethShares_RevertAfterFullBurn() public {
        // First burn all shares
        wrapper.burnStethShares(stethSharesToMint);

        // Then try to burn more
        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.burnStethShares(1);
    }

    // Different users tests

    function test_BurnStethShares_DifferentUsers() public {
        // Setup other users with deposits and mints
        vm.startPrank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));
        wrapper.mintStethShares(stethSharesToMint);
        steth.submit{value: 10 ether}(address(userAlice));
        steth.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(userBob);
        wrapper.depositETH{value: ethToDeposit}(userBob, address(0));
        wrapper.mintStethShares(stethSharesToMint);
        steth.submit{value: 10 ether}(address(userBob));
        steth.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();

        uint256 totalBefore = wrapper.totalMintedStethShares();
        uint256 sharesToBurn = stethSharesToMint / 2;

        // Alice burns
        vm.prank(userAlice);
        wrapper.burnStethShares(sharesToBurn);

        // Bob burns
        vm.prank(userBob);
        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.mintedStethSharesOf(userAlice), stethSharesToMint - sharesToBurn);
        assertEq(wrapper.mintedStethSharesOf(userBob), stethSharesToMint - sharesToBurn);
        assertEq(wrapper.totalMintedStethShares(), totalBefore - (sharesToBurn * 2));
    }

    function test_BurnStethShares_DoesNotAffectOtherUsers() public {
        // Setup Alice with minted shares
        vm.startPrank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));
        wrapper.mintStethShares(stethSharesToMint);
        steth.submit{value: 10 ether}(address(userAlice));
        steth.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();

        uint256 aliceMintedBefore = wrapper.mintedStethSharesOf(userAlice);
        uint256 sharesToBurn = stethSharesToMint / 2;

        // This contract burns, should not affect Alice
        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.mintedStethSharesOf(userAlice), aliceMintedBefore);
    }

    // Capacity restoration tests

    function test_BurnStethShares_RestoresFullCapacity() public {
        // Use up all capacity
        uint256 additionalMint = wrapper.mintingCapacitySharesOf(address(this));
        wrapper.mintStethShares(additionalMint);

        // Burn all shares
        uint256 totalMinted = wrapper.mintedStethSharesOf(address(this));
        wrapper.burnStethShares(totalMinted);

        // Capacity should be fully restored
        uint256 capacityAfterBurn = wrapper.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfterBurn, totalMinted);
    }

    function test_BurnStethShares_PartialCapacityRestore() public {
        uint256 additionalMint = wrapper.mintingCapacitySharesOf(address(this));
        wrapper.mintStethShares(additionalMint);

        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));
        uint256 sharesToBurn = additionalMint / 2;

        wrapper.burnStethShares(sharesToBurn);

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore + sharesToBurn);
    }

    // Edge cases

    function test_BurnStethShares_WithMinimalAmount() public {
        uint256 minimalBurn = 1; // 1 wei
        uint256 mintedBefore = wrapper.mintedStethSharesOf(address(this));

        wrapper.burnStethShares(minimalBurn);

        assertEq(wrapper.mintedStethSharesOf(address(this)), mintedBefore - minimalBurn);
    }

    function test_BurnStethShares_AfterRewards() public {
        // Simulate rewards accrual
        dashboard.mock_simulateRewards(int256(1 ether));

        uint256 sharesToBurn = stethSharesToMint / 2;
        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));

        wrapper.burnStethShares(sharesToBurn);

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertGe(capacityAfter, capacityBefore + sharesToBurn); // Should be at least as high due to rewards
    }

    function test_BurnStethShares_ExactBurnOfAllShares() public {
        uint256 allMintedShares = wrapper.mintedStethSharesOf(address(this));

        wrapper.burnStethShares(allMintedShares);

        assertEq(wrapper.mintedStethSharesOf(address(this)), 0);
        assertEq(wrapper.totalMintedStethShares(), 0);
    }

    // Approvals

    function test_BurnStethShares_RequiresApproval() public {
        // Test that burning requires proper stETH approval
        uint256 sharesToBurn = stethSharesToMint / 2;

        // Reset approval (assuming it was set during setup)
        steth.approve(address(wrapper), 0);

        // Should fail without approval
        vm.expectRevert();
        wrapper.burnStethShares(sharesToBurn);

        // Should succeed with approval (need to approve stETH amount, not shares)
        uint256 stethAmount = steth.getPooledEthByShares(sharesToBurn);
        steth.approve(address(wrapper), stethAmount);
        wrapper.burnStethShares(sharesToBurn);

        assertEq(wrapper.mintedStethSharesOf(address(this)), stethSharesToMint - sharesToBurn);
    }
}
