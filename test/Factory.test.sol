// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "src/Factory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";

import {Distributor} from "src/Distributor.sol";
import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";

import {MockDashboard} from "test/mocks/MockDashboard.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockLazyOracle} from "test/mocks/MockLazyOracle.sol";
import {MockLidoLocator} from "test/mocks/MockLidoLocator.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";

contract FactoryTest is Test {
    Factory public wrapperFactory;

    MockVaultHub public vaultHub;
    MockVaultFactory public vaultFactory;
    MockERC20 public stETH;
    MockERC20 public wstETH;
    MockLazyOracle public lazyOracle;
    MockLidoLocator public locator;

    address public admin = address(0x1);
    address public nodeOperator = address(0x2);
    address public nodeOperatorManager = address(0x3);

    uint256 public connectDeposit = 1 ether;
    uint256 internal immutable fusakaTxGasLimit = 16_777_216;

    function setUp() public {
        vaultHub = new MockVaultHub();
        vaultFactory = new MockVaultFactory(address(vaultHub));
        stETH = new MockERC20("Staked Ether", "stETH");
        wstETH = new MockERC20("Wrapped Staked Ether", "wstETH");
        lazyOracle = new MockLazyOracle();

        locator = new MockLidoLocator(
            address(stETH), address(wstETH), address(lazyOracle), address(vaultHub), address(vaultFactory)
        );

        Factory.SubFactories memory subFactories;
        subFactories.stvPoolFactory = address(new StvPoolFactory());
        subFactories.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        subFactories.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        subFactories.distributorFactory = address(new DistributorFactory());
        subFactories.loopStrategyFactory = address(new LoopStrategyFactory());
        address dummyTeller = address(new DummyImplementation());
        address dummyQueue = address(new DummyImplementation());
        subFactories.ggvStrategyFactory = address(new GGVStrategyFactory(dummyTeller, dummyQueue));
        subFactories.timelockFactory = address(new TimelockFactory());

        wrapperFactory = new Factory(address(locator), subFactories);

        vm.deal(admin, 100 ether);
    }

    function _buildConfigs(
        bool allowlistEnabled,
        bool mintingEnabled,
        uint256 reserveRatioGapBP,
        string memory name,
        string memory symbol
    )
        internal
        view
        returns (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        )
    {
        vaultConfig = Factory.VaultConfig({
            nodeOperator: nodeOperator,
            nodeOperatorManager: nodeOperatorManager,
            nodeOperatorFeeBP: 100,
            confirmExpiry: 3600
        });

        commonPoolConfig = Factory.CommonPoolConfig({
            maxFinalizationTime: 30 days,
            minWithdrawalDelayTime: 1 days,
            name: name,
            symbol: symbol
        });

        auxiliaryConfig = Factory.AuxiliaryPoolConfig({
            allowlistEnabled: allowlistEnabled,
            mintingEnabled: mintingEnabled,
            reserveRatioGapBP: reserveRatioGapBP
        });
    }

    function _defaultTimelockConfig() internal view returns (Factory.TimelockConfig memory) {
        return Factory.TimelockConfig({minDelaySeconds: 0, executor: admin});
    }

    function test_canCreatePool() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(false, false, 0, "Factory STV Pool", "FSTV");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(0);

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate);
        vm.stopPrank();

        StvPool pool = StvPool(payable(deployment.pool));
        WithdrawalQueue withdrawalQueue = WithdrawalQueue(payable(deployment.withdrawalQueue));
        IDashboard dashboard = IDashboard(payable(deployment.dashboard));
        Distributor distributor = pool.DISTRIBUTOR();

        assertEq(address(pool.DASHBOARD()), address(dashboard));
        assertEq(address(pool.WITHDRAWAL_QUEUE()), address(withdrawalQueue));
        assertEq(address(pool.DISTRIBUTOR()), address(distributor));

        assertEq(deployment.vault, address(dashboard.stakingVault()));
        assertEq(address(pool.STAKING_VAULT()), deployment.vault);

        MockDashboard mockDashboard = MockDashboard(payable(address(dashboard)));
        assertTrue(mockDashboard.hasRole(mockDashboard.DEFAULT_ADMIN_ROLE(), deployment.timelock));

        assertEq(pool.ALLOW_LIST_ENABLED(), false);
        assertEq(deployment.distributor, address(distributor));
        assertEq(deployment.strategy, address(0));
        assertEq(deployment.poolType, wrapperFactory.STV_POOL_TYPE());
    }

    function test_revertWithoutConnectDeposit() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(false, false, 0, "Factory STV Pool", "FSTV");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(0);

        vm.startPrank(admin);
        vm.expectRevert();
        wrapperFactory.createPoolStart(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        vm.stopPrank();
    }

    function test_canCreateWithStrategy() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(true, true, 0, "Factory stETH Pool", "FSTETH");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(wrapperFactory.GGV_STRATEGY_FACTORY());

        address ggvFactory = address(wrapperFactory.GGV_STRATEGY_FACTORY());

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        uint256 nonceBefore = vm.getNonce(ggvFactory);
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate);
        vm.stopPrank();

        StvStETHPool pool = StvStETHPool(payable(deployment.pool));

        uint256 nonceAfter = vm.getNonce(ggvFactory);
        assertTrue(nonceAfter >= nonceBefore);
        assertTrue(deployment.strategy != address(0));
        assertTrue(pool.isAllowListed(deployment.strategy));

        MockDashboard mockDashboard = MockDashboard(payable(deployment.dashboard));
        assertTrue(mockDashboard.hasRole(mockDashboard.MINT_ROLE(), address(pool)));
        assertTrue(mockDashboard.hasRole(mockDashboard.BURN_ROLE(), address(pool)));
        assertEq(deployment.poolType, wrapperFactory.STRATEGY_POOL_TYPE());
    }

    function test_allowlistEnabled() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(true, false, 0, "Factory STV Pool", "FSTV");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(0);

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate);
        vm.stopPrank();

        StvPool pool = StvPool(payable(deployment.pool));
        assertTrue(pool.ALLOW_LIST_ENABLED());
        assertEq(deployment.poolType, wrapperFactory.STV_POOL_TYPE());
    }

    function test_createPoolStartGasConsumptionBelowFusakaLimit() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(false, false, 0, "Factory STV Pool", "FSTV");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(0);

        vm.startPrank(admin);
        uint256 gasBefore = gasleft();
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        uint256 gasUsedStart = gasBefore - gasleft();

        uint256 gasBeforeFinish = gasleft();
        wrapperFactory.createPoolFinish(intermediate);
        uint256 gasUsedFinish = gasBeforeFinish - gasleft();
        vm.stopPrank();

        emit log_named_uint("createPoolStart gas", gasUsedStart);
        emit log_named_uint("createPoolFinish gas", gasUsedFinish);
        assertLt(gasUsedStart, fusakaTxGasLimit, "createPoolStart gas exceeds Fusaka limit");
        assertLt(gasUsedFinish, fusakaTxGasLimit, "createPoolFinish gas exceeds Fusaka limit");
    }

    function test_createPoolStartGasConsumptionBelowFusakaLimitForStvSteth() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(false, true, 0, "Factory stETH Pool", "FSTETH");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(0);

        vm.startPrank(admin);
        uint256 gasBefore = gasleft();
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        uint256 gasUsedStart = gasBefore - gasleft();

        uint256 gasBeforeFinish = gasleft();
        wrapperFactory.createPoolFinish(intermediate);
        uint256 gasUsedFinish = gasBeforeFinish - gasleft();
        vm.stopPrank();

        emit log_named_uint("createPoolStart stv steth gas", gasUsedStart);
        emit log_named_uint("createPoolFinish stv steth gas", gasUsedFinish);
        assertLt(gasUsedStart, fusakaTxGasLimit, "createPoolStart stv steth gas exceeds Fusaka limit");
        assertLt(gasUsedFinish, fusakaTxGasLimit, "createPoolFinish stv steth gas exceeds Fusaka limit");
    }

    function test_createPoolStartGasConsumptionBelowFusakaLimitForStvGgv() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig
        ) = _buildConfigs(true, true, 0, "Factory Strategy Pool", "FSP");

        Factory.TimelockConfig memory timelockConfig = _defaultTimelockConfig();
        address strategyFactory = address(wrapperFactory.GGV_STRATEGY_FACTORY());

        vm.startPrank(admin);
        uint256 gasBefore = gasleft();
        Factory.StvPoolIntermediate memory intermediate = wrapperFactory.createPoolStart{value: connectDeposit}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
        );
        uint256 gasUsedStart = gasBefore - gasleft();

        uint256 gasBeforeFinish = gasleft();
        wrapperFactory.createPoolFinish(intermediate);
        uint256 gasUsedFinish = gasBeforeFinish - gasleft();
        vm.stopPrank();

        emit log_named_uint("createPoolStart stv ggv gas", gasUsedStart);
        emit log_named_uint("createPoolFinish stv ggv gas", gasUsedFinish);
        assertLt(gasUsedStart, fusakaTxGasLimit, "createPoolStart stv ggv gas exceeds Fusaka limit");
        assertLt(gasUsedFinish, fusakaTxGasLimit, "createPoolFinish stv ggv gas exceeds Fusaka limit");
    }
}
