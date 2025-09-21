// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {WrapperC} from "src/WrapperC.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";
abstract contract Strategy is IStrategy {

    WrapperC public immutable WRAPPER;
    IStETH public immutable STETH;
    IWstETH public immutable WSTETH;
    address public immutable STRATEGY_PROXY_IMPL;

    mapping(bytes32 salt => address proxy) public userStrategyProxy;

    error ZeroAddress();

    constructor(address _wrapper, address _stETH, address _wstETH, address _strategyProxyImpl) {
        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        STRATEGY_PROXY_IMPL = _strategyProxyImpl;
        WRAPPER = WrapperC(payable(_wrapper));
    }

    /// @notice Returns the strategy id
    /// @return The strategy id
    function strategyId() public pure virtual returns (bytes32);

    /// @notice Returns the address of the strategy proxy for a given user
    /// @param user The user for which to get the strategy proxy address
    /// @return proxy The address of the strategy proxy
    function getStrategyProxyAddress(address user) public view returns (address proxy) {
        bytes32 salt = _generateSalt(user);
        proxy = Clones.predictDeterministicAddress(STRATEGY_PROXY_IMPL, salt);
    }

    function _getOrCreateProxy(address user) internal returns (address proxy) {
        if (user == address(0)) revert ZeroAddress();

        bytes32 salt = _generateSalt(user);
        proxy = userStrategyProxy[salt];
        if (proxy != address(0)) return proxy;

        proxy = Clones.cloneDeterministic(STRATEGY_PROXY_IMPL, salt);
        IStrategyProxy(proxy).initialize(address(this));
        userStrategyProxy[salt] = proxy;

        return proxy;
    }

    function _generateSalt(address user) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encode(strategyId(), address(this), user));
    }
}