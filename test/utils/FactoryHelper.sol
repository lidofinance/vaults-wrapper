// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";

contract FactoryHelper {
    Factory.SubFactories public subFactories;
    Factory.TimelockConfig public defaultTimelockConfig;
    Factory.StrategyParameters public defaultStrategyParameters;

    constructor() {
        subFactories.stvPoolFactory = address(new StvPoolFactory());
        subFactories.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        subFactories.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        subFactories.distributorFactory = address(new DistributorFactory());
        subFactories.loopStrategyFactory = address(new LoopStrategyFactory());
        subFactories.ggvStrategyFactory = address(new GGVStrategyFactory());
        subFactories.timelockFactory = address(new TimelockFactory());

        defaultTimelockConfig = Factory.TimelockConfig({
            minDelaySeconds: 7 days,
            executor: address(this)
        });

        defaultStrategyParameters = Factory.StrategyParameters({
            ggvTeller: address(new DummyImplementation()),
            ggvBoringOnChainQueue: address(new DummyImplementation())
        });
    }

    function deployMainFactory(address locatorAddress) external returns (Factory factory) {
        factory = new Factory(locatorAddress, subFactories, defaultTimelockConfig, defaultStrategyParameters);
    }

    function deployMainFactory(
        address locatorAddress,
        Factory.StrategyParameters memory strategyParams,
        Factory.TimelockConfig memory timelockConfig
    ) external returns (Factory factory) {
        if (strategyParams.ggvTeller == address(0)) {
            strategyParams.ggvTeller = defaultStrategyParameters.ggvTeller;
        }
        if (strategyParams.ggvBoringOnChainQueue == address(0)) {
            strategyParams.ggvBoringOnChainQueue = defaultStrategyParameters.ggvBoringOnChainQueue;
        }
        if (timelockConfig.executor == address(0)) {
            timelockConfig.executor = defaultTimelockConfig.executor;
        }
        if (timelockConfig.minDelaySeconds == 0) {
            timelockConfig.minDelaySeconds = defaultTimelockConfig.minDelaySeconds;
        }

        factory = new Factory(locatorAddress, subFactories, timelockConfig, strategyParams);
    }
}
