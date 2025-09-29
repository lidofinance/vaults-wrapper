// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {SetupWrapperB} from "./SetupWrapperB.sol";

import {MockVaultHub} from "../../mocks/MockVaultHub.sol";

contract EffectiveAssetsTest is Test, SetupWrapperB {
    uint8 supplyDecimals = 27;

    function test_InitialState_CorrectAssets() public view {
        assertEq(wrapper.totalAssets(), initialDeposit);
        assertEq(wrapper.totalEffectiveAssets(), initialDeposit);

        assertEq(wrapper.assetsOf(address(wrapper)), initialDeposit);
        assertEq(wrapper.effectiveAssetsOf(address(wrapper)), initialDeposit);
    }

    function test_Deposit_IncreasesEffectiveAssets() public {
        uint256 ethToDeposit = 1 ether;
        uint256 assetsBefore = wrapper.totalEffectiveAssets();

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.totalEffectiveAssets(), assetsBefore + ethToDeposit);
    }

    function test_Deposit_IncreasesUserEffectiveAssets() public {
        uint256 ethToDeposit = 1 ether;
        uint256 assetsBefore = wrapper.effectiveAssetsOf(userAlice);

        vm.prank(userAlice);
        wrapper.depositETH{value: ethToDeposit}(userAlice, address(0));

        assertEq(wrapper.effectiveAssetsOf(userAlice), assetsBefore + ethToDeposit);
    }

    function test_Rebalance_DoNotChangeUserEffectiveAssets() public {
        wrapper.depositETH{value: 4 ether}();
        wrapper.mintStethShares(1 * 10 ** 18);

        uint256 assetsBefore = wrapper.effectiveAssetsOf(address(this));

        dashboard.rebalanceVaultWithShares(1 * 10 ** 18);

        assertEq(wrapper.effectiveAssetsOf(address(this)), assetsBefore);
        assertLt(wrapper.assetsOf(address(this)), assetsBefore);
        assertGt(wrapper.exceedingMintedStethOf(address(this)), 0);
    }
}
