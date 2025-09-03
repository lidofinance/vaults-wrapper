// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {IStrategyProxy} from "src/interfaces/IStrategyProxy.sol";

contract StrategyProxy is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, IStrategyProxy {

    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
         __ReentrancyGuard_init();
        __Ownable_init(_owner);
    }

    /// @notice Function for receiving native assets
    receive() external payable {}

    /// @notice Executes a call on the target contract
    /// @dev Only callable by owner. To convert to the expected return value, use abi.decode.
    /// @param _target The address of the target contract
    /// @param _data The call data
    /// @return Returns the raw returned data. 
    function call(address _target, bytes calldata _data) external payable onlyOwner returns (bytes memory) {
        return Address.functionCall(_target, _data);
    }

    /// @notice Executes a call on the target contract, but also transferring value wei to the target.
    /// @dev Only callable by owner. To convert to the expected return value, use abi.decode.
    /// @param _target The address of the target contract
    /// @param _data The call data
    /// @param _value The value to send with the call
    /// @return Returns the raw returned data. 
    function callWithValue(address _target, bytes calldata _data, uint256 _value) external payable onlyOwner returns (bytes memory) {
        return Address.functionCallWithValue(_target, _data, _value);
    }

    /// @notice sends `_amount` wei to `_recipient`
    function sendValue(address payable _recipient, uint256 _amount) external payable onlyOwner nonReentrant {
        Address.sendValue(_recipient, _amount);
    }
}