// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {IOperatorGrid} from "src/interfaces/IOperatorGrid.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {StvStETHPoolHarness} from "test/utils/StvStETHPoolHarness.sol";
import {TimelockHarness} from "test/utils/TimelockHarness.sol";

/**
 * @title DisconnectTest
 * @notice Disconnection flow steps
 *
 * - Inform users about upcoming disconnect and timeline
 * - Make sure all roles you will need are assigned
 * - Exit all validators
 *    - Voluntarily if possible
 *    - Forcibly if needed:
 *      - Call `triggerValidatorWithdrawals` on Pool contract from `TRIGGER_VALIDATOR_WITHDRAWAL_ROLE`
 * - Finalize all withdrawal requests
 * - Pause Pool and Withdrawal Queue contracts
 *    - Call `pause` method on Pool contract from `PAUSE_ROLE`
 *    - Call `pause` method on Withdrawal Queue contract from `PAUSE_ROLE`
 * - Rebalance Staking Vault if liability shares are left
 *    - Rebalance Staking Vault to zero liability
 *      - Call `rebalanceVaultWithShares` on Dashboard contract from `REBALANCE_ROLE`
 *    - Ensure no undercollateralized users. Force rebalance them if any exist
 *      - Call `forceRebalanceAndSocializeLoss` on Pool contract from `LOSS_SOCIALIZER_ROLE`
 * - Disconnect Staking Vault
 *    - Initiate voluntary disconnect on Dashboard from Timelock Controller
 * - Withdraw assets from Staking Vault and distribute them to users
 *    - Make sure you account for Initial Connect Deposit that remains locked in the vault
 */
