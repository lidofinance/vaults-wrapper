// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperBHarness} from "test/utils/WrapperBHarness.sol";
import {WrapperC} from "src/WrapperC.sol";
import {ExampleLoopStrategy} from "src/strategy/ExampleLoopStrategy.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperCHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperC (minting with strategy)
 */
contract WrapperCHarness is WrapperBHarness {

    ExampleLoopStrategy public strategy;

    function _setUp(
        Factory.WrapperConfiguration configuration,
        address strategy_,
        bool enableAllowlist
    ) internal virtual override {
        // Call parent setUp
        super._setUp(configuration, strategy_, enableAllowlist);

        // Get the strategy address if it was created by the factory
        if (strategy_ == address(0) && configuration == Factory.WrapperConfiguration.MINTING_AND_STRATEGY) {
            // Strategy was created by factory, get it from the wrapper
            WrapperC wrapperC_ = WrapperC(payable(address(wrapper)));
            strategy = ExampleLoopStrategy(payable(address(wrapperC_.STRATEGY())));
        } else {
            strategy = ExampleLoopStrategy(payable(strategy_));
        }
    }

    // Helper function to get wrapper as WrapperC
    function wrapperC() internal view returns (WrapperC) {
        return WrapperC(payable(address(wrapper)));
    }

    function _checkInitialState() internal virtual override {
        // Call parent checks first
        super._checkInitialState();

        // WrapperC specific: has strategy checks
        if (address(strategy) != address(0)) {
            assertEq(address(wrapperC().STRATEGY()), address(strategy), "Strategy should be set correctly");
            // Additional strategy-specific initial state checks can go here
        }
    }

    function _assertUniversalInvariants(string memory _context) internal virtual override {
        // Call parent invariants
        super._assertUniversalInvariants(_context);

        // WrapperC specific: strategy-related invariants
        if (address(strategy) != address(0)) {
            // Add strategy-specific invariants here if needed
            // For example, checking strategy positions, health factors, etc.
        }
    }
}