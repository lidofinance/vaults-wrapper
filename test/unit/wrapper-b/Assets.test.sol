// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";

import {MockVaultHub} from "../../mocks/MockVaultHub.sol";

contract AssetsTest is Test, SetupWrapperB {
    uint8 supplyDecimals = 27;

    function test_InitialState_CorrectAssets() public view {
        assertEq(wrapper.totalAssets(), initialDeposit);
        assertEq(wrapper.totalNominalAssets(), initialDeposit);

        assertEq(wrapper.nominalAssetsOf(address(wrapper)), initialDeposit);
        assertEq(wrapper.assetsOf(address(wrapper)), initialDeposit);
    }

    function test_Deposit_IncreasesAssets() public {
        uint256 ethToDeposit = 1 ether;
        uint256 assetsBefore = wrapper.totalAssets();

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.totalAssets(), assetsBefore + ethToDeposit);
    }

    function test_Deposit_IncreasesUserAssets() public {
        uint256 ethToDeposit = 1 ether;
        uint256 assetsBefore = wrapper.assetsOf(userAlice);

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.assetsOf(userAlice), assetsBefore + ethToDeposit);
    }

    function test_Rebalance_DoNotChangeUserAssets() public {
        wrapper.depositETH{value: 4 ether}();
        wrapper.mintStethShares(1 * 10 ** 18);

        uint256 assetsBefore = wrapper.assetsOf(address(this));

        dashboard.rebalanceVaultWithShares(1 * 10 ** 18);

        assertEq(wrapper.assetsOf(address(this)), assetsBefore);
        assertLt(wrapper.nominalAssetsOf(address(this)), assetsBefore);
        assertGt(wrapper.exceedingMintedStethOf(address(this)), 0);
    }
}


