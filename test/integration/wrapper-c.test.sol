// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperCHarness} from "test/utils/WrapperCHarness.sol";
import {WrapperC} from "src/WrapperC.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {LoopStrategy} from "src/strategy/LoopStrategy.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperCTest
 * @notice Integration tests for WrapperC (minting with strategy)
 */
contract WrapperCTest is WrapperCHarness {

    function setUp() public {
        // Let the Factory create the strategy internally by passing address(0)
        _setUp(Factory.WrapperConfiguration.MINTING_AND_STRATEGY, address(0), false);
        _checkInitialState();

        assertEq(strategy.LOOPS(), 1, "Strategy loops is expected to be 1");
    }

    // TODO: add after report invariants
    // TODO: add after deposit invariants
    // TODO: add after requestWithdrawal invariants
    // TODO: add after finalizeWithdrawal invariants
    // TODO: add after claimWithdrawal invariants
    // TODO: add strategy execution tests
    // TODO: add strategy exit tests


    function test_happy_path_single_user_single_deposit() public {
        uint256 user1Deposit = 10_000 wei;
        vm.prank(USER1);
        wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 1");

    }

}