// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupStvStETHPool} from "./SetupStvStETHPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";

contract MintingStethSharesTest is Test, SetupStvStETHPool {
    uint256 ethToDeposit = 4 ether;
    uint256 stethSharesToMint = 1 * 10 ** 18; // 1 stETH share

    function setUp() public override {
        super.setUp();
        // Deposit some ETH to get minting capacity
        pool.depositETH{value: ethToDeposit}(address(0));
    }

    // Initial state tests

    function test_InitialState_NoMintedStethShares() public view {
        assertEq(pool.totalMintedStethShares(), 0);
        assertEq(pool.mintedStethSharesOf(address(this)), 0);
    }

    function test_InitialState_HasMintingCapacity() public view {
        uint256 capacity = pool.mintingCapacitySharesOf(address(this));
        assertGt(capacity, 0);
    }

    function test_InitialState_CorrectMintingCapacityCalculation() public view {
        uint256 capacity = pool.mintingCapacitySharesOf(address(this));
        uint256 expectedReservedPart = (ethToDeposit * pool.reserveRatioBP()) / pool.TOTAL_BASIS_POINTS();
        uint256 expectedUnreservedPart = ethToDeposit - expectedReservedPart;
        uint256 expectedCapacity = steth.getSharesByPooledEth(expectedUnreservedPart);
        assertEq(capacity, expectedCapacity);
    }

    // Mint stETH shares tests

    function test_MintStethShares_IncreasesTotalMintedShares() public {
        uint256 totalBefore = pool.totalMintedStethShares();

        pool.mintStethShares(stethSharesToMint);

        assertEq(pool.totalMintedStethShares(), totalBefore + stethSharesToMint);
    }

    function test_MintStethShares_IncreasesUserMintedShares() public {
        uint256 userMintedBefore = pool.mintedStethSharesOf(address(this));

        pool.mintStethShares(stethSharesToMint);

        assertEq(pool.mintedStethSharesOf(address(this)), userMintedBefore + stethSharesToMint);
    }

    function test_MintStethShares_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit StvStETHPool.StethSharesMinted(address(this), stethSharesToMint);

        pool.mintStethShares(stethSharesToMint);
    }

    function test_MintStethShares_CallsDashboardMintShares() public {
        // Check that dashboard's mint function is called with correct parameters
        vm.expectCall(
            address(dashboard),
            abi.encodeWithSelector(dashboard.mintShares.selector, address(this), stethSharesToMint)
        );

        pool.mintStethShares(stethSharesToMint);
    }

    function test_MintStethShares_DecreasesAvailableCapacity() public {
        uint256 capacityBefore = pool.mintingCapacitySharesOf(address(this));

        pool.mintStethShares(stethSharesToMint);

        uint256 capacityAfter = pool.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore - stethSharesToMint);
    }

    function test_MintStethShares_MultipleMints() public {
        uint256 firstMint = stethSharesToMint / 2;
        uint256 secondMint = stethSharesToMint / 2;

        pool.mintStethShares(firstMint);
        pool.mintStethShares(secondMint);

        assertEq(pool.mintedStethSharesOf(address(this)), firstMint + secondMint);
        assertEq(pool.totalMintedStethShares(), firstMint + secondMint);
    }

    // Error cases

    function test_MintStethShares_RevertOnZeroAmount() public {
        vm.expectRevert(StvStETHPool.ZeroArgument.selector);
        pool.mintStethShares(0);
    }

    function test_MintStethShares_RevertOnInsufficientCapacity() public {
        uint256 capacity = pool.mintingCapacitySharesOf(address(this));
        uint256 excessiveAmount = capacity + 1;

        vm.expectRevert(StvStETHPool.InsufficientMintingCapacity.selector);
        pool.mintStethShares(excessiveAmount);
    }

    function test_MintStethShares_RevertOnExactlyExceedingCapacity() public {
        uint256 capacity = pool.mintingCapacitySharesOf(address(this));

        // First mint should succeed
        pool.mintStethShares(capacity);

        // Second mint should fail even with 1 wei
        vm.expectRevert(StvStETHPool.InsufficientMintingCapacity.selector);
        pool.mintStethShares(1);
    }

    // Different users tests

    function test_MintStethShares_DifferentUsers() public {
        vm.prank(userAlice);
        pool.depositETH{value: ethToDeposit}(userAlice, address(0));

        vm.prank(userBob);
        pool.depositETH{value: ethToDeposit}(userBob, address(0));

        // Both users should have minting capacity
        uint256 aliceCapacity = pool.mintingCapacitySharesOf(userAlice);
        uint256 bobCapacity = pool.mintingCapacitySharesOf(userBob);

        assertGt(aliceCapacity, 0);
        assertGt(bobCapacity, 0);

        // Both should be able to mint
        vm.prank(userAlice);
        pool.mintStethShares(stethSharesToMint);

        vm.prank(userBob);
        pool.mintStethShares(stethSharesToMint);

        assertEq(pool.mintedStethSharesOf(userAlice), stethSharesToMint);
        assertEq(pool.mintedStethSharesOf(userBob), stethSharesToMint);
        assertEq(pool.totalMintedStethShares(), stethSharesToMint * 2);
    }

    // Minting capacity tests

    function test_MintingCapacity_DecreasesAfterMint() public {
        uint256 capacityBefore = pool.mintingCapacitySharesOf(address(this));

        pool.mintStethShares(stethSharesToMint);

        uint256 capacityAfter = pool.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore - stethSharesToMint);
    }

    function test_MintingCapacity_ZeroAfterFullMint() public {
        uint256 fullCapacity = pool.mintingCapacitySharesOf(address(this));

        pool.mintStethShares(fullCapacity);

        assertEq(pool.mintingCapacitySharesOf(address(this)), 0);
    }

    function test_MintingCapacity_IncreasesWithMoreDeposits() public {
        uint256 capacityBefore = pool.mintingCapacitySharesOf(address(this));

        pool.depositETH{value: ethToDeposit}(address(0));

        uint256 capacityAfter = pool.mintingCapacitySharesOf(address(this));
        assertGt(capacityAfter, capacityBefore);
    }

    // Reserve ratio tests

    function test_MintingCapacity_RespectsReserveRatio() public view {
        uint256 assets = pool.assetsOf(address(this));
        uint256 capacity = pool.mintingCapacitySharesOf(address(this));

        // Verify that reserve ratio is respected
        uint256 expectedReservedPart = (assets * pool.reserveRatioBP()) / pool.TOTAL_BASIS_POINTS();
        uint256 expectedUnreservedPart = assets - expectedReservedPart;
        uint256 expectedCapacity = steth.getSharesByPooledEth(expectedUnreservedPart);

        assertEq(capacity, expectedCapacity);
    }
}
