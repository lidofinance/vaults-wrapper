// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

abstract contract Strategy is IStrategy {

    IERC20 public immutable STETH;
    address public immutable STRATEGY_PROXY_IMPL;

    mapping(bytes32 salt => address proxy) public userStrategyProxy;

    error ZeroAddress();

    constructor(address _stETH, address _strategyProxyImpl) {
        STETH = IERC20(_stETH);
        STRATEGY_PROXY_IMPL = _strategyProxyImpl;
    }

    /// @notice Returns the strategy id
    /// @return The strategy id
    function strategyId() public pure virtual returns (bytes32);

    /// @notice Returns the address of the strategy proxy for a given user
    /// @param user The user for which to get the strategy proxy address
    /// @return proxy The address of the strategy proxy
    function getStrategyProxyAddress(address user) public view returns (address proxy) {
        bytes32 salt = keccak256(abi.encode(strategyId(), address(this), user));
        proxy = Clones.predictDeterministicAddress(STRATEGY_PROXY_IMPL, salt);
    }

    function _getOrCreateProxy(address user) internal returns (address proxy) {
        if (user == address(0)) revert ZeroAddress();

        bytes32 salt = keccak256(abi.encode(strategyId(), address(this), user));
        proxy = userStrategyProxy[salt];
        if (proxy != address(0)) return proxy;

        proxy = Clones.cloneDeterministic(STRATEGY_PROXY_IMPL, salt);
        IStrategyProxy(proxy).initialize(address(this));
        userStrategyProxy[salt] = proxy;

        return proxy;
    }
}