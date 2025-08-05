// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {DefiWrapper} from "test/utils/DefiWrapper.sol";


contract WrapperCreationTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core));
    }

    // Tests the initial state of the wrapper system after deployment
    // Verifies proper setup of total supply, assets, balances, and vault connection
    function test_initialState() public view {
        assertEq(dw.wrapper().totalSupply(), dw.CONNECT_DEPOSIT(), "wrapper totalSupply should be equal to CONNECT_DEPOSIT");
        assertEq(dw.wrapper().totalAssets(), dw.CONNECT_DEPOSIT(), "wrapper totalAssets should be equal to CONNECT_DEPOSIT");
        assertEq(dw.wrapper().balanceOf(address(dw.escrow())), 0, "escrow should have no shares initially");
        assertEq(dw.wrapper().balanceOf(address(dw.withdrawalQueue())), 0, "withdrawalQueue should have no shares initially");
        assertEq(dw.wrapper().balanceOf(address(dw)), dw.CONNECT_DEPOSIT(), "DefiWrapper should initially hold CONNECT_DEPOSIT shares");
        assertEq(address(dw.stakingVault()).balance, dw.CONNECT_DEPOSIT(), "Vault balance should equal CONNECT_DEPOSIT at start");
    }

}