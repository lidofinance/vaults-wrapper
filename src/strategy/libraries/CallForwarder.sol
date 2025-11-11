// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";

abstract contract CallForwarder {

    error CallForwarderZeroArgument(string name);

    /// @dev WARNING: This ID is used to calculate user proxy addresses.
    /// Changing this value will break user proxy address calculations.
    bytes32 public immutable STRATEGY_ID;
    address public immutable STRATEGY_CALL_FORWARDER_IMPL;

    /// @custom:storage-location erc7201:pool.storage.CallForwarder
    struct CallForwarderStorage {
        mapping(bytes32 salt => address proxy) userCallForwarder;
    }

    // keccak256(abi.encode(uint256(keccak256("pool.storage.CallForwarder")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CALL_FORWARDER_STORAGE_LOCATION =
        0x5c9f76d9e14874ca461072d5f875d2d6da8538e72a25e52a3229de69a88f5b00;

    function _getStorage() internal pure returns (CallForwarderStorage storage $) {
        assembly {
            $.slot := CALL_FORWARDER_STORAGE_LOCATION
        }
    }

    constructor(bytes32 _strategyId, address _strategyCallForwarderImpl) {
        if (_strategyId == bytes32(0)) revert CallForwarderZeroArgument("_strategyId");
        if (_strategyCallForwarderImpl == address(0)) revert CallForwarderZeroArgument("_strategyCallForwarderImpl");

        STRATEGY_ID = _strategyId;
        STRATEGY_CALL_FORWARDER_IMPL = _strategyCallForwarderImpl;
    }

    /// @notice Returns the address of the strategy call forwarder for a given user
    /// @param user The user for which to get the strategy call forwarder address
    /// @return callForwarder The address of the strategy call forwarder
    function getStrategyCallForwarderAddress(address user) public view returns (address callForwarder) {
        bytes32 salt = _generateSalt(user);
        callForwarder = Clones.predictDeterministicAddress(STRATEGY_CALL_FORWARDER_IMPL, salt);
    }

    function _getOrCreateCallForwarder(address _user) internal returns (address callForwarder) {
        if (_user == address(0)) revert CallForwarderZeroArgument("_user");

        CallForwarderStorage storage $ = _getStorage();

        bytes32 salt = _generateSalt(_user);
        callForwarder = $.userCallForwarder[salt];
        if (callForwarder != address(0)) return callForwarder;

        callForwarder = Clones.cloneDeterministic(STRATEGY_CALL_FORWARDER_IMPL, salt);
        IStrategyCallForwarder(callForwarder).initialize(address(this));

        $.userCallForwarder[salt] = callForwarder;
    }

    function _generateSalt(address _user) internal view returns (bytes32 salt) {
        salt = keccak256(abi.encode(STRATEGY_ID, address(this), _user));
    }
}