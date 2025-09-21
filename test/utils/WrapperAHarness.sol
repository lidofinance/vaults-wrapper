// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";

import {WrapperA} from "src/WrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {Factory} from "src/Factory.sol";
import {WrapperAFactory} from "src/factories/WrapperAFactory.sol";
import {WrapperBFactory} from "src/factories/WrapperBFactory.sol";
import {WrapperCFactory} from "src/factories/WrapperCFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {FactoryHelper} from "test/utils/FactoryHelper.sol";

/**
 * @title WrapperAHarness
 * @notice Helper contract for integration tests that provides common setup for WrapperA (no minting, no strategy)
 */
contract WrapperAHarness is Test {
    CoreHarness public core;

    // Core contracts
    ILido public steth;
    IWstETH public wsteth;
    IVaultHub public vaultHub;

    // Test users
    address public constant USER1 = address(0x1001);
    address public constant USER2 = address(0x1002);
    address public constant USER3 = address(0x1003);

    address public constant NODE_OPERATOR = address(0x1004);

    // Test constants
    uint256 public constant WEI_ROUNDING_TOLERANCE = 1;
    uint256 public CONNECT_DEPOSIT;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 0; // 0%
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;
    uint256 public constant RESERVE_RATIO_BP = 20_00; // not configurable
    uint256 public immutable EXTRA_BASE = 10 ** (27 - 18); // not configurable

    // Deployment configuration struct
    struct DeploymentConfig {
        Factory.WrapperType configuration;
        address strategy;
        bool enableAllowlist;
        uint256 reserveRatioGapBP;
        address nodeOperator;
        address nodeOperatorManager;
        address upgradeConformer;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
            uint256 maxFinalizationTime;
        address teller;
        address boringQueue;
    }

    struct WrapperContext {
        WrapperA wrapper;
        WithdrawalQueue withdrawalQueue;
        IDashboard dashboard;
        IStakingVault vault;
    }

    function _initializeCore() internal {
        core = new CoreHarness("lido-core/deployed-local.json");
        steth = core.steth();
        wsteth = core.wsteth();
        vaultHub = core.vaultHub();
        CONNECT_DEPOSIT = vaultHub.CONNECT_DEPOSIT();

        core.setStethShareRatio(1 ether + 10 ** 17); // 1.1 ETH

        // Deal ETH to test users
        vm.deal(USER1, 100_000 ether);
        vm.deal(USER2, 100_000 ether);
        vm.deal(USER3, 100_000 ether);
        vm.deal(NODE_OPERATOR, 1000 ether);
    }

    function _deployWrapperSystem(DeploymentConfig memory config) internal returns (WrapperContext memory) {
        address vault_;
        address dashboard_;
        address payable wrapperAddress;
        address withdrawalQueue_;

        require(address(core) != address(0), "CoreHarness not initialized");

        address vaultFactory = core.locator().vaultFactory();
        address lazyOracle = core.locator().lazyOracle();
        FactoryHelper helper = new FactoryHelper();
        Factory factory = helper.deployMainFactory(vaultFactory, address(steth), address(wsteth), lazyOracle);

        vm.startPrank(config.nodeOperator);
        if (config.configuration == Factory.WrapperType.NO_MINTING_NO_STRATEGY) {
            (vault_, dashboard_, wrapperAddress, withdrawalQueue_) = factory.createVaultWithNoMintingNoStrategy{value: CONNECT_DEPOSIT}(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.upgradeConformer,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.enableAllowlist
            );
        } else if (config.configuration == Factory.WrapperType.MINTING_NO_STRATEGY) {
            (vault_, dashboard_, wrapperAddress, withdrawalQueue_) = factory.createVaultWithMintingNoStrategy{value: CONNECT_DEPOSIT}(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.upgradeConformer,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.enableAllowlist,
                config.reserveRatioGapBP
            );
        } else if (config.configuration == Factory.WrapperType.LOOP_STRATEGY) {
            uint256 loops = 1;
            (vault_, dashboard_, wrapperAddress, withdrawalQueue_) = factory.createVaultWithLoopStrategy{value: CONNECT_DEPOSIT}(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.upgradeConformer,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.enableAllowlist,
                config.reserveRatioGapBP,
                loops
            );
        } else if (config.configuration == Factory.WrapperType.GGV_STRATEGY) {
            (vault_, dashboard_, wrapperAddress, withdrawalQueue_) = factory.createVaultWithGGVStrategy{value: CONNECT_DEPOSIT}(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.upgradeConformer,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.enableAllowlist,
                config.reserveRatioGapBP,
                config.teller,
                config.boringQueue
            );
        } else {
            revert("Invalid configuration");
        }
        vm.stopPrank();

        // Apply initial vault report
        core.applyVaultReport(vault_, 0, 0, 0, 0, true);

        return WrapperContext({
            wrapper: WrapperA(payable(wrapperAddress)),
            withdrawalQueue: WithdrawalQueue(payable(withdrawalQueue_)),
            dashboard: IDashboard(payable(dashboard_)),
            vault: IStakingVault(vault_)
        });
    }

    function _deployWrapperA(
        bool enableAllowlist
    ) internal returns (
        WrapperA wrapper_,
        WithdrawalQueue withdrawalQueue_,
        IDashboard dashboard_,
        IStakingVault vault_
    ) {
        DeploymentConfig memory config = DeploymentConfig({
            configuration: Factory.WrapperType.NO_MINTING_NO_STRATEGY,
            strategy: address(0),
            enableAllowlist: enableAllowlist,
            reserveRatioGapBP: 0,
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            upgradeConformer: NODE_OPERATOR,
            nodeOperatorFeeBP: NODE_OPERATOR_FEE_RATE,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
            teller: address(0),
            boringQueue: address(0)
        });

        WrapperContext memory context = _deployWrapperSystem(config);

        wrapper_ = context.wrapper;
        withdrawalQueue_ = context.withdrawalQueue;
        vault_ = context.vault;
        dashboard_ = context.dashboard;

        return (wrapper_, withdrawalQueue_, dashboard_, vault_);
    }

    function _checkInitialState(WrapperContext memory ctx) internal virtual {
        // Basic checks common to all wrappers
        assertEq(ctx.dashboard.reserveRatioBP(), RESERVE_RATIO_BP, "Reserve ratio should match RESERVE_RATIO_BP constant");
        assertEq(ctx.wrapper.EXTRA_DECIMALS_BASE(), EXTRA_BASE, "EXTRA_DECIMALS_BASE should match EXTRA_BASE constant");

        assertEq(ctx.wrapper.totalSupply(), CONNECT_DEPOSIT * EXTRA_BASE, "Total stvETH supply should be equal to CONNECT_DEPOSIT");
        assertEq(ctx.wrapper.balanceOf(address(ctx.wrapper)), CONNECT_DEPOSIT * EXTRA_BASE, "Wrapper stvETH balance should be equal to CONNECT_DEPOSIT");

        assertEq(ctx.wrapper.balanceOf(NODE_OPERATOR), 0, "stvETH balance of NODE_OPERATOR should be zero");
        assertEq(steth.balanceOf(NODE_OPERATOR), 0, "stETH balance of node operator should be zero");

        assertEq(ctx.dashboard.locked(), CONNECT_DEPOSIT, "Vault's locked should be CONNECT_DEPOSIT");
        assertEq(ctx.dashboard.maxLockableValue(), CONNECT_DEPOSIT, "Vault's total value should be CONNECT_DEPOSIT");
        assertEq(ctx.dashboard.withdrawableValue(), 0, "Vault's withdrawable value should be zero");
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be zero");

        // WrapperA specific: no minting capacity
        assertEq(ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be zero");
        assertEq(ctx.dashboard.totalMintingCapacityShares(), 0, "Total minting capacity should be zero");

        assertEq(steth.getPooledEthByShares(1 ether), 1 ether + 10 ** 17, "ETH for 1e18 stETH shares should be 1.1 ETH");

        console.log("Reserve ratio:", ctx.dashboard.reserveRatioBP());
        console.log("ETH for 1e18 stETH shares: ", steth.getPooledEthByShares(1 ether));

        _assertUniversalInvariants("Initial state", ctx);
    }


    /**
     * @notice Report a vault value change without fees
     * @param _factorBp The factor by which the vault value should be changed (10_000 = 100%)
     */
    function reportVaultValueChangeNoFees(WrapperContext memory ctx, uint256 _factorBp) public {
        uint256 totalValue = ctx.dashboard.totalValue();
        totalValue = totalValue * _factorBp / 10000;
        core.applyVaultReport(address(ctx.vault), totalValue, 0, 0, 0, false);
    }

    // TODO: add after report invariants
    // TODO: add after deposit invariants
    // TODO: add after requestWithdrawal invariants
    // TODO: add after finalizeWithdrawal invariants
    // TODO: add after claimWithdrawal invariants

    function _allPossibleStvHolders(WrapperContext memory ctx) internal view virtual returns (address[] memory) {
        address[] memory holders = new address[](5);
        holders[0] = USER1;
        holders[1] = USER2;
        holders[2] = USER3;
        holders[3] = address(ctx.wrapper);
        holders[4] = address(ctx.withdrawalQueue);
        return holders;
    }

    function _assertUniversalInvariants(string memory _context, WrapperContext memory _ctx) internal virtual {

        assertEq(
            _ctx.wrapper.previewRedeem(_ctx.wrapper.totalSupply()),
            _ctx.wrapper.totalAssets(),
            _contextMsg(_context, "previewRedeem(totalSupply) should equal totalAssets")
        );

        address[] memory holders = _allPossibleStvHolders(_ctx);
        {
            uint256 totalBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalBalance += _ctx.wrapper.balanceOf(holders[i]);
            }
            assertEq(
                totalBalance,
                _ctx.wrapper.totalSupply(),
                _contextMsg(_context, "Sum of all holders' balances should equal totalSupply")
            );
        }

        {
            uint256 totalPreviewRedeem = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalPreviewRedeem += _ctx.wrapper.previewRedeem(_ctx.wrapper.balanceOf(holders[i]));
            }
            uint256 totalAssets = _ctx.wrapper.totalAssets();
            uint256 diff = totalPreviewRedeem > totalAssets
                ? totalPreviewRedeem - totalAssets
                : totalAssets - totalPreviewRedeem;
            assertTrue(
                diff <= 1,
                _contextMsg(_context, "Sum of previewRedeem of all holders should equal totalAssets (within 1 wei accuracy)")
            );
        }

        {
            // The sum of all stETH balances (users + wrapper) should approximately equal the stETH minted for all liability shares
            uint256 totalStethBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalStethBalance += steth.balanceOf(holders[i]);
            }

            uint256 totalMintedSteth = steth.getPooledEthByShares(_ctx.dashboard.liabilityShares());
            assertApproxEqAbs(
                totalStethBalance,
                totalMintedSteth,
                holders.length * WEI_ROUNDING_TOLERANCE,
                _contextMsg(_context, "Sum of all stETH balances (users + wrapper) should approximately equal stETH minted for liability shares")
            );
        }
    }

    function _contextMsg(string memory _context, string memory _msg) internal pure returns (string memory) {
        return string(abi.encodePacked(_context, ": ", _msg));
    }
}