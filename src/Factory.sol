// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {Wrapper} from "./Wrapper.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

contract Factory {
    IVaultFactory immutable VAULT_FACTORY;
    address immutable STETH;

    string constant NAME = "Staked ETH Vault Wrapper";
    string constant SYMBOL = "stvToken";

    event VaultWrapperCreated(
        address vault,
        address wrapper,
        address withdrawalQueue,
        address strategy
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
        address _strategy
    )
        external
        payable
        returns (
            address vault,
            address dashboard,
            Wrapper wrapper,
            WithdrawalQueue withdrawalQueue
        )
    {
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard{
            value: msg.value
        }(
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
            msg.sender,
            NAME,
            SYMBOL,
            false, // whitelist disabled by default
            address(_strategy) != address(0), // enable minting if strategy is provided
            _strategy
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);
        withdrawalQueue.initialize(msg.sender);

        // Grant mint/burn roles to wrapper if strategy is provided
        if (address(_strategy) != address(0)) {
            _dashboard.grantRole(_dashboard.MINT_ROLE(), address(wrapper));
            _dashboard.grantRole(_dashboard.BURN_ROLE(), address(wrapper));
        }

        wrapper.setWithdrawalQueue(address(withdrawalQueue));

        // Set the wrapper as owner
        _dashboard.grantRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(wrapper));

        // Revocation of factory roles
        _dashboard.revokeRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(
            vault,
            address(wrapper),
            address(withdrawalQueue),
            _strategy
        );

        return (vault, dashboard, wrapper, withdrawalQueue);
    }
}
