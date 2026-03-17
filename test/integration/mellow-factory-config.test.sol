// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IQueue} from "src/interfaces/mellow/IQueue.sol";
import {ISyncDepositQueue} from "src/interfaces/mellow/ISyncDepositQueue.sol";
import {IVault} from "src/interfaces/mellow/IVault.sol";
import {MellowStrategyFactory} from "src/factories/MellowStrategyFactory.sol";

import {StvPoolHarness} from "test/utils/StvPoolHarness.sol";

contract MellowFactoryConfigTest is StvPoolHarness {
    MellowStrategyFactory public factory;
    IVault public vault;

    function setUp() public {
        _initializeCore();

        address factoryAddr = vm.envAddress("MELLOW_STRATEGY_FACTORY");
        factory = MellowStrategyFactory(factoryAddr);
        vault = IVault(factory.VAULT());
    }

    function testSyncDepositQueue() public view {
        address queue = factory.SYNC_DEPOSIT_QUEUE();
        if (queue == address(0)) return;

        assertTrue(vault.hasQueue(queue), "syncDepositQueue: not registered in vault");
        assertTrue(vault.isDepositQueue(queue), "syncDepositQueue: not a deposit queue");
        assertEq(IQueue(queue).asset(), address(wsteth), "syncDepositQueue: wrong asset");
        assertTrue(
            Strings.equal(ISyncDepositQueue(queue).name(), "SyncDepositQueue"),
            "syncDepositQueue: name mismatch"
        );
    }

    function testAsyncDepositQueue() public view {
        address queue = factory.ASYNC_DEPOSIT_QUEUE();
        if (queue == address(0)) return;

        assertTrue(vault.hasQueue(queue), "asyncDepositQueue: not registered in vault");
        assertTrue(vault.isDepositQueue(queue), "asyncDepositQueue: not a deposit queue");
        assertEq(IQueue(queue).asset(), address(wsteth), "asyncDepositQueue: wrong asset");
    }

    function testAsyncRedeemQueue() public view {
        address queue = factory.ASYNC_REDEEM_QUEUE();

        assertTrue(queue != address(0), "asyncRedeemQueue: zero address");
        assertTrue(vault.hasQueue(queue), "asyncRedeemQueue: not registered in vault");
        assertFalse(vault.isDepositQueue(queue), "asyncRedeemQueue: should not be a deposit queue");
        assertEq(IQueue(queue).asset(), address(wsteth), "asyncRedeemQueue: wrong asset");
    }

    function testAtLeastOneDepositQueue() public view {
        assertTrue(
            factory.SYNC_DEPOSIT_QUEUE() != address(0) || factory.ASYNC_DEPOSIT_QUEUE() != address(0),
            "at least one deposit queue must be configured"
        );
    }
}
