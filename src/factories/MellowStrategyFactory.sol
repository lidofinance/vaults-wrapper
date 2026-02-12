// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StrategyCallForwarderFactory} from "./StrategyCallForwarderFactory.sol";
import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {IVault} from "src/interfaces/mellow/IVault.sol";
import {MellowStrategy} from "src/strategy/MellowStrategy.sol";

contract MellowStrategyFactory is IStrategyFactory {
    bytes32 public immutable STRATEGY_ID = keccak256("strategy.mellow.v1");

    address public immutable VAULT;
    address public immutable SYNC_DEPOSIT_QUEUE;
    address public immutable ASYNC_DEPOSIT_QUEUE;
    address public immutable ASYNC_REDEEM_QUEUE;
    bool public immutable ALLOWLIST_ENABLED;
    StrategyCallForwarderFactory public immutable STRATEGY_CALL_FORWARDER_FACTORY;

    constructor(
        address vault_,
        address syncDepositQueue_,
        address asyncDepositQueue_,
        address asyncRedeemQueue_,
        bool allowListEnabled_,
        StrategyCallForwarderFactory strategyCallForwarderFactory_
    ) {
        VAULT = vault_;
        SYNC_DEPOSIT_QUEUE = syncDepositQueue_;
        ASYNC_DEPOSIT_QUEUE = asyncDepositQueue_;
        ASYNC_REDEEM_QUEUE = asyncRedeemQueue_;
        ALLOWLIST_ENABLED = allowListEnabled_;
        STRATEGY_CALL_FORWARDER_FACTORY = strategyCallForwarderFactory_;
    }

    /// @inheritdoc IStrategyFactory
    function deploy(address pool, bytes calldata) external returns (address) {
        return address(
            new MellowStrategy(
                STRATEGY_ID,
                STRATEGY_CALL_FORWARDER_FACTORY.deploy(),
                pool,
                IVault(VAULT),
                SYNC_DEPOSIT_QUEUE,
                ASYNC_DEPOSIT_QUEUE,
                ASYNC_REDEEM_QUEUE,
                ALLOWLIST_ENABLED
            )
        );
    }
}
