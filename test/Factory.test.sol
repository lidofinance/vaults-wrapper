// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "../src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {StvStrategyPoolFactory} from "src/factories/StvStrategyPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";
import {BasePool} from "../src/BasePool.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {Distributor} from "../src/Distributor.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockDashboard} from "./mocks/MockDashboard.sol";
import {MockVaultFactory} from "./mocks/MockVaultFactory.sol";
import {MockLazyOracle} from "./mocks/MockLazyOracle.sol";

contract FactoryTest is Test {
    Factory public WrapperFactory;

    MockVaultHub public vaultHub;
    MockVaultFactory public vaultFactory;
    MockERC20 public stETH;
    MockERC20 public wstETH;
    MockLazyOracle public lazyOracle;

    address public admin = address(0x1);
    address public nodeOperator = address(0x2);
    address public nodeOperatorManager = address(0x3);

    address public strategyAddress = address(0x5555);

    uint256 public initialBalance = 100_000 wei;

    uint256 public connectDeposit = 1 ether;

    function setUp() public {
        vm.deal(admin, initialBalance + connectDeposit);
        vm.deal(nodeOperator, initialBalance);
        vm.deal(nodeOperatorManager, initialBalance);

        // Deploy mock contracts
        vaultHub = new MockVaultHub();
        vm.label(address(vaultHub), "VaultHub");

        vaultFactory = new MockVaultFactory(address(vaultHub));
        vm.label(address(vaultFactory), "VaultFactory");

        stETH = new MockERC20("Staked Ether", "stETH");
        vm.label(address(stETH), "stETH");

        wstETH = new MockERC20("Wrapped Staked Ether", "wstETH");
        vm.label(address(wstETH), "wstETH");

        lazyOracle = new MockLazyOracle();

        // Deploy dedicated implementation factories and the main Factory
        StvPoolFactory waf = new StvPoolFactory();
        StvStETHPoolFactory wbf = new StvStETHPoolFactory();
        StvStrategyPoolFactory wcf = new StvStrategyPoolFactory();
        WithdrawalQueueFactory wqf = new WithdrawalQueueFactory();
        DistributorFactory df = new DistributorFactory();
        LoopStrategyFactory lsf = new LoopStrategyFactory();
        GGVStrategyFactory ggvf = new GGVStrategyFactory();
        address dummy = address(new DummyImplementation());
        address timelockFactory = address(new TimelockFactory());

        Factory.WrapperConfig memory a = Factory.WrapperConfig({
            vaultFactory: address(vaultFactory),
            steth: address(stETH),
            wsteth: address(wstETH),
            lazyOracle: address(lazyOracle),
            stvPoolFactory: address(waf),
            stvStETHPoolFactory: address(wbf),
            stvStrategyPoolFactory: address(wcf),
            withdrawalQueueFactory: address(wqf),
            distributorFactory: address(df),
            loopStrategyFactory: address(lsf),
            ggvStrategyFactory: address(ggvf),
            dummyImplementation: dummy,
            timelockFactory: timelockFactory
        });
        WrapperFactory = new Factory(
            a,
            Factory.TimelockConfig({
                minDelaySeconds: 0
            })
        );
    }

    function test_canCreatePool() public {
        vm.startPrank(admin);
        (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor) = WrapperFactory
            .createVaultWithNoMintingNoStrategy{value: connectDeposit}(
            nodeOperator,
            nodeOperatorManager,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            30 days,
            1 days,
            false // allowlist disabled
        );

        BasePool pool = BasePool(poolProxy);
        WithdrawalQueue withdrawalQueue = WithdrawalQueue(payable(withdrawalQueueProxy));

        assertEq(address(pool.STAKING_VAULT()), address(vault));
        assertEq(address(pool.DASHBOARD()), address(dashboard));
        assertEq(address(pool.WITHDRAWAL_QUEUE()), address(withdrawalQueue));
        assertEq(address(pool.DISTRIBUTOR()), address(distributor));
        // StvPool doesn't have a STRATEGY field

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));
        Distributor distributor_ = Distributor(distributor);

        assertTrue(
            mockDashboard.hasRole(
                mockDashboard.DEFAULT_ADMIN_ROLE(),
                admin // admin is now the owner, not the pool
            )
        );

        assertFalse(mockDashboard.hasRole(mockDashboard.DEFAULT_ADMIN_ROLE(), address(WrapperFactory)));

        assertFalse(distributor_.hasRole(distributor_.DEFAULT_ADMIN_ROLE(), address(WrapperFactory)), "Distributor default admin should be revoked");
        assertFalse(distributor_.hasRole(distributor_.MANAGER_ROLE(), address(WrapperFactory)), "Distributor manager role should be revoked");
        assertTrue(distributor_.hasRole(distributor_.DEFAULT_ADMIN_ROLE(), admin), "Distributor default admin should be granted to admin");
        assertTrue(distributor_.hasRole(distributor_.MANAGER_ROLE(), admin), "Distributor manager role should be granted to admin");
    }

    function test_revertWithoutConnectDeposit() public {
        vm.startPrank(admin);
        vm.expectRevert("InsufficientFunds()");
        WrapperFactory.createVaultWithNoMintingNoStrategy(
            nodeOperator,
            nodeOperatorManager,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            30 days,
            1 days,
            false // allowlist disabled
        );
    }

    function test_canCreateWithStrategy() public {
        vm.startPrank(admin);
        (, address dashboard, address payable poolProxy,, address strategy, /** distributor */) = WrapperFactory
            .createVaultWithLoopStrategy{value: connectDeposit}(
            nodeOperator,
            nodeOperatorManager,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            30 days,
            1 days,
            false, // allowlist disabled
            0, // reserve ratio gap
            1 // loops
        );

        BasePool pool = BasePool(poolProxy);

        // Strategy is deployed internally for loop strategy and added to allowlist
        assertTrue(strategy != address(0));
        assertTrue(pool.isAllowListed(strategy));

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));

        assertTrue(mockDashboard.hasRole(mockDashboard.MINT_ROLE(), address(pool)));

        assertTrue(mockDashboard.hasRole(mockDashboard.BURN_ROLE(), address(pool)));
    }

    function test_allowlistEnabled() public {
        vm.startPrank(admin);
        (,, address payable poolProxy, /** withdrawalQueueProxy */ , /** distributor */) = WrapperFactory.createVaultWithNoMintingNoStrategy{value: connectDeposit}(
            nodeOperator,
            nodeOperatorManager,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            30 days,
            1 days,
            true // allowlist enabled
        );

        BasePool pool = BasePool(poolProxy);
        assertTrue(pool.ALLOW_LIST_ENABLED());
    }
}
