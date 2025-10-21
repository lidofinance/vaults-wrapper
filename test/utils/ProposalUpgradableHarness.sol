// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ProposalUpgradable, ERC1967Utils} from "src/ProposalUpgradable.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

contract ProposalUpgradableHarness is ProposalUpgradable {
    address private wqContract;
    bool private canUpgrade;

    event UpgradeInitialized();

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner, address proposer, address confirmer, address _wqContract) public initializer {
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _initializeProposalUpgradable(proposer, confirmer);
        wqContract = _wqContract;
        canUpgrade = true;
    }

    function initializeUpgrade() public {
        emit UpgradeInitialized();
    }

    function withdrawalQueue() public view override returns (WithdrawalQueue) {
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
