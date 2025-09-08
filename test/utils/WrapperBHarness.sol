// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperAHarness} from "test/utils/WrapperAHarness.sol";
import {WrapperB} from "src/WrapperB.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperBHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperB (minting, no strategy)
 */
contract WrapperBHarness is WrapperAHarness {

    function _setUp(
        Factory.WrapperConfiguration configuration,
        address strategy,
        bool enableAllowlist
    ) internal virtual override {
        // Call parent setUp
        super._setUp(configuration, strategy, enableAllowlist);
    }

    // Helper function to get wrapper as WrapperB
    function wrapperB() internal view returns (WrapperB) {
        return WrapperB(payable(address(wrapper)));
    }

    function _checkInitialState() internal virtual override {
        // Call parent checks first
        super._checkInitialState();

        // WrapperB specific: has minting capacity
        // Note: Cannot check mintableStShares for users with no deposits as it would cause underflow
        // Minting capacity checks are performed in individual tests after deposits are made
    }

    function _assertUniversalInvariants(string memory _context) internal virtual override {
        // Call parent invariants
        super._assertUniversalInvariants(_context);

        // WrapperB specific: check minting invariants
        address[] memory holders = new address[](5);
        holders[0] = USER1;
        holders[1] = USER2;
        holders[2] = USER3;
        holders[3] = address(wrapper);
        holders[4] = address(withdrawalQueue);

        {   // Check none can mint beyond mintableStShares
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 mintableStShares = wrapperB().mintableStShares(holder);
                vm.startPrank(holder);
                vm.expectRevert("InsufficientMintableStShares()");
                wrapperB().mintStShares(mintableStShares + 1);
                vm.stopPrank();
            }
        }
    }
}