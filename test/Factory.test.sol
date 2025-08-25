// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "../src/Factory.sol";
import {WrapperBase} from "../src/WrapperBase.sol";
import {WrapperA} from "../src/WrapperA.sol";
import {WrapperC} from "../src/WrapperC.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockDashboard} from "./mocks/MockDashboard.sol";
import {MockVaultFactory} from "./mocks/MockVaultFactory.sol";

contract FactoryTest is Test {
    Factory public WrapperFactory;

    MockVaultHub public vaultHub;
    MockVaultFactory public vaultFactory;
    MockERC20 public stETH;

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

        // Deploy the Factory contract
        WrapperFactory = new Factory(address(vaultFactory), address(stETH));
    }

    function test_canCreateWrapper() public {
        vm.startPrank(admin);
        (
            address vault,
            address dashboard,
            WrapperBase wrapper,
            WithdrawalQueue withdrawalQueue
        ) = WrapperFactory.createVaultWithWrapper{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                Factory.WrapperConfiguration.NO_MINTING_NO_STRATEGY,
                address(0) // no strategy for this test
            );
        assertEq(address(wrapper.STAKING_VAULT()), address(vault));
        assertEq(address(wrapper.DASHBOARD()), address(dashboard));
        assertEq(address(wrapper.withdrawalQueue()), address(withdrawalQueue));
        // WrapperA doesn't have a STRATEGY field

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));

        assertTrue(
            mockDashboard.hasRole(
                mockDashboard.DEFAULT_ADMIN_ROLE(),
                address(wrapper)
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
        WrapperFactory.createVaultWithWrapper(
            nodeOperator,
            nodeOperatorManager,
            100, // 1% fee
            3600, // 1 hour confirm expiry
            Factory.WrapperConfiguration.NO_MINTING_NO_STRATEGY,
            address(0) // no strategy for this test
        );
    }

    function test_canCreateWithStrategy() public {
        vm.startPrank(admin);
        (
            address vault,
            address dashboard,
            WrapperBase wrapper,
            WithdrawalQueue withdrawalQueue
        ) = WrapperFactory.createVaultWithWrapper{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                Factory.WrapperConfiguration.MINTING_AND_STRATEGY,
                strategyAddress // strategy for this test
            );
        // Cast to WrapperC to access STRATEGY
        WrapperC wrapperC = WrapperC(payable(address(wrapper)));
        assertEq(address(wrapperC.STRATEGY()), strategyAddress);

        MockDashboard mockDashboard = MockDashboard(payable(dashboard));

        assertTrue(
            mockDashboard.hasRole(mockDashboard.MINT_ROLE(), address(wrapper))
        );

        assertTrue(
            mockDashboard.hasRole(mockDashboard.BURN_ROLE(), address(wrapper))
        );
    }
}
