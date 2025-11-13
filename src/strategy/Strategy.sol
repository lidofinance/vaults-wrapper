// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {IStETH} from "src/interfaces/core/IStETH.sol";
import {IWstETH} from "src/interfaces/core/IWstETH.sol";

abstract contract Strategy is IStrategy {
    StvStETHPool internal immutable POOL_;
    IStETH public immutable STETH;
    IWstETH public immutable WSTETH;
    address public immutable STRATEGY_CALL_FORWARDER_IMPL;

    /// @dev WARNING: This ID is used to calculate user proxy addresses.
    /// Changing this value will break user proxy address calculations.
    bytes32 public constant STRATEGY_ID = keccak256("strategy.ggv.v1");

    mapping(bytes32 salt => address proxy) private userStrategyCallForwarder;

    error ZeroArgument(string name);

    constructor(address _pool, address _stETH, address _wstETH, address _strategyCallForwarderImpl) {
        STETH = IStETH(_stETH);
        WSTETH = IWstETH(_wstETH);
        STRATEGY_CALL_FORWARDER_IMPL = _strategyCallForwarderImpl;
        POOL_ = StvStETHPool(payable(_pool));
    }

    function POOL() external view returns (address) {
        return address(POOL_);
    }

    /// @notice Recovers ERC20 tokens from the strategy
    /// @param _token The token to recover
    /// @param _recipient The recipient of the tokens
    /// @param _amount The amount of tokens to recover
    function recoverERC20(address _token, address _recipient, uint256 _amount) external {
        if (_token == address(0)) revert ZeroArgument("_token");
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_amount == 0) revert ZeroArgument("_amount");

        address proxy = getStrategyCallForwarderAddress(msg.sender);

        IStrategyCallForwarder(proxy)
            .doCall(address(STETH), abi.encodeWithSelector(IERC20.transfer.selector, _recipient, _amount));
    }

    /// @notice Returns the address of the strategy proxy for a given user
    /// @param user The user for which to get the strategy call forwarder address
    /// @return callForwarder The address of the strategy call forwarder
    function getStrategyCallForwarderAddress(address user) public view returns (address callForwarder) {
        bytes32 salt = _generateSalt(user);
        callForwarder = Clones.predictDeterministicAddress(STRATEGY_CALL_FORWARDER_IMPL, salt);
    }

    function _getOrCreateCallForwarder(address _user) internal returns (address callForwarder) {
        if (_user == address(0)) revert ZeroArgument("_user");

        bytes32 salt = _generateSalt(_user);
        callForwarder = userStrategyCallForwarder[salt];
        if (callForwarder != address(0)) return callForwarder;

        callForwarder = Clones.cloneDeterministic(STRATEGY_CALL_FORWARDER_IMPL, salt);
        IStrategyCallForwarder(callForwarder).initialize(address(this));
        IStrategyCallForwarder(callForwarder)
            .doCall(address(STETH), abi.encodeWithSelector(STETH.approve.selector, address(POOL_), type(uint256).max));
        userStrategyCallForwarder[salt] = callForwarder;
    }

    function _generateSalt(address _user) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encode(STRATEGY_ID, address(this), _user));
    }
}
