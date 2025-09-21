// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperBHarness} from "test/utils/WrapperBHarness.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperC} from "src/WrapperC.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperCHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperC (minting with strategy)
 */
contract WrapperCHarness is WrapperBHarness {

    IStrategy public strategy;

    function _deployWrapperC(
        bool enableAllowlist,
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
            upgradeConformer: NODE_OPERATOR,
            nodeOperatorFeeBP: NODE_OPERATOR_FEE_RATE,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
            teller: _teller,
            boringQueue: _boringQueue
        });

        WrapperContext memory ctx = _deployWrapperSystem(config);
        WrapperC wrapperC_ = WrapperC(payable(address(ctx.wrapper)));

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

        // WrapperC specific: has strategy checks
        if (address(strategy) != address(0)) {
            assertEq(address(wrapperC(ctx).STRATEGY()), address(strategy), "Strategy should be set correctly");
            // Additional strategy-specific initial state checks can go here
        }
    }

    function _assertUniversalInvariants(string memory _context, WrapperContext memory _ctx) internal virtual override {
        // Call parent invariants
        super._assertUniversalInvariants(_context, _ctx);

        // WrapperC specific: strategy-related invariants
        if (address(strategy) != address(0)) {
            // Add strategy-specific invariants here if needed
            // For example, checking strategy positions, health factors, etc.
        }
    }

    // Helper function to access WrapperC-specific functionality from context
    function wrapperC(WrapperContext memory ctx) internal pure returns (WrapperC) {
        return WrapperC(payable(address(ctx.wrapper)));
    }
}