// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TransferBlockingTest is Test, SetupWrapperB {
    uint256 ethToDeposit = 10 ether;

    // Helper functions to replicate internal calculations from WrapperB
    function _calcAssetsToLockForStethShares(uint256 _stethShares) internal view returns (uint256 assetsToLock) {
        if (_stethShares == 0) return 0;
        uint256 stethAmount = steth.getPooledEthBySharesRoundUp(_stethShares);
        assetsToLock = Math.mulDiv(
            stethAmount,
            wrapper.TOTAL_BASIS_POINTS(),
            wrapper.TOTAL_BASIS_POINTS() - wrapper.WRAPPER_RR_BP(),
            Math.Rounding.Ceil
        );
    }

    function _calcStvToLockForStethShares(uint256 _stethShares) internal view returns (uint256 stvToLock) {
        uint256 assetsToLock = _calcAssetsToLockForStethShares(_stethShares);
        stvToLock = wrapper.previewDeposit(assetsToLock);
    }

    function setUp() public override {
        super.setUp();
        wrapper.depositETH{value: ethToDeposit}();
    }

    // Basic transfer tests without debt

    function test_Transfer_AllowedWithoutDebt() public {
        uint256 balance = wrapper.balanceOf(address(this));
        uint256 transferAmount = balance / 2;

        wrapper.transfer(userAlice, transferAmount);

        assertEq(wrapper.balanceOf(userAlice), transferAmount);
        assertEq(wrapper.balanceOf(address(this)), balance - transferAmount);
    }

    function test_Transfer_ZeroAmountAlwaysAllowed() public {
        // Zero transfer should work without any minting
        wrapper.transfer(userAlice, 0);
        assertEq(wrapper.balanceOf(userAlice), 0);

        // Zero transfer should also work with maximum debt
        uint256 mintCapacity = wrapper.mintingCapacitySharesOf(address(this));
        wrapper.mintStethShares(mintCapacity);

        wrapper.transfer(userAlice, 0);
        assertEq(wrapper.balanceOf(userAlice), 0);
    }

    // Test minting creates restrictions

    function test_MintingCreatesDebt() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);
        assertEq(wrapper.mintedStethSharesOf(address(this)), sharesToMint);
    }

    // Core transfer blocking tests

    function test_Transfer_BlockedWhenInsufficientBalanceAfterMinting() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToMint);

        uint256 balance = wrapper.balanceOf(address(this));
        uint256 requiredLocked = _calcStvToLockForStethShares(sharesToMint);
        uint256 excessiveTransfer = balance - requiredLocked + 1;

        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        wrapper.transfer(userAlice, excessiveTransfer);
    }

    function test_Transfer_AllowedWhenWithinAvailableBalance() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(sharesToMint);

        uint256 balance = wrapper.balanceOf(address(this));
        uint256 requiredLocked = _calcStvToLockForStethShares(sharesToMint);
        uint256 safeTransfer = balance - requiredLocked;

        wrapper.transfer(userAlice, safeTransfer);

        assertEq(wrapper.balanceOf(address(this)), requiredLocked);
    }

    // TransferFrom tests

    function test_TransferFrom_BlockedWhenInsufficientBalance() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToMint);

        uint256 balance = wrapper.balanceOf(address(this));
        uint256 requiredLocked = _calcStvToLockForStethShares(sharesToMint);
        uint256 excessiveTransfer = balance - requiredLocked + 1;

        wrapper.approve(userAlice, excessiveTransfer);

        vm.prank(userAlice);
        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        wrapper.transferFrom(address(this), userBob, excessiveTransfer);
    }

    function test_TransferFrom_AllowedWhenWithinBalance() public {
        uint256 sharesToMint = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToMint);

        uint256 balance = wrapper.balanceOf(address(this));
        uint256 requiredLocked = _calcStvToLockForStethShares(sharesToMint);
        uint256 safeTransfer = balance - requiredLocked;

        wrapper.approve(userAlice, safeTransfer);

        vm.prank(userAlice);
        wrapper.transferFrom(address(this), userBob, safeTransfer);

        assertEq(wrapper.balanceOf(address(this)), requiredLocked);
    }

    // Different users with different debt levels

    function test_Transfer_IndependentRestrictionsForDifferentUsers() public {
        // Alice deposits and mints (creates debt)
        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        uint256 aliceMintCapacity = wrapper.mintingCapacitySharesOf(userAlice);
        vm.prank(userAlice);
        wrapper.mintStethShares(aliceMintCapacity / 2);

        // Bob deposits but doesn't mint (no debt)
        vm.prank(userBob);
        wrapper.depositETH{value: ethToDeposit}(userBob, address(0));

        uint256 bobBalance = wrapper.balanceOf(userBob);

        // Bob should be able to transfer his entire balance (no restrictions)
        vm.prank(userBob);
        wrapper.transfer(userAlice, bobBalance);

        assertEq(wrapper.balanceOf(userBob), 0);

        // Alice should have restrictions due to her debt
        uint256 aliceBalance = wrapper.balanceOf(userAlice);
        uint256 aliceRequiredLocked = _calcStvToLockForStethShares(wrapper.mintedStethSharesOf(userAlice));

        uint256 maxSafeTransfer = aliceBalance - aliceRequiredLocked;
        uint256 excessiveTransfer = maxSafeTransfer + 1;

        vm.prank(userAlice);
        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        wrapper.transfer(userBob, excessiveTransfer);
    }

    // Receiving transfers should not be affected by debt

    function test_Transfer_ReceivingNotAffectedByDebt() public {
        // Alice has maximum debt
        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        uint256 aliceMintCapacity = wrapper.mintingCapacitySharesOf(userAlice);
        vm.prank(userAlice);
        wrapper.mintStethShares(aliceMintCapacity);

        // This contract transfers to Alice (Alice is receiving, not sending)
        uint256 transferAmount = wrapper.balanceOf(address(this)) / 4;
        uint256 aliceBalanceBefore = wrapper.balanceOf(userAlice);

        wrapper.transfer(userAlice, transferAmount);

        // Alice should receive the transfer despite having debt
        assertEq(wrapper.balanceOf(userAlice), aliceBalanceBefore + transferAmount);
    }

    // Debt changes affect transfer restrictions

    function test_Transfer_RestrictionUpdatesAfterAdditionalMinting() public {
        uint256 mintCapacity = wrapper.mintingCapacitySharesOf(address(this));
        uint256 firstMint = mintCapacity / 4;

        // First mint
        wrapper.mintStethShares(firstMint);

        uint256 balance = wrapper.balanceOf(address(this));
        uint256 initialRequiredLocked = _calcStvToLockForStethShares(firstMint);
        uint256 initialMaxTransfer = balance > initialRequiredLocked ? balance - initialRequiredLocked : 0;

        // Mint more shares to increase debt
        uint256 additionalMint = mintCapacity / 4;
        wrapper.mintStethShares(additionalMint);

        // Now the previous safe transfer amount should be blocked due to increased debt
        vm.expectRevert(WrapperB.InsufficientReservedBalance.selector);
        wrapper.transfer(userAlice, initialMaxTransfer);
    }

    function test_Transfer_RestrictionReleasesAfterBurning() public {
        uint256 mintCapacity = wrapper.mintingCapacitySharesOf(address(this));
        uint256 sharesToMint = mintCapacity / 2;

        wrapper.mintStethShares(sharesToMint);

        uint256 initialRequiredLocked = _calcStvToLockForStethShares(sharesToMint);

        // Burn half the shares
        vm.deal(address(this), 100 ether);
        steth.submit{value: 10 ether}(address(this));
        steth.approve(address(wrapper), type(uint256).max);

        uint256 sharesToBurn = sharesToMint / 2;
        wrapper.burnStethShares(sharesToBurn);

        uint256 newRequiredLocked = _calcStvToLockForStethShares(sharesToMint - sharesToBurn);

        // Should require less locked amount now
        assertLt(newRequiredLocked, initialRequiredLocked);

        // Should be able to transfer more now
        uint256 currentBalance = wrapper.balanceOf(address(this));
        uint256 newMaxTransfer = currentBalance - newRequiredLocked - 100;
        wrapper.transfer(userAlice, newMaxTransfer);
        // This should succeed without revert
    }

    // Edge cases

    function test_Transfer_CorrectCalculationOfRequiredLocked() public {
        uint256 mintCapacity = wrapper.mintingCapacitySharesOf(address(this));
        uint256 sharesToMint = mintCapacity / 3;

        wrapper.mintStethShares(sharesToMint);

        // Verify our helper function matches the contract's internal logic
        uint256 requiredLocked = _calcStvToLockForStethShares(sharesToMint);
        uint256 balance = wrapper.balanceOf(address(this));

        // Should be able to transfer exactly (balance - requiredLocked)
        uint256 maxTransfer = balance - requiredLocked;
        wrapper.transfer(userAlice, maxTransfer);

        // Should have exactly requiredLocked left
        assertEq(wrapper.balanceOf(address(this)), requiredLocked);
    }

    // Reserve ratio verification

    function test_Transfer_ReserveRatioImpactOnCalculations() public view {
        uint256 testShares = 1 ether;
        uint256 reserveRatio = wrapper.WRAPPER_RR_BP();
        uint256 totalBasisPoints = wrapper.TOTAL_BASIS_POINTS();

        // Verify reserve ratio is configured correctly
        assertGt(reserveRatio, 0);
        assertLt(reserveRatio, totalBasisPoints);

        // Verify calculation logic
        uint256 stethAmount = steth.getPooledEthBySharesRoundUp(testShares);
        uint256 expectedAssetsToLock = Math.mulDiv(
            stethAmount,
            totalBasisPoints,
            totalBasisPoints - reserveRatio,
            Math.Rounding.Ceil
        );
        uint256 calculatedAssetsToLock = _calcAssetsToLockForStethShares(testShares);

        assertEq(calculatedAssetsToLock, expectedAssetsToLock);
    }
}
