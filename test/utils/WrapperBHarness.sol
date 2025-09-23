// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperAHarness} from "test/utils/WrapperAHarness.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperB} from "src/WrapperB.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {Factory} from "src/Factory.sol";
import {FactoryHelper} from "test/utils/FactoryHelper.sol";

/**
 * @title WrapperBHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperB (minting, no strategy)
 */
contract WrapperBHarness is WrapperAHarness {

    function _deployWrapperB(
        bool enableAllowlist,
        uint256 reserveRatioGapBP
    ) internal returns (WrapperContext memory) {
        // If WRAPPER_DEPLOYED_JSON is provided, use pre-deployed addresses instead of deploying
        string memory deployedPath = "";
        try vm.envString("WRAPPER_DEPLOYED_JSON") returns (string memory p) {
            deployedPath = p;
        } catch {}

        if (bytes(deployedPath).length != 0) {
            string memory json = vm.readFile(deployedPath);
            address wrapperAddress = vm.parseJsonAddress(json, "$.wrapperProxy");
            address withdrawalQueueAddress = vm.parseJsonAddress(json, "$.withdrawalQueue");
            address dashboardAddress = vm.parseJsonAddress(json, "$.dashboard");
            address vaultAddress = vm.parseJsonAddress(json, "$.vault");

            // Inform core harness about the dashboard used by this wrapper
            core.setDashboard(dashboardAddress);

            return WrapperContext({
                wrapper: WrapperA(payable(wrapperAddress)),
                withdrawalQueue: WithdrawalQueue(payable(withdrawalQueueAddress)),
                dashboard: IDashboard(payable(dashboardAddress)),
                vault: IStakingVault(vaultAddress)
            });
        }

        DeploymentConfig memory config = DeploymentConfig({
            configuration: Factory.WrapperType.MINTING_NO_STRATEGY,
            strategy: address(0),
            enableAllowlist: enableAllowlist,
            reserveRatioGapBP: reserveRatioGapBP,
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            upgradeConformer: NODE_OPERATOR,
            nodeOperatorFeeBP: NODE_OPERATOR_FEE_RATE,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
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

        {   // Check none can mint beyond mintableStShares
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 mintableStShares = wrapperB(_ctx).mintableStethShares(holder);

                vm.startPrank(holder);
                vm.expectRevert("InsufficientMintableStShares()");
                wrapperB(_ctx).mintStethShares(mintableStShares + 1);
                vm.stopPrank();
            }
        }
    }

    // Helper function to access WrapperB-specific functionality from context
    function wrapperB(WrapperContext memory ctx) internal pure returns (WrapperB) {
        return WrapperB(payable(address(ctx.wrapper)));
    }
}