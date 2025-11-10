// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {SetupStvPool} from "./SetupStvPool.sol";
import {Test} from "forge-std/Test.sol";
import {StvPool} from "src/StvPool.sol";

contract BadDebtTest is Test, SetupStvPool {
    function _simulateBadDebt() internal {
        // Deposit some ETH
        pool.depositETH{value: 10 ether}(address(this), address(0));

        // Simulate liability transfer
        dashboard.mock_increaseLiability(steth.getSharesByPooledEth(10 ether));

        // Simulate negative rewards to create bad debt
        dashboard.mock_simulateRewards(int256(-2 ether));

        _assertBadDebt();
    }

    function _getValueAndLiabilityShares() internal view returns (uint256 valueShares, uint256 liabilityShares) {
        valueShares = steth.getSharesByPooledEth(vaultHub.totalValue(address(pool.STAKING_VAULT())));
        liabilityShares = pool.totalLiabilityShares();
    }

    function _assertBadDebt() internal view {
        (uint256 valueShares, uint256 liabilityShares) = _getValueAndLiabilityShares();
        assertLt(valueShares, liabilityShares);
    }

    function _assertNoBadDebt() internal view {
        (uint256 valueShares, uint256 liabilityShares) = _getValueAndLiabilityShares();
        assertGe(valueShares, liabilityShares);
    }

    // Initial state tests

    function test_InitialState_NoBadDebt() public view {
        _assertNoBadDebt();
    }

    // Bad debt tests

    function test_BadDebt_TransfersNotAllowed() public {
        _simulateBadDebt();

        vm.expectRevert(StvPool.VaultInBadDebt.selector);
        pool.transfer(address(1), 1 ether);
    }

    function test_BadDebt_DepositsNotAllowed() public {
        _simulateBadDebt();

        vm.expectRevert(StvPool.VaultInBadDebt.selector);
        pool.depositETH{value: 1 ether}(address(this), address(0));
    }
}
