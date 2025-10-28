// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SetupStvStETHPool} from "./SetupStvStETHPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";

contract TransferWithLiabilityTest is Test, SetupStvStETHPool {
    function setUp() public override {
        super.setUp();
        pool.depositETH{value: 20 ether}(address(0));
    }

    function test_TransferWithLiability_TransfersDebtAndStv() public {
        uint256 sharesToTransfer = pool.remainingMintingCapacitySharesOf(address(this), 0) / 2;
        pool.mintStethShares(sharesToTransfer);

        uint256 stvToTransfer = pool.balanceOf(address(this));

        vm.expectEmit(true, false, false, true);
        emit StvStETHPool.StethSharesBurned(address(this), sharesToTransfer);
        vm.expectEmit(true, false, false, true);
        emit StvStETHPool.StethSharesMinted(userAlice, sharesToTransfer);

        bool success = pool.transferWithLiability(userAlice, stvToTransfer, sharesToTransfer);
        assertTrue(success);

        assertEq(pool.mintedStethSharesOf(address(this)), 0);
        assertEq(pool.mintedStethSharesOf(userAlice), sharesToTransfer);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.balanceOf(userAlice), stvToTransfer);
    }

    function test_TransferWithLiability_RevertsWhenNoLiability() public {
        vm.expectRevert(StvStETHPool.ZeroArgument.selector);
        pool.transferWithLiability(userAlice, 100000, 0);
    }

    function test_TransferWithLiability_RevertsWhenStvInsufficient() public {
        uint256 sharesToTransfer = pool.remainingMintingCapacitySharesOf(address(this), 0) / 2;
        pool.mintStethShares(sharesToTransfer);

        uint256 minStv = pool.calcStvToLockForStethShares(sharesToTransfer);
        assertGt(minStv, 0);
        uint256 insufficientStv = minStv - 1;

        vm.expectRevert(StvStETHPool.InsufficientStv.selector);
        pool.transferWithLiability(userAlice, insufficientStv, sharesToTransfer);
    }

    function test_TransferWithLiability_RevertsWhenSharesExceedLiability() public {
        uint256 mintedShares = pool.remainingMintingCapacitySharesOf(address(this), 0) / 4;
        pool.mintStethShares(mintedShares);

        uint256 mintedRecorded = pool.mintedStethSharesOf(address(this));
        assertEq(mintedRecorded, mintedShares);

        uint256 stvBalance = pool.balanceOf(address(this));

        vm.expectRevert(StvStETHPool.InsufficientMintedShares.selector);
        pool.transferWithLiability(userAlice, stvBalance, mintedRecorded + 1);
    }

    function test_TransferWithLiability_RevertsWhenZeroStvButHasShares() public {
        uint256 sharesToTransfer = pool.remainingMintingCapacitySharesOf(address(this), 0) / 5;
        pool.mintStethShares(sharesToTransfer);

        vm.expectRevert(StvStETHPool.InsufficientStv.selector);
        pool.transferWithLiability(userAlice, 0, sharesToTransfer);
    }
}
