// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract TimelockFactory {
    function deploy(uint256 minDelaySeconds, address proposer, address executor) external returns (address timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        TimelockController tl = new TimelockController(minDelaySeconds, proposers, executors, address(0));
        timelock = address(tl);
    }
}
