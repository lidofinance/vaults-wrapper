// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {WrapperA} from "./WrapperA.sol";
import {WrapperB} from "./WrapperB.sol";
import {WrapperC} from "./WrapperC.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

contract DummyContractStub {

}

contract Factory {
    IVaultFactory public immutable VAULT_FACTORY;
    address public immutable STETH;

    string constant NAME = "Staked ETH Vault Wrapper";
    string constant SYMBOL = "stvToken";

    event VaultWrapperCreated(
        address indexed vault,
        address indexed wrapper,
        address indexed withdrawalQueue,
        address strategy,
        WrapperConfiguration configuration
    );

    enum WrapperConfiguration {
        NO_MINTING_NO_STRATEGY,    // (A) no minting, no strategy
        MINTING_NO_STRATEGY,       // (B) minting, no strategy
        MINTING_AND_STRATEGY       // (C) minting and strategy
    }

    constructor(address _vaultFactory, address _steth) {
        VAULT_FACTORY = IVaultFactory(_vaultFactory);
        STETH = _steth;
    }

    function createVaultWithWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        WrapperConfiguration _configuration,
        address _strategy,
        bool _allowlistEnabled
    )
        external
        payable
        returns (
            address vault,
            address dashboard,
            address payable wrapperProxy,
            address withdrawalQueueProxy
        )
    {
        // Deploy vault and dashboard
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard{
            value: msg.value
        }(
            address(this), // temporary admin
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        IDashboard _dashboard = IDashboard(payable(dashboard));

        // Create wrapper implementation with proper constructor params
        WrapperBase wrapperImpl;
        bytes memory proxyInitData;

        if (_configuration == WrapperConfiguration.NO_MINTING_NO_STRATEGY) {
            wrapperImpl = new WrapperA(
                dashboard,      // correct dashboard
                _allowlistEnabled
            );
            proxyInitData = abi.encodeCall(
                WrapperA.initialize,
                (address(this), NAME, SYMBOL) // Factory gets admin role temporarily
            );
        } else if (_configuration == WrapperConfiguration.MINTING_NO_STRATEGY) {
            wrapperImpl = new WrapperB(
                dashboard,      // correct dashboard
                STETH,          // stETH address
                _allowlistEnabled
            );
            proxyInitData = abi.encodeCall(
                WrapperB.initialize,
                (address(this), NAME, SYMBOL) // Factory gets admin role temporarily
            );
        } else if (_configuration == WrapperConfiguration.MINTING_AND_STRATEGY) {
            wrapperImpl = new WrapperC(
                dashboard,      // correct dashboard
                STETH,
                _allowlistEnabled,
                _strategy != address(0) ? _strategy : address(1) // avoid zero strategy
            );
            proxyInitData = abi.encodeCall(
                WrapperB.initialize,
                (address(this), NAME, SYMBOL) // Factory gets admin role temporarily
            );
        } else {
            revert("Invalid configuration");
        }

        // Deploy wrapper proxy
        wrapperProxy = payable(address(new ERC1967Proxy(address(wrapperImpl), proxyInitData)));
        WrapperBase wrapper = WrapperBase(payable(wrapperProxy));

        // Create withdrawal queue implementation with correct wrapper
        uint256 maxFinalizationTime = 30 days; // Default max finalization time
        WithdrawalQueue wqImpl = new WithdrawalQueue(WrapperBase(wrapperProxy), maxFinalizationTime);

        // Deploy withdrawal queue proxy
        withdrawalQueueProxy = address(new ERC1967Proxy(
            address(wqImpl),
            abi.encodeCall(WithdrawalQueue.initialize, (msg.sender))
        ));

        // Configure the system
        _dashboard.grantRole(_dashboard.FUND_ROLE(), wrapperProxy);

        // TODO: who must be granted WITHDRAW_ROLE?
        _dashboard.grantRole(_dashboard.WITHDRAW_ROLE(), withdrawalQueueProxy);

        // For WrapperB and WrapperC, grant mint/burn roles
        if (_configuration != WrapperConfiguration.NO_MINTING_NO_STRATEGY) {
            _dashboard.grantRole(_dashboard.MINT_ROLE(), wrapperProxy);
            _dashboard.grantRole(_dashboard.BURN_ROLE(), wrapperProxy);
        }

        wrapper.setWithdrawalQueue(withdrawalQueueProxy);

        // For WrapperC, set the strategy
        if (_configuration == WrapperConfiguration.MINTING_AND_STRATEGY && _strategy != address(0)) {
            WrapperC(wrapperProxy).setStrategy(_strategy);
        }

        // Transfer admin role to the user (for wrapper)
        wrapper.grantRole(wrapper.DEFAULT_ADMIN_ROLE(), msg.sender);
        wrapper.revokeRole(wrapper.DEFAULT_ADMIN_ROLE(), address(this));

        // Transfer admin role to the user (for dashboard)
        _dashboard.grantRole(_dashboard.DEFAULT_ADMIN_ROLE(), msg.sender);
        _dashboard.revokeRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(
            vault,
            wrapperProxy,
            withdrawalQueueProxy,
            _strategy,
            _configuration
        );

        return (vault, dashboard, wrapperProxy, withdrawalQueueProxy);
    }
}