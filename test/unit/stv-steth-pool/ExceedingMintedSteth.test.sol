// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupStvStETHPool} from "./SetupStvStETHPool.sol";

contract ExceedingMintedStethTest is Test, SetupStvStETHPool {
    uint8 supplyDecimals = 27;
    uint256 initialMintedStethShares = 1 * 10 ** 18;

    function setUp() public override {
        super.setUp();

        pool.depositETH{value: 3 ether}(address(this), address(0));
        pool.mintStethShares(initialMintedStethShares);
    }

    function test_InitialState_CorrectMintedStethShares() public view {
        assertEq(pool.totalMintedStethShares(), initialMintedStethShares);
        assertEq(pool.totalExceedingMintedStethShares(), 0);
        assertEq(pool.totalExceedingMintedSteth(), 0);
    }

    function test_Rebalance_IncreaseExceedingMintedSteth() public {
        uint256 sharesToRebalance = initialMintedStethShares;

        dashboard.rebalanceVaultWithShares(sharesToRebalance);
        assertEq(pool.totalExceedingMintedStethShares(), sharesToRebalance);
    }
}
