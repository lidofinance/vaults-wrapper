// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

interface IStrategyCallForwarder {
    function initialize(address _owner) external;
    function call(address _target, bytes calldata _data) external payable returns (bytes memory);
    function callWithValue(address _target, bytes calldata _data, uint256 _value)
        external
        payable
        returns (bytes memory);
    function sendValue(address payable _recipient, uint256 _amount) external payable;
}
