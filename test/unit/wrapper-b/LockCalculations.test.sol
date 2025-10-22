// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SetupWrapperB} from "./SetupWrapperB.sol";

contract LockCalculationsTest is Test, SetupWrapperB {
    function setUp() public override {
        super.setUp();
        wrapper.depositETH{value: 10 ether}();
    }

    function test_CalcAssetsToLockForStethShares_Zero() public view {
        assertEq(wrapper.calcAssetsToLockForStethShares(0), 0);
    }

    function test_CalcStvToLockForStethShares_Zero() public view {
        assertEq(wrapper.calcStvToLockForStethShares(0), 0);
    }

    function test_CalcStethSharesToMintForStv_Zero() public view {
        assertEq(wrapper.calcStethSharesToMintForStv(0), 0);
    }

    function test_CalcStethSharesToMintForAssets_Zero() public view {
        assertEq(wrapper.calcStethSharesToMintForAssets(0), 0);
    }

    function test_CalcAssetsToLockForStethShares_Calculation() public view {
        uint256 shares = 1e18;

        uint256 steth = steth.getPooledEthBySharesRoundUp(shares); // rounds up
        uint256 expectedAssets = Math.mulDiv(
            steth,
            wrapper.TOTAL_BASIS_POINTS(),
            wrapper.TOTAL_BASIS_POINTS() - wrapper.reserveRatioBP(),
            Math.Rounding.Ceil // rounds up
        );

        assertEq(wrapper.calcAssetsToLockForStethShares(shares), expectedAssets);
    }

    function test_CalcStvToLockForStethShares_Calculation() public view {
        uint256 shares = 1e18;

        uint256 steth = steth.getPooledEthBySharesRoundUp(shares); // rounds up
        uint256 expectedAssets = Math.mulDiv(
            steth,
            wrapper.TOTAL_BASIS_POINTS(),
            wrapper.TOTAL_BASIS_POINTS() - wrapper.reserveRatioBP(),
            Math.Rounding.Ceil // rounds up
        );
        uint256 expectedStv = Math.mulDiv(
            expectedAssets,
            wrapper.totalSupply(),
            wrapper.totalAssets(),
            Math.Rounding.Ceil // rounds up
        );

        assertEq(wrapper.calcStvToLockForStethShares(shares), expectedStv);
    }

    function test_CalcStethSharesToMintForStv_Calculation() public view {
        uint256 stv = 1e27;

        uint256 assets = Math.mulDiv(stv, wrapper.totalAssets(), wrapper.totalSupply(), Math.Rounding.Floor);
        uint256 maxStethToMint = Math.mulDiv(
            assets,
            wrapper.TOTAL_BASIS_POINTS() - wrapper.reserveRatioBP(),
            wrapper.TOTAL_BASIS_POINTS(),
            Math.Rounding.Floor // rounds down
        );
        uint256 expectedStethShares = steth.getSharesByPooledEth(maxStethToMint); // rounds down

        assertEq(wrapper.calcStethSharesToMintForStv(stv), expectedStethShares);
    }

    function test_CalcStethSharesToMintForAssets_Calculation() public view {
        uint256 assets = 1e18;

        uint256 maxStethToMint = Math.mulDiv(
            assets,
            wrapper.TOTAL_BASIS_POINTS() - wrapper.reserveRatioBP(),
            wrapper.TOTAL_BASIS_POINTS(),
            Math.Rounding.Floor // rounds down
        );
        uint256 expectedStethShares = steth.getSharesByPooledEth(maxStethToMint); // rounds down

        assertEq(wrapper.calcStethSharesToMintForAssets(assets), expectedStethShares);
    }
}
