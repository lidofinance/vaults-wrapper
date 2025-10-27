// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Distributor} from "src/Distributor.sol";

contract DistributorFactory {
    function deploy(address _owner) external returns (address impl) {
        impl = address(new Distributor(_owner));
    }
}

