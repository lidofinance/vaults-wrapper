// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Factory} from "src/Factory.sol";
import {WrapperBase} from "src/WrapperBase.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperB} from "src/WrapperB.sol";
import {WrapperC} from "src/WrapperC.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {WrapperAFactory} from "src/factories/WrapperAFactory.sol";
import {WrapperBFactory} from "src/factories/WrapperBFactory.sol";
import {WrapperCFactory} from "src/factories/WrapperCFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";

contract FactoryHelper {

    address public immutable DUMMY_IMPLEMENTATION;
    address public immutable WRAPPER_A_FACTORY;
    address public immutable WRAPPER_B_FACTORY;
    address public immutable WRAPPER_C_FACTORY;
    address public immutable WITHDRAWAL_QUEUE_FACTORY;
    address public immutable LOOP_STRATEGY_FACTORY;
    address public immutable GGV_STRATEGY_FACTORY;

    constructor() {
        DUMMY_IMPLEMENTATION = address(new DummyImplementation());
        WRAPPER_A_FACTORY = address(new WrapperAFactory());
        WRAPPER_B_FACTORY = address(new WrapperBFactory());
        WRAPPER_C_FACTORY = address(new WrapperCFactory());
        WITHDRAWAL_QUEUE_FACTORY = address(new WithdrawalQueueFactory());
        LOOP_STRATEGY_FACTORY = address(new LoopStrategyFactory());
        GGV_STRATEGY_FACTORY = address(new GGVStrategyFactory());
    }

    /// @notice Deploy main Factory with freshly deployed impl factories
    function deployMainFactory(address _vaultFactory, address _steth, address _wsteth, address _lazyOracle)
        external
        returns (
            Factory factory
        )
    {
        Factory.WrapperConfig memory a = Factory.WrapperConfig({
            vaultFactory: _vaultFactory,
            steth: _steth,
            lazyOracle: _lazyOracle,
            wrapperAFactory: WRAPPER_A_FACTORY,
            wrapperBFactory: WRAPPER_B_FACTORY,
            wrapperCFactory: WRAPPER_C_FACTORY,
            withdrawalQueueFactory: WITHDRAWAL_QUEUE_FACTORY,
            loopStrategyFactory: LOOP_STRATEGY_FACTORY,
            ggvStrategyFactory: GGV_STRATEGY_FACTORY,
            dummyImplementation: DUMMY_IMPLEMENTATION
        });
        factory = new Factory(a);
    }

    /// @notice Deploy LoopStrategy implementation
    /// @param _steth Address of stETH token
    /// @param _wrapper Address of the wrapper (WrapperC proxy or implementation)
    /// @param _loops Number of leverage loops
    /// @return impl Address of the deployed LoopStrategy
    function deployLoopStrategy(
        address _steth,
        address _wrapper,
        uint256 _loops
    ) external returns (address impl) {
        impl = LoopStrategyFactory(LOOP_STRATEGY_FACTORY).deploy(_steth, _wrapper, _loops);
    }

    /// @notice Deploy GGVStrategy implementation
    /// @param _steth Address of stETH token
    /// @param _teller Address of GGV Teller contract
    /// @param _boringQueue Address of Boring On-Chain Queue
    /// @return impl Address of the deployed GGVStrategy
    function deployGGVStrategy(
        address _wrapper,
        address _steth,
        address _teller,
        address _boringQueue
    ) external returns (address impl) {
        impl = GGVStrategyFactory(GGV_STRATEGY_FACTORY).deploy(_wrapper, _steth, _teller, _boringQueue);
    }
}
