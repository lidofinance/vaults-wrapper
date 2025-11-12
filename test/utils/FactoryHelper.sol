// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";
import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";

contract FactoryHelper {
    Factory.SubFactories public subFactories;
    Factory.TimelockConfig public defaultTimelockConfig;

    constructor() {
        address dummyTeller = address(new DummyImplementation());
        address dummyQueue = address(new DummyImplementation());
        address dummySteth = address(new DummyImplementation());
        address dummyWsteth = address(new DummyImplementation());

        subFactories.stvPoolFactory = address(new StvPoolFactory());
        subFactories.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        subFactories.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        subFactories.distributorFactory = address(new DistributorFactory());
        subFactories.ggvStrategyFactory = address(new GGVStrategyFactory(dummyTeller, dummyQueue, dummySteth, dummyWsteth));
        subFactories.timelockFactory = address(new TimelockFactory());

        defaultTimelockConfig = Factory.TimelockConfig({
            minDelaySeconds: 7 days,
            executor: address(this)
        });
    }

    function deployMainFactory(address locatorAddress) external returns (Factory factory) {
        factory = new Factory(locatorAddress, subFactories);
    }

    function deployMainFactory(
        address locatorAddress,
        address ggvTeller,
        address ggvBoringQueue
    ) external returns (Factory factory) {
        Factory.SubFactories memory factories = subFactories;
        if (ggvTeller != address(0) && ggvBoringQueue != address(0)) {
            ILidoLocator locator = ILidoLocator(locatorAddress);
            address steth = address(locator.lido());
            address wsteth = address(locator.wstETH());
            factories.ggvStrategyFactory = address(new GGVStrategyFactory(ggvTeller, ggvBoringQueue, steth, wsteth));
        }

        factory = new Factory(locatorAddress, factories);
    }
}
