// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {StvStrategyPoolFactory} from "src/factories/StvStrategyPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";

contract FactoryHelper {
    address public immutable DUMMY_IMPLEMENTATION;
    address public immutable WRAPPER_A_FACTORY;
    address public immutable WRAPPER_B_FACTORY;
    address public immutable WRAPPER_C_FACTORY;
    address public immutable WITHDRAWAL_QUEUE_FACTORY;
    address public immutable DISTRIBUTOR_FACTORY;
    address public immutable LOOP_STRATEGY_FACTORY;
    address public immutable GGV_STRATEGY_FACTORY;
    address public immutable TIMELOCK_FACTORY;

    constructor() {
        DUMMY_IMPLEMENTATION = address(new DummyImplementation());
        WRAPPER_A_FACTORY = address(new StvPoolFactory());
        WRAPPER_B_FACTORY = address(new StvStETHPoolFactory());
        WRAPPER_C_FACTORY = address(new StvStrategyPoolFactory());
        WITHDRAWAL_QUEUE_FACTORY = address(new WithdrawalQueueFactory());
        DISTRIBUTOR_FACTORY = address(new DistributorFactory());
        LOOP_STRATEGY_FACTORY = address(new LoopStrategyFactory());
        GGV_STRATEGY_FACTORY = address(new GGVStrategyFactory());
        TIMELOCK_FACTORY = address(new TimelockFactory());
    }

    /// @notice Deploy main Factory with freshly deployed impl factories
    function deployMainFactory(address _vaultFactory, address _steth, address _wsteth, address _lazyOracle)
        external
        returns (Factory factory)
    {
        Factory.PoolConfig memory a = Factory.PoolConfig({
            vaultFactory: _vaultFactory,
            steth: _steth,
            wsteth: _wsteth,
            lazyOracle: _lazyOracle,
            stvPoolFactory: WRAPPER_A_FACTORY,
            stvStETHPoolFactory: WRAPPER_B_FACTORY,
            stvStrategyPoolFactory: WRAPPER_C_FACTORY,
            withdrawalQueueFactory: WITHDRAWAL_QUEUE_FACTORY,
            distributorFactory: DISTRIBUTOR_FACTORY,
            loopStrategyFactory: LOOP_STRATEGY_FACTORY,
            ggvStrategyFactory: GGV_STRATEGY_FACTORY,
            dummyImplementation: DUMMY_IMPLEMENTATION,
            timelockFactory: TIMELOCK_FACTORY
        });
        factory = new Factory(
            a,
            Factory.TimelockConfig({
                minDelaySeconds: 7 days
            })
        );
    }

    /// @notice Deploy LoopStrategy implementation
    /// @param _steth Address of stETH token
    /// @param _pool Address of the pool (StvStrategyPool proxy or implementation)
    /// @param _loops Number of leverage loops
    /// @return impl Address of the deployed LoopStrategy
    function deployLoopStrategy(address _steth, address _pool, uint256 _loops) external returns (address impl) {
        impl = LoopStrategyFactory(LOOP_STRATEGY_FACTORY).deploy(_steth, _pool, _loops);
    }

    /// @notice Deploy GGVStrategy implementation
    /// @param _steth Address of stETH token
    /// @param _teller Address of GGV Teller contract
    /// @param _boringQueue Address of Boring On-Chain Queue
    /// @return impl Address of the deployed GGVStrategy
    function deployGGVStrategy(address _pool, address _steth, address _wsteth, address _teller, address _boringQueue)
        external
        returns (address impl)
    {
        impl = GGVStrategyFactory(GGV_STRATEGY_FACTORY).deploy(_pool, _steth, _wsteth, _teller, _boringQueue);
    }
}
