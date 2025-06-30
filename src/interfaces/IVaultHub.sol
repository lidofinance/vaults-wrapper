// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

interface IVaultHub {
    function fund(address vault) external payable;
    function withdraw(address vault, address recipient, uint256 etherAmount) external;
    function totalValue(address vault) external view returns (uint256);
    function withdrawableValue(address vault) external view returns (uint256);
    function requestValidatorExit(address vault, bytes calldata pubkeys) external;
    function triggerValidatorWithdrawals(
        address vault,
        bytes calldata pubkeys,
        uint64[] calldata amounts,
        address refundRecipient
    ) external payable;
}