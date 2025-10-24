// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {StvStETHPoolHarness} from "test/utils/StvStETHPoolHarness.sol";
import {StvStrategyPool} from "src/StvStrategyPool.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title StvStrategyPoolHarness
 * @notice Helper contract for integration tests that provides common setup for StvStrategyPool (minting with strategy)
 */
contract StvStrategyPoolHarness is StvStETHPoolHarness {
    IStrategy public strategy;

    function _deployStvStrategyPool(
        bool enableAllowlist,
        uint256 nodeOperatorFeeBP,
        address strategy_,
        uint256 reserveRatioGapBP,
        address _teller,
        address _boringQueue
    ) internal returns (WrapperContext memory) {
        DeploymentConfig memory config = DeploymentConfig({
            configuration: Factory.WrapperType.GGV_STRATEGY,
            strategy: strategy_,
            enableAllowlist: enableAllowlist,
            reserveRatioGapBP: reserveRatioGapBP,
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            nodeOperatorFeeBP: nodeOperatorFeeBP,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
            minWithdrawalDelayTime: 1 days,
            teller: _teller,
            boringQueue: _boringQueue,
            timelockExecutor: address(0)
        });

        WrapperContext memory ctx = _deployWrapperSystem(config);

        strategy = IStrategy(payable(strategy_));

        return ctx;
    }

    function _allPossibleStvHolders(WrapperContext memory ctx) internal view override returns (address[] memory) {
        address[] memory holders_ = super._allPossibleStvHolders(ctx);
        address[] memory holders = new address[](holders_.length + 2);
        uint256 i = 0;
        for (i = 0; i < holders_.length; i++) {
            holders[i] = holders_[i];
        }
        holders[i++] = address(strategy);
        //        holders[i++] = address(strategy.LENDER_MOCK());
        return holders;
    }

    function _checkInitialState(WrapperContext memory ctx) internal virtual override {
        // Call parent checks first
        super._checkInitialState(ctx);

        // StvStrategyPool specific: has strategy checks
        if (address(strategy) != address(0)) {
            assertEq(address(stvStrategyPool(ctx).STRATEGY()), address(strategy), "Strategy should be set correctly");
            // Additional strategy-specific initial state checks can go here
        }
    }

    function _assertUniversalInvariants(string memory _context, WrapperContext memory _ctx) internal virtual override {
        // Call parent invariants
        super._assertUniversalInvariants(_context, _ctx);

        // StvStrategyPool specific: strategy-related invariants
        if (address(strategy) != address(0)) {
            // Add strategy-specific invariants here if needed
            // For example, checking strategy positions, health factors, etc.
        }
    }

    // Helper function to access StvStrategyPool-specific functionality from context
    function stvStrategyPool(WrapperContext memory ctx) internal pure returns (StvStrategyPool) {
        return StvStrategyPool(payable(address(ctx.pool)));
    }
}
