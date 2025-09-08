// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperBHarness} from "test/utils/WrapperBHarness.sol";
import {WrapperC} from "src/WrapperC.sol";
import {LoopStrategy} from "src/strategy/LoopStrategy.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperCHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperC (minting with strategy)
 */
contract WrapperCHarness is WrapperBHarness {

    LoopStrategy public strategy;

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
            strategy = LoopStrategy(payable(address(wrapperC_.STRATEGY())));

        } else {
            strategy = LoopStrategy(payable(strategy_));
        }
        vm.deal(address(strategy.LENDER_MOCK()), 1000 ether);
    }

    function _allPossibleStvHolders() internal view override returns (address[] memory) {
        address[] memory holders_ = super._allPossibleStvHolders();
        address[] memory holders = new address[](holders_.length + 1);
        for (uint256 i = 0; i < holders_.length; i++) {
            holders[i] = holders_[i];
        }
        holders[holders_.length] = address(strategy);
        return holders;
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