// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Wrapper} from "./Wrapper.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

contract Factory {
    IVaultFactory immutable VAULT_FACTORY;

    event VaultWrapperCreated(
        address vault,
        address dashboard,
        address wrapper
    );

    constructor(address _vaultFactory) {
        VAULT_FACTORY = IVaultFactory(_vaultFactory);
    }

    function createVaultWithWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        string calldata _name,
        string calldata _symbol
    )
        external
        payable
        returns (
            address vault,
            IDashboard dashboard,
            Wrapper wrapper,
            WithdrawalQueue withdrawalQueue
        )
    {
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard(
            address(this), // default admin
            _nodeOperator, // node operator
            _nodeOperatorManager, // node operator manager
            _nodeOperatorFeeBP, // node operator fee BP
            _confirmExpiry, // confirm expiry
            new IVaultFactory.RoleAssignment[](0) // no role assignments
        );

        // TODO: proxy when decided on contract setup
        withdrawalQueue = new WithdrawalQueue(address(dashboard));
        wrapper = new Wrapper(
            address(dashboard),
            address(withdrawalQueue),
            msg.sender,
            _name,
            _symbol
        );

        // Set the wrapper as owner
        dashboard.grantRole(dashboard.DEFAULT_ADMIN_ROLE(), address(wrapper));

        // Revokation of factory roles
        dashboard.revokeRole(dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(vault, address(dashboard), address(wrapper));

        return (vault, dashboard, wrapper, withdrawalQueue);
    }
}
