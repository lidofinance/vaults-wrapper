// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {IVault} from "src/interfaces/mellow/IVault.sol";
import {MellowStrategy} from "src/strategy/MellowStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

contract MellowStrategyFactory is IStrategyFactory {
    bytes32 public immutable STRATEGY_ID = keccak256("strategy.mellow.v1");

    address public immutable VAULT;
    address public immutable SYNC_DEPOSIT_QUEUE;
    address public immutable ASYNC_DEPOSIT_QUEUE;
    address public immutable ASYNC_REDEEM_QUEUE;
    bool public immutable ALLOWLIST_ENABLED;
    address public immutable STRATEGY_CALL_FORWARDER_IMPLEMENTATION;

    constructor(
        address vault_,
        address syncDepositQueue_,
        address asyncDepositQueue_,
        address asyncRedeemQueue_,
        bool allowListEnabled_
    ) {
        VAULT = vault_;
        SYNC_DEPOSIT_QUEUE = syncDepositQueue_;
        ASYNC_DEPOSIT_QUEUE = asyncDepositQueue_;
        ASYNC_REDEEM_QUEUE = asyncRedeemQueue_;
        ALLOWLIST_ENABLED = allowListEnabled_;
        STRATEGY_CALL_FORWARDER_IMPLEMENTATION = address(new StrategyCallForwarder());
    }

    /// @inheritdoc IStrategyFactory
    function deploy(address pool, bytes calldata) external returns (address) {
        return address(
            new MellowStrategy(
                STRATEGY_ID,
                STRATEGY_CALL_FORWARDER_IMPLEMENTATION,
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
