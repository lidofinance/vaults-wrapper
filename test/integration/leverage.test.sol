// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {WrapperCHarness} from "test/utils/WrapperCHarness.sol";
import {LeverageStrategy} from "src/strategy/LeverageStrategy.sol";
import {WrapperC} from "src/WrapperC.sol";

contract WrapperCTest is WrapperCHarness {

    WrapperC public wrapper;

    function setUp() public {
        _initializeCore();

        strategy = new LeverageStrategy(address(core.steth()), 1);

        WrapperContext memory ctx = _deployWrapperC(false, address(strategy), 0);
        wrapper = wrapperC(ctx);

        assertEq(address(wrapperC(ctx).STRATEGY()), address(strategy), "Strategy should be set correctly on wrapper");
    }

    function test_deposit() public {


    }

}