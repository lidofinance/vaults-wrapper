// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


import {IStETH} from "src/interfaces/IStETH.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";
import {StvStrategyPool} from "src/StvStrategyPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";

abstract contract Strategy is IStrategy {
    StvStETHPool public immutable POOL;
    IStETH public immutable STETH;
    IWstETH public immutable WSTETH;
    address public immutable STRATEGY_PROXY_IMPL;

    /// @dev WARNING: This ID is used to calculate user proxy addresses.
    /// Changing this value will break user proxy address calculations.
    bytes32 public constant STRATEGY_ID = keccak256("strategy.ggv.v1");

    mapping(bytes32 salt => address proxy) private userStrategyProxy;

    error ZeroArgument(string name);
    error TokenNotAllowed();

    constructor(address _pool, address _stETH, address _wstETH, address _strategyProxyImpl) {
        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        STRATEGY_PROXY_IMPL = _strategyProxyImpl;
        POOL = StvStETHPool(payable(_pool));
    }

    /// @notice Recovers ERC20 tokens from the strategy
    /// @param _token The token to recover
    /// @param _recipient The recipient of the tokens
    /// @param _amount The amount of tokens to recover
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        address proxy = getStrategyProxyAddress(msg.sender);

        IStrategyProxy(proxy).safeRecoverERC20(_token, _recipient, _amount);
    }

    /// @notice Returns the address of the strategy proxy for a given user
    /// @param user The user for which to get the strategy proxy address
    /// @return proxy The address of the strategy proxy
    function getStrategyProxyAddress(address user) public view returns (address proxy) {
        bytes32 salt = _generateSalt(user);
        proxy = Clones.predictDeterministicAddress(STRATEGY_PROXY_IMPL, salt);
    }

    function _getOrCreateProxy(address _user) internal returns (address proxy) {
        if (_user == address(0)) revert ZeroArgument("_user");

        bytes32 salt = _generateSalt(_user);
        proxy = userStrategyProxy[salt];
        if (proxy != address(0)) return proxy;

        proxy = Clones.cloneDeterministic(STRATEGY_PROXY_IMPL, salt);
        IStrategyProxy(proxy).initialize(address(this));
        IStrategyProxy(proxy).call(
            address(STETH), abi.encodeWithSelector(STETH.approve.selector, address(POOL), type(uint256).max)
        );
        userStrategyProxy[salt] = proxy;

        return proxy;
    }

    function _generateSalt(address _user) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encode(STRATEGY_ID, address(this), _user));
    }
}
