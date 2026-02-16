// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IQueue {
    function vault() external view returns (address vault);

    function asset() external view returns (address asset);
}
