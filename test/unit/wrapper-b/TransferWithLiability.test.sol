// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SetupWrapperB} from "./SetupWrapperB.sol";
import {WrapperB} from "src/WrapperB.sol";

contract TransferWithLiabilityTest is Test, SetupWrapperB {
    function setUp() public override {
        super.setUp();
        wrapper.depositETH{value: 20 ether}();
    }

    function test_TransferWithLiability_TransfersDebtAndStv() public {
        uint256 sharesToTransfer = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToTransfer);

        uint256 stvToTransfer = wrapper.balanceOf(address(this));

        vm.expectEmit(true, false, false, true);
        emit WrapperB.StethSharesBurned(address(this), sharesToTransfer);
        vm.expectEmit(true, false, false, true);
        emit WrapperB.StethSharesMinted(userAlice, sharesToTransfer);

        bool success = wrapper.transferWithLiability(userAlice, stvToTransfer, sharesToTransfer);
        assertTrue(success);

        assertEq(wrapper.mintedStethSharesOf(address(this)), 0);
        assertEq(wrapper.mintedStethSharesOf(userAlice), sharesToTransfer);
        assertEq(wrapper.balanceOf(address(this)), 0);
        assertEq(wrapper.balanceOf(userAlice), stvToTransfer);
    }

    function test_TransferWithLiability_RevertsWhenNoLiability() public {
        vm.expectRevert(WrapperB.ZeroArgument.selector);
        wrapper.transferWithLiability(userAlice, 100000, 0);
    }

    function test_TransferWithLiability_RevertsWhenStvInsufficient() public {
        uint256 sharesToTransfer = wrapper.mintingCapacitySharesOf(address(this)) / 2;
        wrapper.mintStethShares(sharesToTransfer);

        uint256 minStv = wrapper.calcStvToLockForStethShares(sharesToTransfer);
        assertGt(minStv, 0);
        uint256 insufficientStv = minStv - 1;

        vm.expectRevert(WrapperB.InsufficientStv.selector);
        wrapper.transferWithLiability(userAlice, insufficientStv, sharesToTransfer);
    }

    function test_TransferWithLiability_RevertsWhenSharesExceedLiability() public {
        uint256 mintedShares = wrapper.mintingCapacitySharesOf(address(this)) / 4;
        wrapper.mintStethShares(mintedShares);

        uint256 mintedRecorded = wrapper.mintedStethSharesOf(address(this));
        assertEq(mintedRecorded, mintedShares);

        uint256 stvBalance = wrapper.balanceOf(address(this));

        vm.expectRevert(WrapperB.InsufficientMintedShares.selector);
        wrapper.transferWithLiability(userAlice, stvBalance, mintedRecorded + 1);
    }

    function test_TransferWithLiability_RevertsWhenZeroStvButHasShares() public {
        uint256 sharesToTransfer = wrapper.mintingCapacitySharesOf(address(this)) / 5;
        wrapper.mintStethShares(sharesToTransfer);

        vm.expectRevert(WrapperB.InsufficientStv.selector);
        wrapper.transferWithLiability(userAlice, 0, sharesToTransfer);
    }
}
