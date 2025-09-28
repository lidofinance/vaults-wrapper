// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "../src/Factory.sol";
import {WrapperAFactory} from "src/factories/WrapperAFactory.sol";
import {WrapperBFactory} from "src/factories/WrapperBFactory.sol";
import {WrapperCFactory} from "src/factories/WrapperCFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {WrapperBase} from "../src/WrapperBase.sol";
import {WrapperA} from "../src/WrapperA.sol";
import {WrapperC} from "../src/WrapperC.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";

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
        WrapperAFactory waf = new WrapperAFactory();
        WrapperBFactory wbf = new WrapperBFactory();
        WrapperCFactory wcf = new WrapperCFactory();
        WithdrawalQueueFactory wqf = new WithdrawalQueueFactory();
        LoopStrategyFactory lsf = new LoopStrategyFactory();
        GGVStrategyFactory ggvf = new GGVStrategyFactory();
        address dummy = address(new DummyImplementation());

        Factory.WrapperConfig memory a = Factory.WrapperConfig({
            vaultFactory: address(vaultFactory),
            steth: address(stETH),
            wsteth: address(wstETH),
            lazyOracle: address(lazyOracle),
            wrapperAFactory: address(waf),
            wrapperBFactory: address(wbf),
            wrapperCFactory: address(wcf),
            withdrawalQueueFactory: address(wqf),
            loopStrategyFactory: address(lsf),
            ggvStrategyFactory: address(ggvf),
            dummyImplementation: dummy
        });
        WrapperFactory = new Factory(a);
    }

    function test_canCreateWrapper() public {
        vm.startPrank(admin);
        (
            address vault,
            address dashboard,
            address payable wrapperProxy,
            address withdrawalQueueProxy
        ) = WrapperFactory.createVaultWithNoMintingNoStrategy{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                nodeOperator,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                30 days,
                false // allowlist disabled
            );

        WrapperBase wrapper = WrapperBase(wrapperProxy);
        WithdrawalQueue withdrawalQueue = WithdrawalQueue(payable(withdrawalQueueProxy));

        assertEq(address(wrapper.STAKING_VAULT()), address(vault));
        assertEq(address(wrapper.DASHBOARD()), address(dashboard));
        assertEq(address(wrapper.WITHDRAWAL_QUEUE()), address(withdrawalQueue));
        // WrapperA doesn't have a STRATEGY field

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));

        assertTrue(
            mockDashboard.hasRole(
                mockDashboard.DEFAULT_ADMIN_ROLE(),
                admin // admin is now the owner, not the wrapper
            )
        );

        assertFalse(
            mockDashboard.hasRole(
                mockDashboard.DEFAULT_ADMIN_ROLE(),
                address(WrapperFactory)
            )
        );
    }

    function test_revertWithoutConnectDeposit() public {
        vm.startPrank(admin);
        vm.expectRevert("InsufficientFunds()");
        WrapperFactory.createVaultWithNoMintingNoStrategy(
            nodeOperator,
            nodeOperatorManager,
            nodeOperator,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            30 days,
            false // allowlist disabled
        );
    }

    function test_canCreateWithStrategy() public {
        vm.startPrank(admin);
        (
            address vault,
            address dashboard,
            address payable wrapperProxy,
            address withdrawalQueueProxy
        ) = WrapperFactory.createVaultWithLoopStrategy{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                nodeOperator,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                30 days,
                false, // allowlist disabled
                0, // reserve ratio gap
                1 // loops
            );

        WrapperBase wrapper = WrapperBase(wrapperProxy);
        WithdrawalQueue withdrawalQueue = WithdrawalQueue(payable(withdrawalQueueProxy));

        WrapperC wrapperC = WrapperC(payable(address(wrapper)));
        // Strategy is deployed internally for loop strategy
        assertTrue(address(wrapperC.STRATEGY()) != address(0));

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));

        assertTrue(
            mockDashboard.hasRole(mockDashboard.MINT_ROLE(), address(wrapper))
        );

        assertTrue(
            mockDashboard.hasRole(mockDashboard.BURN_ROLE(), address(wrapper))
        );
    }

    function test_allowlistEnabled() public {
        vm.startPrank(admin);
        (
            ,
            ,
            address payable wrapperProxy,

        ) = WrapperFactory.createVaultWithNoMintingNoStrategy{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                nodeOperator,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                30 days,
                true // allowlist enabled
            );

        WrapperBase wrapper = WrapperBase(wrapperProxy);
        assertTrue(wrapper.ALLOW_LIST_ENABLED());
    }

}