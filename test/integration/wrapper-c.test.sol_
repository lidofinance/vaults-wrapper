// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperCHarness} from "test/utils/WrapperCHarness.sol";
import {WrapperA} from "src/WrapperA.sol";
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
        _initializeCore();
    }

    function test_initial_state() public {
        // Deploy wrapper system with minting and strategy enabled
        // Let the Factory create the strategy internally by passing address(0)
        WrapperContext memory ctx = _deployWrapperC(false, address(0), 0);

        _checkInitialState(ctx);

//        assertEq(strategy.LOOPS(), 1, "Strategy loops is expected to be 1");
        assertEq(address(wrapperC(ctx).STRATEGY()), address(strategy), "Strategy should be set correctly on wrapper");
    }

    function xtest_happy_path_single_user_single_deposit() public {
        // Deploy wrapper system with minting and strategy enabled
        WrapperContext memory ctx = _deployWrapperC(false, address(0), 0);

        uint256 user1Deposit = 10_000 wei;
        vm.prank(USER1);
        ctx.wrapper.depositETH{value: user1Deposit}(USER1);

        _assertUniversalInvariants("Step 1", ctx);

        // Verify basic deposit functionality
        // assertEq(ctx.wrapper.balanceOf(address(ctx.wrapper.strategy())), user1Deposit * EXTRA_BASE, "User1 should have received stvToken shares");
    }

    function xtest_happy_path_with_strategy() public {
        // Deploy wrapper system with minting and strategy enabled
        WrapperContext memory ctx = _deployWrapperC(false, address(0), 0);

        uint256 user1Deposit = 10_000 wei;
        vm.prank(USER1);
        wrapperC(ctx).depositETH{value: user1Deposit}(USER1, address(strategy));

        _assertUniversalInvariants("Step 1", ctx);

        // Verify that strategy integration works
        assertEq(ctx.wrapper.balanceOf(USER1), user1Deposit * EXTRA_BASE, "User1 should have received stvToken shares");
        assertEq(address(wrapperC(ctx).STRATEGY()), address(strategy), "Strategy should be properly set");

        // Check strategy state if it was executed
        // Note: The actual strategy execution depends on the WrapperC implementation
        // This test verifies the basic integration without executing the strategy
    }

    // TODO: add after report invariants
    // TODO: add after deposit invariants
    // TODO: add after requestWithdrawal invariants
    // TODO: add after finalizeWithdrawal invariants
    // TODO: add after claimWithdrawal invariants
    // TODO: add strategy execution tests
    // TODO: add strategy exit tests

}