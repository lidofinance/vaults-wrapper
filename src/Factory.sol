// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {Wrapper} from "./Wrapper.sol";
import {Escrow} from "./Escrow.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

contract Factory {
    IVaultFactory immutable VAULT_FACTORY;
    address immutable STETH;

    event VaultWrapperCreated(
        address vault,
        address wrapper,
        address withdrawalQueue,
        address escrow
    );

    constructor(address _vaultFactory, address _steth) {
        VAULT_FACTORY = IVaultFactory(_vaultFactory);
        STETH = _steth;
    }

    function createVaultWithWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        address _strategy,
        string calldata _name,
        string calldata _symbol
    )
        external
        payable
        returns (
            address vault,
            address dashboard,
            Wrapper wrapper,
            WithdrawalQueue withdrawalQueue,
            Escrow escrow
        )
    {
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard(
            address(this), // default admin
            _nodeOperator, // node operator
            _nodeOperatorManager, // node operator manager
            _nodeOperatorFeeBP, // node operator fee BP
            _confirmExpiry, // confirm expiry
            new IVaultFactory.RoleAssignment[](0)
        );

        IDashboard _dashboard = IDashboard(payable(dashboard));

        // TODO: proxy when decided on contract setup
        wrapper = new Wrapper(
            dashboard,
            address(0),
            msg.sender,
            _name,
            _symbol
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);
        withdrawalQueue.initialize(msg.sender);

        // optionally deploy Escrow if a strategy is provided
        if (address(_strategy) != address(0)) {
            escrow = new Escrow(
                address(wrapper),
                address(withdrawalQueue),
                _strategy,
                STETH
            );
            wrapper.setEscrowAddress(address(escrow));
            _dashboard.grantRole(_dashboard.MINT_ROLE(), address(escrow));
            _dashboard.grantRole(_dashboard.BURN_ROLE(), address(escrow));
        }

        // Set the wrapper as owner
        _dashboard.grantRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(wrapper));

        // Revokation of factory roles
        _dashboard.revokeRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(
            vault,
            address(wrapper),
            address(withdrawalQueue),
            address(escrow)
        );

        return (vault, dashboard, wrapper, withdrawalQueue, escrow);
    }
}
