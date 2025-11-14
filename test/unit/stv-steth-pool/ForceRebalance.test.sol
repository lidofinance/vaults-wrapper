// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SetupStvStETHPool} from "./SetupStvStETHPool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";

contract ForceRebalanceTest is Test, SetupStvStETHPool {
    uint256 internal constant DEPOSIT_AMOUNT = 20 ether;
    address socializer;

    function setUp() public override {
        super.setUp();

        vm.prank(userAlice);
        pool.depositETH{value: DEPOSIT_AMOUNT}(userAlice, address(0));

        socializer = makeAddr("socializer");

        bytes32 ROLE_SOCIALIZER = pool.LOSS_SOCIALIZER_ROLE();
        vm.prank(owner);
        pool.grantRole(ROLE_SOCIALIZER, socializer);
    }

    function _mintMaxStethShares(address _account) internal {
        uint256 capacity = pool.remainingMintingCapacitySharesOf(_account, 0);
        assertGt(capacity, 0, "expected positive minting capacity");

        vm.prank(_account);
        pool.mintStethShares(capacity);
    }

    function _simulateLoss(uint256 _loss) internal {
        assertLe(_loss, uint256(type(int256).max), "loss exceeds int256 max");
        dashboard.mock_simulateRewards(-int256(_loss));
    }

    function _calcLossToBreachThreshold(address _account) internal view returns (uint256 lossToBreachThreshold) {
        uint256 mintedSteth = steth.getPooledEthByShares(pool.mintedStethSharesOf(_account));
        uint256 assets = pool.assetsOf(_account);
        uint256 threshold = pool.forcedRebalanceThresholdBP();

        // liability / (assets - x) = (1 - threshold)
        // x = assets - liability / (1 - threshold)
        lossToBreachThreshold =
            assets - (mintedSteth * pool.TOTAL_BASIS_POINTS()) / (pool.TOTAL_BASIS_POINTS() - threshold);

        // scale loss to user's share of the pool
        lossToBreachThreshold = (lossToBreachThreshold * pool.totalAssets()) / assets;
    }

    function test_ForceRebalance_RevertWhenReportStale() public {
        dashboard.VAULT_HUB().mock_setReportFreshness(dashboard.stakingVault(), false);

        vm.expectRevert(StvPool.VaultReportStale.selector);
        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalance_RevertWhenThresholdNotBreached() public {
        _mintMaxStethShares(userAlice);

        vm.expectRevert(StvStETHPool.ZeroArgument.selector);
        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalance_RevertWhenLossDoesNotExceedsThreshold() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice) - 1);

        vm.expectRevert(StvStETHPool.ZeroArgument.selector);
        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalance_DoNotRevertWhenLossExceedsThreshold() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        pool.forceRebalance(userAlice);
    }

    function test_PreviewForceRebalance_RebalanceToReserveRatio() public {
        MockVaultHub vaultHub = dashboard.VAULT_HUB();
        vaultHub.mock_setConnectionParameters(
            dashboard.stakingVault(),
            1000, // 10% reserve ratio + 5% gap on wrapper
            975 // 9.75% rebalance threshold + 5% gap on wrapper
        );
        pool.syncVaultParameters();

        uint256 sharesToMint = pool.remainingMintingCapacitySharesOf(userAlice, 0);
        vm.prank(userAlice);
        pool.mintStethShares(sharesToMint);

        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        // verify that proportion of minted steth to assets equals rebalance threshold
        assertEq(
            Math.mulDiv(
                pool.TOTAL_BASIS_POINTS(),
                steth.getPooledEthByShares(sharesToMint),
                pool.assetsOf(userAlice),
                Math.Rounding.Floor // greater then or equal due to rounding
            ),
            pool.TOTAL_BASIS_POINTS() - pool.forcedRebalanceThresholdBP(),
            "unexpected pre-rebalance ratio"
        );

        uint256 stvBurned = pool.forceRebalance(userAlice);
        assertGt(stvBurned, 0, "expected non-zero burn");

        // verify that proportion of minted steth to assets equals reserve ratio
        assertEq(
            Math.mulDiv(
                pool.TOTAL_BASIS_POINTS(),
                steth.getPooledEthByShares(pool.mintedStethSharesOf(userAlice)),
                pool.assetsOf(userAlice),
                Math.Rounding.Ceil // less then or equal due to rounding
            ),
            pool.TOTAL_BASIS_POINTS() - pool.reserveRatioBP(),
            "unexpected post-rebalance ratio"
        );
    }

    function test_PreviewForceRebalance_ReturnsExpectedValuesForUndercollateralized() public {
        _mintMaxStethShares(userAlice);

        uint256 totalValue = dashboard.maxLockableValue();
        assertGt(totalValue, 1 ether, "unexpected vault value");
        _simulateLoss(4 ether);

        (uint256 stethShares, uint256 stv, bool isUndercollateralized) = pool.previewForceRebalance(userAlice);
        assertEq(stethShares, pool.mintedStethSharesOf(userAlice), "unexpected steth shares to rebalance");
        assertEq(stv, pool.balanceOf(userAlice), "unexpected stv to rebalance");
        assertTrue(isUndercollateralized, "expected undercollateralized");
    }

    function test_ForceRebalance_RevertIfAccountIsUndercollateralized() public {
        _mintMaxStethShares(userAlice);

        uint256 totalValue = dashboard.maxLockableValue();
        assertGt(totalValue, 1 ether, "unexpected vault value");
        _simulateLoss(totalValue - 1 ether);

        vm.expectRevert(abi.encodeWithSelector(StvStETHPool.UndercollateralizedAccount.selector));
        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalanceAndSocializeLoss_DoNotRevertIfAccountIsUndercollateralized() public {
        // Enable loss socialization
        vm.prank(owner);
        pool.setMaxLossSocializationBP(100_00); // 100%

        _mintMaxStethShares(userAlice);
        _simulateLoss(4 ether);

        vm.prank(socializer);
        pool.forceRebalanceAndSocializeLoss(userAlice);
    }

    function test_ForceRebalance_PermissionlessExecution() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        // Anyone can call forceRebalance
        vm.prank(userBob);
        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalance_UpdatesMintedShares() public {
        _mintMaxStethShares(userAlice);
        uint256 mintedBefore = pool.mintedStethSharesOf(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        pool.forceRebalance(userAlice);

        uint256 mintedAfter = pool.mintedStethSharesOf(userAlice);
        assertLt(mintedAfter, mintedBefore);
    }

    function test_ForceRebalance_BurnsCorrectStv() public {
        _mintMaxStethShares(userAlice);
        uint256 balanceBefore = pool.balanceOf(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        uint256 stvBurned = pool.forceRebalance(userAlice);

        assertEq(pool.balanceOf(userAlice), balanceBefore - stvBurned);
        assertGt(stvBurned, 0);
    }

    function test_ForceRebalance_EmitsCorrectEvent() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        (uint256 expectedShares, uint256 expectedStv,) = pool.previewForceRebalance(userAlice);

        vm.expectEmit(true, true, true, true);
        emit StvStETHPool.StethSharesRebalanced(userAlice, expectedShares, expectedStv);

        pool.forceRebalance(userAlice);
    }

    function test_ForceRebalance_RestoresHealthStatus() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        assertFalse(pool.isHealthyOf(userAlice));

        pool.forceRebalance(userAlice);

        assertTrue(pool.isHealthyOf(userAlice));
    }

    function test_ForceRebalance_WithMinimalThresholdBreach() public {
        _mintMaxStethShares(userAlice);
        uint256 loss = _calcLossToBreachThreshold(userAlice);
        _simulateLoss(loss);

        uint256 stvBurned = pool.forceRebalance(userAlice);
        assertGt(stvBurned, 0);
    }

    function test_ForceRebalance_MultipleTimesForSameUser() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        pool.forceRebalance(userAlice);
        assertTrue(pool.isHealthyOf(userAlice));

        // Simulate another loss
        _simulateLoss(_calcLossToBreachThreshold(userAlice));
        assertFalse(pool.isHealthyOf(userAlice));

        pool.forceRebalance(userAlice);
        assertTrue(pool.isHealthyOf(userAlice));
    }

    function test_ForceRebalance_DifferentUsers_Independent() public {
        vm.prank(userBob);
        pool.depositETH{value: DEPOSIT_AMOUNT}(userBob, address(0));

        _mintMaxStethShares(userAlice);
        _mintMaxStethShares(userBob);

        _simulateLoss(_calcLossToBreachThreshold(userAlice));

        assertFalse(pool.isHealthyOf(userAlice));
        assertFalse(pool.isHealthyOf(userBob));

        uint256 bobMintedBefore = pool.mintedStethSharesOf(userBob);

        pool.forceRebalance(userAlice);

        assertTrue(pool.isHealthyOf(userAlice));
        assertFalse(pool.isHealthyOf(userBob));
        assertEq(pool.mintedStethSharesOf(userBob), bobMintedBefore);
    }

    function test_SocializeLoss_OnlyByRole() public {
        _mintMaxStethShares(userAlice);
        _simulateLoss(4 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), pool.LOSS_SOCIALIZER_ROLE()
            )
        );
        pool.forceRebalanceAndSocializeLoss(userAlice);
    }

    function test_SocializeLoss_RevertWhenHealthy() public {
        _mintMaxStethShares(userAlice);

        vm.prank(socializer);
        vm.expectRevert(StvStETHPool.CollateralizedAccount.selector);
        pool.forceRebalanceAndSocializeLoss(userAlice);
    }

    function test_SocializeLoss_BurnsAvailableStv() public {
        // Enable loss socialization
        vm.prank(owner);
        pool.setMaxLossSocializationBP(100_00); // 100%

        _mintMaxStethShares(userAlice);
        uint256 balanceBefore = pool.balanceOf(userAlice);
        _simulateLoss(4 ether);

        vm.prank(socializer);
        uint256 stvBurned = pool.forceRebalanceAndSocializeLoss(userAlice);

        assertEq(stvBurned, balanceBefore);
        assertEq(pool.balanceOf(userAlice), 0);
    }

    function test_SocializeLoss_ClearsAllMintedShares() public {
        // Enable loss socialization
        vm.prank(owner);
        pool.setMaxLossSocializationBP(100_00); // 100%

        _mintMaxStethShares(userAlice);
        _simulateLoss(4 ether);

        vm.prank(socializer);
        pool.forceRebalanceAndSocializeLoss(userAlice);

        assertEq(pool.mintedStethSharesOf(userAlice), 0);
    }
}
