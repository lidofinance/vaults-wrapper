// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ProposalUpgradable, ERC1967Utils} from "src/ProposalUpgradable.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract ProposalUpgradableHarness is ProposalUpgradable {
    address private wqContract;
    bool private canUpgrade = true;

    event UpgradeInitialized();
    

    constructor(){
        _disableInitializers();
    }
    
    function initialize(address owner, address proposer, address conformer, address _wqContract) public initializer {
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _initializeProposalUpgradable(proposer, conformer);
        wqContract = _wqContract;
    }

    function initializeUpgrade() public{
        emit UpgradeInitialized();
    }

    function withdrawalQueue() override public view returns (WithdrawalQueue) {
        return WithdrawalQueue(payable(wqContract));
    }

    function _canUpgrade() internal view override returns (bool) {
       return canUpgrade;
    }

    function setCanUpgrade(bool _value) public {
        canUpgrade = _value;
    }

    function getImplementation() public view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}