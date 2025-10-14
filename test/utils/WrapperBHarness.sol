// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {WrapperAHarness} from "test/utils/WrapperAHarness.sol";
import {WrapperB} from "src/WrapperB.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperBHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperB (minting, no strategy)
 */
contract WrapperBHarness is WrapperAHarness {
    function _deployWrapperB(bool enableAllowlist, uint256 nodeOperatorFeeBP, uint256 reserveRatioGapBP)
        internal
        returns (WrapperContext memory)
    {
        DeploymentConfig memory config = DeploymentConfig({
            configuration: Factory.WrapperType.MINTING_NO_STRATEGY,
            strategy: address(0),
            enableAllowlist: enableAllowlist,
            reserveRatioGapBP: reserveRatioGapBP,
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            upgradeConformer: NODE_OPERATOR,
            nodeOperatorFeeBP: nodeOperatorFeeBP,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
            minWithdrawalDelayTime: 1 days,
            teller: address(0),
            boringQueue: address(0)
        });

        WrapperContext memory context = _deployWrapperSystem(config);

        return context;
    }

    function _checkInitialState(WrapperContext memory ctx) internal virtual override {
        // Call parent checks first
        super._checkInitialState(ctx);

        // WrapperB specific: has minting capacity
        // Note: Cannot check mintableStShares for users with no deposits as it would cause underflow
        // Minting capacity checks are performed in individual tests after deposits are made
    }

    function _assertUniversalInvariants(string memory _context, WrapperContext memory _ctx) internal virtual override {
        // Call parent invariants
        super._assertUniversalInvariants(_context, _ctx);

        // TODO: check minting capacity of wrapper which owns connect deposit stv shares

        address[] memory holders = _allPossibleStvHolders(_ctx);

        {
            // Check none can mint beyond mintable capacity
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 mintableStShares = wrapperB(_ctx).mintableStethShares(holder);

                vm.startPrank(holder);
                vm.expectRevert(WrapperB.InsufficientMintingCapacity.selector);
                wrapperB(_ctx).mintStethShares(mintableStShares + 1);
                vm.stopPrank();
            }
        }
    }

    // Helper function to access WrapperB-specific functionality from context
    function wrapperB(WrapperContext memory ctx) internal pure returns (WrapperB) {
        return WrapperB(payable(address(ctx.wrapper)));
    }

    /**
     * @notice Calculate max mintable stETH shares for a given ETH amount
     * @dev Uses WRAPPER_RR_BP from WrapperB which includes the wrapper gap
     */
    function _calcMaxMintableStShares(WrapperContext memory ctx, uint256 _eth) public view returns (uint256) {
        uint256 wrapperRrBp = wrapperB(ctx).WRAPPER_RR_BP();
        return steth.getSharesByPooledEth(_eth * (TOTAL_BASIS_POINTS - wrapperRrBp) / TOTAL_BASIS_POINTS);
    }
}
