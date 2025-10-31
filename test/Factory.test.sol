// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";

import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Distributor} from "src/Distributor.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {MockDashboard} from "test/mocks/MockDashboard.sol";
import {MockVaultFactory} from "test/mocks/MockVaultFactory.sol";
import {MockLazyOracle} from "test/mocks/MockLazyOracle.sol";
import {MockLidoLocator} from "test/mocks/MockLidoLocator.sol";

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

    function setUp() public {
        vaultHub = new MockVaultHub();
        vaultFactory = new MockVaultFactory(address(vaultHub));
        stETH = new MockERC20("Staked Ether", "stETH");
        wstETH = new MockERC20("Wrapped Staked Ether", "wstETH");
        lazyOracle = new MockLazyOracle();

        locator = new MockLidoLocator(
            address(stETH),
            address(wstETH),
            address(lazyOracle),
            address(vaultHub),
            address(vaultFactory)
        );

        Factory.SubFactories memory subFactories;
        subFactories.stvPoolFactory = address(new StvPoolFactory());
        subFactories.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        subFactories.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        subFactories.distributorFactory = address(new DistributorFactory());
        subFactories.loopStrategyFactory = address(new LoopStrategyFactory());
        subFactories.ggvStrategyFactory = address(new GGVStrategyFactory());
        subFactories.timelockFactory = address(new TimelockFactory());

        Factory.TimelockConfig memory timelockConfig = Factory.TimelockConfig({
            minDelaySeconds: 0,
            executor: admin
        });

        Factory.StrategyParameters memory strategyParams = Factory.StrategyParameters({
            ggvTeller: address(0x1111),
            ggvBoringOnChainQueue: address(0x2222)
        });

        wrapperFactory = new Factory(address(locator), subFactories, timelockConfig, strategyParams);

        vm.deal(admin, 100 ether);
    }

    function _basePoolConfig(bool allowlistEnabled, bool mintingEnabled, uint256 reserveRatioGapBP)
        internal
        view
        returns (Factory.PoolFullConfig memory)
    {
        return Factory.PoolFullConfig({
            allowlistEnabled: allowlistEnabled,
            mintingEnabled: mintingEnabled,
            owner: admin,
            nodeOperator: nodeOperator,
            nodeOperatorManager: nodeOperatorManager,
            nodeOperatorFeeBP: 100,
            confirmExpiry: 3600,
            maxFinalizationTime: 30 days,
            minWithdrawalDelayTime: 1 days,
            reserveRatioGapBP: reserveRatioGapBP
        });
    }

    function test_canCreatePool() public {
        Factory.PoolFullConfig memory poolConfig = _basePoolConfig(false, false, 0);
        Factory.StrategyConfig memory strategyConfig = Factory.StrategyConfig({factory: address(0)});

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate =
            wrapperFactory.createPoolStart{value: connectDeposit}(poolConfig, strategyConfig);
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate, strategyConfig);
        vm.stopPrank();

        StvPool pool = StvPool(payable(deployment.pool));
        WithdrawalQueue withdrawalQueue = WithdrawalQueue(payable(deployment.withdrawalQueue));
        IDashboard dashboard = IDashboard(payable(intermediate.dashboard));
        Distributor distributor = pool.DISTRIBUTOR();

        assertEq(address(pool.DASHBOARD()), address(dashboard));
        assertEq(address(pool.WITHDRAWAL_QUEUE()), address(withdrawalQueue));
        assertEq(address(pool.DISTRIBUTOR()), address(distributor));

        address vault = address(dashboard.stakingVault());
        assertEq(address(pool.STAKING_VAULT()), vault);

        MockDashboard mockDashboard = MockDashboard(payable(address(dashboard)));
        assertTrue(mockDashboard.hasRole(mockDashboard.DEFAULT_ADMIN_ROLE(), intermediate.timelock));

        assertEq(pool.ALLOW_LIST_ENABLED(), false);
    }

    function test_revertWithoutConnectDeposit() public {
        Factory.PoolFullConfig memory poolConfig = _basePoolConfig(false, false, 0);
        Factory.StrategyConfig memory strategyConfig = Factory.StrategyConfig({factory: address(0)});

        vm.startPrank(admin);
        vm.expectRevert();
        wrapperFactory.createPoolStart(poolConfig, strategyConfig);
        vm.stopPrank();
    }

    function test_canCreateWithStrategy() public {
        Factory.PoolFullConfig memory poolConfig = _basePoolConfig(true, true, 0);
        Factory.StrategyConfig memory strategyConfig = Factory.StrategyConfig({
            factory: address(wrapperFactory.GGV_STRATEGY_FACTORY())
        });

        address ggvFactory = address(wrapperFactory.GGV_STRATEGY_FACTORY());

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate =
            wrapperFactory.createPoolStart{value: connectDeposit}(poolConfig, strategyConfig);
        uint256 nonceBefore = vm.getNonce(ggvFactory);
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate, strategyConfig);
        vm.stopPrank();

        StvStETHPool pool = StvStETHPool(payable(deployment.pool));

        uint256 nonceAfter = vm.getNonce(ggvFactory);
        address strategy = address(0);
        if (nonceAfter > nonceBefore) {
            uint256 creations = nonceAfter - nonceBefore;
            uint256 guessNonce = creations > 1 ? nonceBefore + creations - 1 : nonceBefore;
            strategy = vm.computeCreateAddress(ggvFactory, guessNonce);
        }

        assertTrue(strategy != address(0));
        assertTrue(pool.isAllowListed(strategy));

        MockDashboard mockDashboard = MockDashboard(payable(intermediate.dashboard));
        assertTrue(mockDashboard.hasRole(mockDashboard.MINT_ROLE(), address(pool)));
        assertTrue(mockDashboard.hasRole(mockDashboard.BURN_ROLE(), address(pool)));
    }

    function test_allowlistEnabled() public {
        Factory.PoolFullConfig memory poolConfig = _basePoolConfig(true, false, 0);
        Factory.StrategyConfig memory strategyConfig = Factory.StrategyConfig({factory: address(0)});

        vm.startPrank(admin);
        Factory.StvPoolIntermediate memory intermediate =
            wrapperFactory.createPoolStart{value: connectDeposit}(poolConfig, strategyConfig);
        Factory.StvPoolDeployment memory deployment = wrapperFactory.createPoolFinish(intermediate, strategyConfig);
        vm.stopPrank();

        StvPool pool = StvPool(payable(deployment.pool));
        assertTrue(pool.ALLOW_LIST_ENABLED());
    }
}
