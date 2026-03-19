// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract MockMellowQueue {
    address public asset;

    function setAsset(address a) external {
        asset = a;
    }
}
