// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperA} from "./SetupWrapperA.sol";

contract StvTest is Test, SetupWrapperA {
    uint8 supplyDecimals = 27;

    function test_InitialState_CorrectSupplyAndAssets() public view {
        assertEq(wrapper.totalAssets(), initialDeposit);
        assertEq(wrapper.totalSupply(), 10 ** supplyDecimals);

        assertEq(wrapper.nominalAssetsOf(address(wrapper)), initialDeposit);
        assertEq(wrapper.balanceOf(address(wrapper)), 10 ** supplyDecimals);
    }

    // deposit tests

    function test_Deposit_IncreasesTotalSupply() public {
        uint256 ethToDeposit = 1 ether;
        uint256 supplyBefore = wrapper.totalSupply();

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.totalSupply(), supplyBefore + 10 ** supplyDecimals);
    }

    function test_Deposit_IncreasesTotalAssets() public {
        uint256 ethToDeposit = 1 ether;
        uint256 assetsBefore = wrapper.totalAssets();

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.totalAssets(), assetsBefore + ethToDeposit);
    }

    function test_Deposit_IncreasesUserBalance() public {
        uint256 ethToDeposit = 1 ether;
        uint256 userBalanceBefore = wrapper.balanceOf(userAlice);

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.balanceOf(userAlice), userBalanceBefore + 10 ** supplyDecimals);
    }

    function test_Deposit_IncreasesUserAssets() public {
        uint256 ethToDeposit = 1 ether;

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        uint256 aliceBalanceE27 = wrapper.balanceOf(address(wrapper));

        assertEq(aliceBalanceE27, 10 ** supplyDecimals);
        assertEq(wrapper.previewRedeem(aliceBalanceE27), ethToDeposit);
    }

    // rewards

    function test_Rewards_IncreasesTotalAssets() public {
        uint256 rewards = 1 ether;
        uint256 totalAssetsBefore = wrapper.totalAssets();
        dashboard.mock_simulateRewards(int256(rewards));

        assertEq(wrapper.totalAssets(), totalAssetsBefore + rewards);
    }

    function test_Rewards_DistributedAmongUsers() public {
        wrapper.depositETH{value: 1 ether}(userAlice, address(0));
        wrapper.depositETH{value: 2 ether}(userBob, address(0));

        uint256 rewards = 333;
        dashboard.mock_simulateRewards(int256(rewards));

        assertEq(wrapper.nominalAssetsOf(address(wrapper)), 1 ether + (rewards / 4));
        assertEq(wrapper.nominalAssetsOf(userAlice), 1 ether + (rewards / 4));
        assertEq(wrapper.nominalAssetsOf(userBob), 2 ether + (rewards / 2));
    }
}
