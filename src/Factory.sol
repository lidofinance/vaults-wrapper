// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {WrapperBase} from "./WrapperBase.sol";
import {WrapperA} from "./WrapperA.sol";
import {WrapperB} from "./WrapperB.sol";
import {WrapperC} from "./WrapperC.sol";
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

    enum WrapperConfiguration {
        NO_MINTING_NO_STRATEGY,    // (A) no minting, no strategy
        MINTING_NO_STRATEGY,       // (B) minting, no strategy  
        MINTING_AND_STRATEGY       // (C) minting and strategy
    }
    
    function createVaultWithWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        WrapperConfiguration _configuration,
        address _strategy
    )
        external
        payable
        returns (
            address vault,
            address dashboard,
            WrapperBase wrapper,
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

        // Deploy the appropriate wrapper based on configuration
        if (_configuration == WrapperConfiguration.NO_MINTING_NO_STRATEGY) {
            wrapper = new WrapperA(
                dashboard,
                msg.sender,
                NAME,
                SYMBOL,
                false // whitelist disabled by default
            );
        } else if (_configuration == WrapperConfiguration.MINTING_NO_STRATEGY) {
            wrapper = new WrapperB(
                dashboard,
                msg.sender,
                NAME,
                SYMBOL,
                false // whitelist disabled by default
            );
        } else if (_configuration == WrapperConfiguration.MINTING_AND_STRATEGY) {
            wrapper = new WrapperC(
                dashboard,
                msg.sender,
                NAME,
                SYMBOL,
                false, // whitelist disabled by default
                _strategy
            );
        } else {
            revert("Invalid configuration");
        }

        withdrawalQueue = new WithdrawalQueue(wrapper);
        withdrawalQueue.initialize(msg.sender);

        // Grant fund/withdraw roles to wrapper for all configurations
        _dashboard.grantRole(_dashboard.FUND_ROLE(), address(wrapper));
        _dashboard.grantRole(_dashboard.WITHDRAW_ROLE(), address(wrapper));

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
