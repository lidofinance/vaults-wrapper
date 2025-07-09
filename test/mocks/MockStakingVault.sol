// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockStakingVault
 * @notice Mock contract for testing StakingVault
 */
contract MockStakingVault {
    address public nodeOperator;
    uint256 public totalAssets;

    event Funded(address indexed sender, uint256 amount);

    constructor() {
        nodeOperator = address(0x123);
    }

    function fund() external payable {
        totalAssets += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    function setNodeOperator(address _nodeOperator) external {
        nodeOperator = _nodeOperator;
    }

    function setTotalAssets(uint256 _totalAssets) external {
        totalAssets = _totalAssets;
    }

    function withdraw(address recipient, uint256 amount) external {
        require(msg.sender == nodeOperator, "Not node operator");
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function triggerValidatorWithdrawals(
        bytes calldata pubkeys,
        uint64[] calldata amounts,
        address refundRecipient
    ) external payable {
        // Mock implementation
    }
}