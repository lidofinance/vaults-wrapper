// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract MockUpgradableWq {
    address immutable public WRAPPER;

    error OnlyWrapperCanUpgrade();
    event ImplementationUpgraded(address newImplementation);

    constructor(address _wrapper){
        WRAPPER = _wrapper;
    }

    function upgradeTo(address newImplementation) external {
        if(msg.sender != address(WRAPPER)) revert OnlyWrapperCanUpgrade();
        ERC1967Utils.upgradeToAndCall(newImplementation, new bytes(0));
        emit ImplementationUpgraded(newImplementation);
    }
}