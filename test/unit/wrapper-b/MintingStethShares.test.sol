// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";

contract MintingStethSharesTest is Test, SetupWrapperB {
    uint256 ethToDeposit = 4 ether;
    uint256 stethSharesToMint = 1 * 10 ** 18; // 1 stETH share

    function setUp() public override {
        super.setUp();
        // Deposit some ETH to get minting capacity
        wrapper.depositETH{value: ethToDeposit}();
    }

    // Initial state tests

    function test_InitialState_NoMintedStethShares() public view {
        assertEq(wrapper.totalMintedStethShares(), 0);
        assertEq(wrapper.mintedStethSharesOf(address(this)), 0);
    }

    function test_InitialState_HasMintingCapacity() public view {
        uint256 capacity = wrapper.mintingCapacitySharesOf(address(this));
        assertGt(capacity, 0);
    }

    function test_InitialState_CorrectMintingCapacityCalculation() public view {
        uint256 capacity = wrapper.mintingCapacitySharesOf(address(this));
        uint256 expectedReservedPart = (ethToDeposit * wrapper.WRAPPER_RR_BP()) / wrapper.TOTAL_BASIS_POINTS();
        uint256 expectedUnreservedPart = ethToDeposit - expectedReservedPart;
        uint256 expectedCapacity = steth.getSharesByPooledEth(expectedUnreservedPart);
        assertEq(capacity, expectedCapacity);
    }

    // Mint stETH shares tests

    function test_MintStethShares_IncreasesTotalMintedShares() public {
        uint256 totalBefore = wrapper.totalMintedStethShares();

        wrapper.mintStethShares(stethSharesToMint);

        assertEq(wrapper.totalMintedStethShares(), totalBefore + stethSharesToMint);
    }

    function test_MintStethShares_IncreasesUserMintedShares() public {
        uint256 userMintedBefore = wrapper.mintedStethSharesOf(address(this));

        wrapper.mintStethShares(stethSharesToMint);

        assertEq(wrapper.mintedStethSharesOf(address(this)), userMintedBefore + stethSharesToMint);
    }

    function test_MintStethShares_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit WrapperB.StethSharesMinted(address(this), stethSharesToMint);

        wrapper.mintStethShares(stethSharesToMint);
    }

    function test_MintStethShares_CallsDashboardMintShares() public {
        // Check that dashboard's mint function is called with correct parameters
        vm.expectCall(
            address(dashboard),
            abi.encodeWithSelector(dashboard.mintShares.selector, address(this), stethSharesToMint)
        );

        wrapper.mintStethShares(stethSharesToMint);
    }

    function test_MintStethShares_DecreasesAvailableCapacity() public {
        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));

        wrapper.mintStethShares(stethSharesToMint);

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore - stethSharesToMint);
    }

    function test_MintStethShares_MultipleMints() public {
        uint256 firstMint = stethSharesToMint / 2;
        uint256 secondMint = stethSharesToMint / 2;

        wrapper.mintStethShares(firstMint);
        wrapper.mintStethShares(secondMint);

        assertEq(wrapper.mintedStethSharesOf(address(this)), firstMint + secondMint);
        assertEq(wrapper.totalMintedStethShares(), firstMint + secondMint);
    }

    // Error cases

    function test_MintStethShares_RevertOnZeroAmount() public {
        vm.expectRevert(WrapperB.ZeroArgument.selector);
        wrapper.mintStethShares(0);
    }

    function test_MintStethShares_RevertOnInsufficientCapacity() public {
        uint256 capacity = wrapper.mintingCapacitySharesOf(address(this));
        uint256 excessiveAmount = capacity + 1;

        vm.expectRevert(WrapperB.InsufficientMintingCapacity.selector);
        wrapper.mintStethShares(excessiveAmount);
    }

    function test_MintStethShares_RevertOnExactlyExceedingCapacity() public {
        uint256 capacity = wrapper.mintingCapacitySharesOf(address(this));

        // First mint should succeed
        wrapper.mintStethShares(capacity);

        // Second mint should fail even with 1 wei
        vm.expectRevert(WrapperB.InsufficientMintingCapacity.selector);
        wrapper.mintStethShares(1);
    }

    // Different users tests

    function test_MintStethShares_DifferentUsers() public {
        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        vm.prank(userBob);
        wrapper.depositETH{value: ethToDeposit}(userBob, address(0));

        // Both users should have minting capacity
        uint256 aliceCapacity = wrapper.mintingCapacitySharesOf(userAlice);
        uint256 bobCapacity = wrapper.mintingCapacitySharesOf(userBob);

        assertGt(aliceCapacity, 0);
        assertGt(bobCapacity, 0);

        // Both should be able to mint
        vm.prank(userAlice);
        wrapper.mintStethShares(stethSharesToMint);

        vm.prank(userBob);
        wrapper.mintStethShares(stethSharesToMint);

        assertEq(wrapper.mintedStethSharesOf(userAlice), stethSharesToMint);
        assertEq(wrapper.mintedStethSharesOf(userBob), stethSharesToMint);
        assertEq(wrapper.totalMintedStethShares(), stethSharesToMint * 2);
    }

    // Minting capacity tests

    function test_MintingCapacity_DecreasesAfterMint() public {
        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));

        wrapper.mintStethShares(stethSharesToMint);

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertEq(capacityAfter, capacityBefore - stethSharesToMint);
    }

    function test_MintingCapacity_ZeroAfterFullMint() public {
        uint256 fullCapacity = wrapper.mintingCapacitySharesOf(address(this));

        wrapper.mintStethShares(fullCapacity);

        assertEq(wrapper.mintingCapacitySharesOf(address(this)), 0);
    }

    function test_MintingCapacity_IncreasesWithMoreDeposits() public {
        uint256 capacityBefore = wrapper.mintingCapacitySharesOf(address(this));

        wrapper.depositETH{value: ethToDeposit}();

        uint256 capacityAfter = wrapper.mintingCapacitySharesOf(address(this));
        assertGt(capacityAfter, capacityBefore);
    }

    // Reserve ratio tests

    function test_MintingCapacity_RespectsReserveRatio() public {
        uint256 effectiveAssets = wrapper.effectiveAssetsOf(address(this));
        uint256 capacity = wrapper.mintingCapacitySharesOf(address(this));

        // Verify that reserve ratio is respected
        uint256 expectedReservedPart = (effectiveAssets * wrapper.WRAPPER_RR_BP()) / wrapper.TOTAL_BASIS_POINTS();
        uint256 expectedUnreservedPart = effectiveAssets - expectedReservedPart;
        uint256 expectedCapacity = steth.getSharesByPooledEth(expectedUnreservedPart);

        assertEq(capacity, expectedCapacity);
    }
}
