// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {Factory} from "../src/Factory.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockVaultFactory} from "./mocks/MockVaultFactory.sol";

contract FactoryTest is Test {
    Factory public WrapperFactory;

    MockVaultHub public vaultHub;
    MockVaultFactory public vaultFactory;
    MockERC20 public stETH;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public operator = address(0x3);
    address public admin = address(0x4);

    uint256 public initialBalance = 100_000 wei;

    function setUp() public {
        vm.deal(user1, initialBalance);
        vm.deal(user2, initialBalance);
        vm.deal(admin, initialBalance);
        vm.deal(operator, initialBalance);

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
}
