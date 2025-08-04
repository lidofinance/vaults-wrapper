// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "../src/Factory.sol";
import {Wrapper} from "../src/Wrapper.sol";
import {Escrow} from "../src/Escrow.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockVaultFactory} from "./mocks/MockVaultFactory.sol";

contract FactoryTest is Test {
    Factory public WrapperFactory;

    MockVaultHub public vaultHub;
    MockVaultFactory public vaultFactory;
    MockERC20 public stETH;

    address public admin = address(0x1);
    address public nodeOperator = address(0x2);
    address public nodeOperatorManager = address(0x3);

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
            Wrapper wrapper,
            WithdrawalQueue withdrawalQueue,
            Escrow escrow
        ) = WrapperFactory.createVaultWithWrapper{value: connectDeposit}(
                nodeOperator,
                nodeOperatorManager,
                100, // 1% fee
                3600, // 1 hour confirm expiry
                address(0), // no strategy for this test
                "Test Vault",
                "TVLT"
            );
        assertEq(address(wrapper.STAKING_VAULT()), address(vault));
        assertEq(address(wrapper.DASHBOARD()), address(dashboard));
        assertEq(address(wrapper.withdrawalQueue()), address(withdrawalQueue));
        assertEq(address(escrow), address(0)); // no escrow created
        assertEq(address(wrapper.ESCROW()), address(0));
    }
}
