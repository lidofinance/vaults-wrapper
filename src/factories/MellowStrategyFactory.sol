// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {IVault} from "src/interfaces/mellow/IVault.sol";
import {MellowStrategy} from "src/strategy/MellowStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

contract MellowStrategyFactory is IStrategyFactory {
    bytes32 public immutable STRATEGY_ID = keccak256("strategy.mellow.v1");

    /// @inheritdoc IStrategyFactory
    function deploy(address pool, bytes calldata deployBytes) external returns (address impl) {
        (IVault vault, address syncDepositQueue, address asyncDepositQueue, address asyncRedeemQueue) =
            abi.decode(deployBytes, (IVault, address, address, address));

        address strategyCallForwarderImpl = address(new StrategyCallForwarder());
        bytes32 salt = keccak256(
            abi.encode(
                STRATEGY_ID,
                strategyCallForwarderImpl,
                pool,
                vault,
                syncDepositQueue,
                asyncDepositQueue,
                asyncRedeemQueue
            )
        );
        impl = address(
            new MellowStrategy{salt: salt}(
                STRATEGY_ID,
                strategyCallForwarderImpl,
                pool,
                vault,
                syncDepositQueue,
                asyncDepositQueue,
                asyncRedeemQueue
            )
        );
    }
}