contract DisconnectTest is StvStETHPoolHarness, TimelockHarness {
    WrapperContext ctx;

    address finalizer = NODE_OPERATOR;

    function setUp() public {
        _initializeCore();

        ctx = _deployStvStETHPool({enableAllowlist: false, nodeOperatorFeeBP: 200, reserveRatioGapBP: 500});
        _setupTimelock(address(ctx.timelock), NODE_OPERATOR, NODE_OPERATOR);

        vm.deal(address(this), 100 ether);
    }

    function test_Disconnect_InitialState() public view {
        // Vault is connected
        assertTrue(core.vaultHub().isVaultConnected(address(ctx.vault)));
        assertFalse(core.vaultHub().isPendingDisconnect(address(ctx.vault)));

        // Pool has assets and supply
        assertGt(ctx.pool.totalAssets(), 0);
        assertGt(ctx.pool.totalSupply(), 0);

        // No liability
        assertEq(ctx.dashboard.liabilityShares(), 0);
    }

    function test_Disconnect_VoluntaryDisconnect() public {
        IVaultHub vaultHub = core.vaultHub();
        StvStETHPool pool = stvStETHPool(ctx);

        // Users can deposit before disconnect
        uint256 depositAmount = 10 ether;
        pool.depositETH{value: depositAmount}(address(this), address(0));
        assertGt(pool.balanceOf(address(this)), 0);
        assertApproxEqAbs(pool.assetsOf(address(this)), depositAmount, WEI_ROUNDING_TOLERANCE);

        // Users can mint stETH before disconnect
        uint256 stethSharesToMint = 10 ** 18;
        pool.mintStethShares(stethSharesToMint);
        assertEq(pool.mintedStethSharesOf(address(this)), stethSharesToMint);

        // Disconnect should revert since liability shares are not zero
        vm.prank(address(ctx.timelock));
        vm.expectRevert(
            abi.encodeWithSignature(
                "NoLiabilitySharesShouldBeLeft(address,uint256)", address(ctx.vault), stethSharesToMint
            )
        );
        ctx.dashboard.voluntaryDisconnect();

        // Users have time to exit from the pool
        ctx.withdrawalQueue.requestWithdrawal(address(this), pool.balanceOf(address(this)) / 5, 0);
        vm.warp(block.timestamp + 30 days);

        // Check there are requests to finalize
        uint256 requestToFinalized = ctx.withdrawalQueue.unfinalizedRequestsNumber();
        assertGt(requestToFinalized, 0);

        // Oracle report to update vault state
        reportVaultValueChangeNoFees(ctx, 100_00);

        // Finalize all withdrawal requests
        vm.prank(finalizer);
        ctx.withdrawalQueue.finalize(requestToFinalized, address(0));
        assertEq(ctx.withdrawalQueue.unfinalizedRequestsNumber(), 0);
        assertEq(ctx.withdrawalQueue.unfinalizedStv(), 0);
        assertEq(ctx.withdrawalQueue.unfinalizedAssets(), 0);
        assertEq(ctx.withdrawalQueue.unfinalizedStethShares(), 0);

        // Pause Withdrawal Queue
        // TODO: assign pause_role
        // vm.prank(pauser);
        // ctx.withdrawalQueue.pause();
        // assertTrue(ctx.withdrawalQueue.paused());

        // Double check no requests are left to finalize
        // uint256 unfinalizedRequests = ctx.withdrawalQueue.unfinalizedRequestsNumber();
        // assertEq(unfinalizedRequests, 0);

        // Users can not request new withdrawals
        // vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        // ctx.withdrawalQueue.requestWithdrawal(address(this), 10 ** pool.decimals(), 0);

        // Pause Pool
        // TODO: implement pool pause
        // vm.prank(pauser);
        // pool.pause();
        // assertTrue(pool.paused());

        // Users can not deposit
        // vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        // pool.depositETH{value: 1 ether}(address(this), address(0));

        // Users can not mint stETH
        // vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        // pool.mintStethShares(10 ** 18);

        // Assign roles to temp address
        address disconnectManager = makeAddr("disconnectManager");

        address[] memory targets = new address[](3);
        bytes[] memory payloads = new bytes[](3);

        targets[0] = address(pool);
        targets[1] = address(ctx.dashboard);
        targets[2] = address(ctx.dashboard);

        bytes32 lossSocializerRole = pool.LOSS_SOCIALIZER_ROLE();
        bytes32 triggerValidatorRole = ctx.dashboard.TRIGGER_VALIDATOR_WITHDRAWAL_ROLE();
        bytes32 rebalanceRole = ctx.dashboard.REBALANCE_ROLE();

        payloads[1] = abi.encodeWithSignature("grantRole(bytes32,address)", lossSocializerRole, disconnectManager);
        payloads[0] = abi.encodeWithSignature("grantRole(bytes32,address)", triggerValidatorRole, disconnectManager);
        payloads[2] = abi.encodeWithSignature("grantRole(bytes32,address)", rebalanceRole, disconnectManager);

        _timelockScheduleAndExecuteBatch(targets, payloads);

        // Verify roles assigned
        pool.hasRole(lossSocializerRole, disconnectManager);
        pool.hasRole(triggerValidatorRole, disconnectManager);
        ctx.dashboard.hasRole(rebalanceRole, disconnectManager);

        // TODO: assign TRIGGER_VALIDATOR_WITHDRAWAL_ROLE from Dashboard to Pool
        // Verify validators can be forcibly withdrawn
        // bytes memory mockPubkey = new bytes(48);
        // uint64[] memory amountsInGwei = new uint64[](1);
        // amountsInGwei[0] = 32 * 10 ** 9;

        // vm.prank(disconnectManager);
        // pool.triggerValidatorWithdrawals(mockPubkey, amountsInGwei, disconnectManager);

        // Oracle report to update vault state
        reportVaultValueChangeNoFees(ctx, 100_00);

        // Check vault has liability shares
        uint256 liabilityShares = ctx.dashboard.liabilityShares();
        assertGt(liabilityShares, 0);

        // Rebalance vault to zero liability
        vm.prank(disconnectManager);
        ctx.dashboard.rebalanceVaultWithShares(liabilityShares);
        assertEq(ctx.dashboard.liabilityShares(), 0);

        // Schedule and execute disconnect
        _timelockSchedule(address(ctx.dashboard), abi.encodeWithSignature("voluntaryDisconnect()"));
        _timelockWarp();
        reportVaultValueChangeNoFees(ctx, 0); // voluntaryDisconnect() requires fresh oracle report
        _timelockExecute(address(ctx.dashboard), abi.encodeWithSignature("voluntaryDisconnect()"));

        // Verify disconnect is pending
        assertTrue(vaultHub.isVaultConnected(address(ctx.vault)));
        assertTrue(vaultHub.isPendingDisconnect(address(ctx.vault)));

        // Apply oracle report to finalize disconnect
        IVaultHub.VaultRecord memory vaultRecord = vaultHub.vaultRecord(address(ctx.vault));

        vm.prank(address(core.lazyOracle()));
        vaultHub.applyVaultReport({
            _vault: address(ctx.vault),
            _reportTimestamp: block.timestamp,
            _reportTotalValue: vaultRecord.report.totalValue,
            _reportInOutDelta: vaultRecord.report.inOutDelta,
            _reportCumulativeLidoFees: vaultRecord.cumulativeLidoFees,
            _reportLiabilityShares: vaultRecord.liabilityShares,
            _reportMaxLiabilityShares: vaultRecord.maxLiabilityShares,
            _reportSlashingReserve: 0
        });

        assertFalse(vaultHub.isVaultConnected(address(ctx.vault)));

        // Check the vault has non zero assets to withdraw
        uint256 availableBalance = ctx.vault.availableBalance();
        assertGt(availableBalance, 0);
        assertEq(address(ctx.vault).balance, availableBalance);

        // Withdraw assets from the vault
        // TODO: should it be withdrawal to Distributor contract?
    }
}
