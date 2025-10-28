// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";

import {StvPool} from "src/StvPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Factory} from "src/Factory.sol";
import {FactoryHelper} from "test/utils/FactoryHelper.sol";
import {Distributor} from "src/Distributor.sol";

/**
 * @title StvPoolHarness
 * @notice Helper contract for integration tests that provides common setup for StvPool (no minting, no strategy)
 */
contract StvPoolHarness is Test {
    CoreHarness public core;

    // Core contracts
    ILido public steth;
    IWstETH public wsteth;
    IVaultHub public vaultHub;

    // Test users
    address public constant USER1 = address(0x1001);
    address public constant USER2 = address(0x1002);
    address public constant USER3 = address(0x1003);

    address public constant CL_LAYER = address(0x128284828);

    address public constant NODE_OPERATOR = address(0x1004);

    // Test constants
    uint256 public constant WEI_ROUNDING_TOLERANCE = 1;
    uint256 public CONNECT_DEPOSIT;
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;
    uint256 public immutable EXTRA_BASE = 10 ** (27 - 18); // not configurable

    // Deployment configuration struct
    struct DeploymentConfig {
        Factory.WrapperType configuration;
        bool enableAllowlist;
        uint256 reserveRatioGapBP;
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        address teller;
        address boringQueue;
    }

    struct WrapperContext {
        StvPool pool;
        WithdrawalQueue withdrawalQueue;
        IDashboard dashboard;
        IStakingVault vault;
        address strategy;
        Distributor distributor;
    }

    function _initializeCore() internal {
        core = new CoreHarness();
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
        address payable poolAddress;
        address withdrawalQueue_;
        address strategy_;
        address distributor_;

        require(address(core) != address(0), "CoreHarness not initialized");

        address vaultFactory = core.locator().vaultFactory();
        address lazyOracle = core.locator().lazyOracle();

        // Decide whether to deploy a new pool Factory or use a pre-deployed one
        Factory factory;
        string memory factoryJsonPath = "";
        try vm.envString("FACTORY_DEPLOYED_JSON") returns (string memory p) {
            factoryJsonPath = p;
        } catch {}

        if (bytes(factoryJsonPath).length != 0) {
            string memory deployedJson = vm.readFile(factoryJsonPath);
            address existingFactory = vm.parseJsonAddress(deployedJson, "$.deployment.factory");
            factory = Factory(existingFactory);
        } else {
            FactoryHelper helper = new FactoryHelper();
            factory = helper.deployMainFactory(vaultFactory, address(steth), address(wsteth), lazyOracle);
        }

        if (bytes(factoryJsonPath).length > 0) {
            console.log("factoryJsonPath", factoryJsonPath);
            console.log("NB: using existingFactory for testing: %s", address(factory));
        }

        vm.startPrank(config.nodeOperator);
        if (config.configuration == Factory.WrapperType.NO_MINTING_NO_STRATEGY) {
            (vault_, dashboard_, poolAddress, withdrawalQueue_, distributor_) = factory.createVaultWithNoMintingNoStrategy{
                value: CONNECT_DEPOSIT
            }(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.minWithdrawalDelayTime,
                config.enableAllowlist
            );
        } else if (config.configuration == Factory.WrapperType.MINTING_NO_STRATEGY) {
            (vault_, dashboard_, poolAddress, withdrawalQueue_, distributor_) = factory.createVaultWithMintingNoStrategy{
                value: CONNECT_DEPOSIT
            }(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.minWithdrawalDelayTime,
                config.enableAllowlist,
                config.reserveRatioGapBP
            );
        } else if (config.configuration == Factory.WrapperType.LOOP_STRATEGY) {
            uint256 loops = 1;
            (vault_, dashboard_, poolAddress, withdrawalQueue_, strategy_, distributor_) = factory.createVaultWithLoopStrategy{
                value: CONNECT_DEPOSIT
            }(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.minWithdrawalDelayTime,
                config.enableAllowlist,
                config.reserveRatioGapBP,
                loops
            );
        } else if (config.configuration == Factory.WrapperType.GGV_STRATEGY) {
            (vault_, dashboard_, poolAddress, withdrawalQueue_, strategy_, distributor_) = factory.createVaultWithGGVStrategy{
                value: CONNECT_DEPOSIT
            }(
                config.nodeOperator,
                config.nodeOperatorManager,
                config.nodeOperatorFeeBP,
                config.confirmExpiry,
                config.maxFinalizationTime,
                config.minWithdrawalDelayTime,
                config.enableAllowlist,
                config.reserveRatioGapBP,
                config.teller,
                config.boringQueue
            );
        } else {
            revert("Invalid configuration");
        }
        vm.stopPrank();

        // Apply initial vault report with current total value equal to connect deposit
        core.applyVaultReport(vault_, CONNECT_DEPOSIT, 0, 0, 0);

        WrapperContext memory ctx = WrapperContext({
            pool: StvPool(payable(poolAddress)),
            withdrawalQueue: WithdrawalQueue(payable(withdrawalQueue_)),
            dashboard: IDashboard(payable(dashboard_)),
            vault: IStakingVault(vault_),
            strategy: strategy_,
            distributor: Distributor(distributor_)
        });

        return ctx;
    }

    function _deployStvPool(bool enableAllowlist, uint256 nodeOperatorFeeBP)
        internal
        returns (WrapperContext memory context)
    {
        DeploymentConfig memory config = DeploymentConfig({
            configuration: Factory.WrapperType.NO_MINTING_NO_STRATEGY,
            enableAllowlist: enableAllowlist,
            reserveRatioGapBP: 0,
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            nodeOperatorFeeBP: nodeOperatorFeeBP,
            confirmExpiry: CONFIRM_EXPIRY,
            maxFinalizationTime: 30 days,
            minWithdrawalDelayTime: 1 days,
            teller: address(0),
            boringQueue: address(0)
        });

        context = _deployWrapperSystem(config);

        return context;
    }

    function _checkInitialState(WrapperContext memory ctx) internal virtual {
        // Basic checks common to all pools
        assertEq(10 ** (ctx.pool.decimals() - 18), EXTRA_BASE, "should match EXTRA_BASE constant");

        assertEq(
            ctx.pool.totalSupply(),
            CONNECT_DEPOSIT * EXTRA_BASE,
            "Total stvETH supply should be equal to CONNECT_DEPOSIT"
        );
        assertEq(
            ctx.pool.balanceOf(address(ctx.pool)),
            CONNECT_DEPOSIT * EXTRA_BASE,
            "Wrapper stvETH balance should be equal to CONNECT_DEPOSIT"
        );

        assertEq(ctx.pool.balanceOf(NODE_OPERATOR), 0, "stvETH balance of NODE_OPERATOR should be zero");
        assertEq(steth.balanceOf(NODE_OPERATOR), 0, "stETH balance of node operator should be zero");

        assertEq(ctx.dashboard.locked(), CONNECT_DEPOSIT, "Vault's locked should be CONNECT_DEPOSIT");
        assertEq(ctx.dashboard.maxLockableValue(), CONNECT_DEPOSIT, "Vault's total value should be CONNECT_DEPOSIT");
        assertEq(ctx.dashboard.withdrawableValue(), 0, "Vault's withdrawable value should be zero");
        assertEq(ctx.dashboard.liabilityShares(), 0, "Vault's liability shares should be zero");

        // StvPool specific: no minting capacity
        assertEq(ctx.dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be zero");
        assertEq(ctx.dashboard.totalMintingCapacityShares(), 0, "Total minting capacity should be zero");

        console.log("Reserve ratio:", ctx.dashboard.vaultConnection().reserveRatioBP);
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
        core.applyVaultReport(address(ctx.vault), totalValue, 0, 0, 0);

        assertEq(totalValue, ctx.dashboard.totalValue(), "Total value should match reported one, check quarantine");
    }

    /**
     * @notice Simulate sending all available ETH from staking vault to consensus layer (drain withdrawable)
     */
    function _depositToCL(WrapperContext memory ctx) internal {
        core.mockValidatorsReceiveETH(address(ctx.vault));
    }

    /**
     * @notice Simulate validator exits returning ETH from consensus layer to staking vault
     * @param _amount amount of ETH to return to staking vault
     */
    function _withdrawFromCL(WrapperContext memory ctx, uint256 _amount) internal {
        core.mockValidatorExitReturnETH(address(ctx.vault), _amount);
    }

    /**
     * @notice Advance block time past the WQ min delay for the given request and ensure report freshness afterwards
     * @dev Ensures LazyOracle.latestReportTimestamp() is >= request.timestamp and that report is fresh
     */
    function _advancePastMinDelayAndRefreshReport(WrapperContext memory ctx, uint256 requestId) internal {
        uint256 minDelay = ctx.withdrawalQueue.MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS();
        WithdrawalQueue.WithdrawalRequestStatus memory st = ctx.withdrawalQueue.getWithdrawalStatus(requestId);
        vm.warp(st.timestamp + minDelay + 2);
        reportVaultValueChangeNoFees(ctx, 10_000);
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
        holders[3] = address(ctx.pool);
        holders[4] = address(ctx.withdrawalQueue);
        return holders;
    }

    function _assertUniversalInvariants(string memory _context, WrapperContext memory _ctx) internal virtual {
        assertEq(
            _ctx.pool.previewRedeem(_ctx.pool.totalSupply()),
            _ctx.pool.totalAssets(),
            _contextMsg(_context, "previewRedeem(totalSupply) should equal totalAssets")
        );

        address[] memory holders = _allPossibleStvHolders(_ctx);
        {
            uint256 totalBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalBalance += _ctx.pool.balanceOf(holders[i]);
            }
            assertEq(
                totalBalance,
                _ctx.pool.totalSupply(),
                _contextMsg(_context, "Sum of all holders' balances should equal totalSupply")
            );
        }

        {
            uint256 totalPreviewRedeem = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalPreviewRedeem += _ctx.pool.previewRedeem(_ctx.pool.balanceOf(holders[i]));
            }
            uint256 totalAssets = _ctx.pool.totalAssets();
            uint256 diff =
                totalPreviewRedeem > totalAssets ? totalPreviewRedeem - totalAssets : totalAssets - totalPreviewRedeem;
            assertTrue(
                diff <= 1,
                _contextMsg(
                    _context, "Sum of previewRedeem of all holders should equal totalAssets (within 1 wei accuracy)"
                )
            );
        }

        {
            // The sum of all stETH balances (users + pool) should approximately equal the stETH minted for all liability shares
            uint256 totalStethBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalStethBalance += steth.balanceOf(holders[i]);
            }

            uint256 totalMintedSteth = steth.getPooledEthByShares(_ctx.dashboard.liabilityShares());
            assertApproxEqAbs(
                totalStethBalance,
                totalMintedSteth,
                holders.length * WEI_ROUNDING_TOLERANCE,
                _contextMsg(
                    _context,
                    "Sum of all stETH balances (users + pool) should approximately equal stETH minted for liability shares"
                )
            );
        }
    }

    function _contextMsg(string memory _context, string memory _msg) internal pure returns (string memory) {
        return string(abi.encodePacked(_context, ": ", _msg));
    }
}
