// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";

contract ExceedingMintedStethTest is Test, SetupWrapperB {
    uint8 supplyDecimals = 27;
    uint256 initialMintedStethShares = 1 * 10 ** 18;

    function setUp() public override {
        super.setUp();

        wrapper.depositETH{value: 3 ether}();
        wrapper.mintStethShares(initialMintedStethShares);
    }

    function test_InitialState_CorrectMintedStethShares() public view {
        assertEq(wrapper.totalMintedStethShares(), initialMintedStethShares);
        assertEq(wrapper.totalExceedingMintedStethShares(), 0);
        assertEq(wrapper.totalExceedingMintedSteth(), 0);
    }

    function test_Rebalance_IncreaseExceedingMintedSteth() public {
        uint256 sharesToRebalance = initialMintedStethShares;

        dashboard.rebalanceVaultWithShares(sharesToRebalance);
        assertEq(wrapper.totalExceedingMintedStethShares(), sharesToRebalance);
    }
}
