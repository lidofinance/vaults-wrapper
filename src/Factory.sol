// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {WrapperA} from "./WrapperA.sol";
import {WrapperB} from "./WrapperB.sol";
import {WrapperC} from "./WrapperC.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {LoopStrategy} from "./strategy/LoopStrategy.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {ILidoLocator} from "./interfaces/ILidoLocator.sol";

error InvalidConfiguration();

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
        address  _upgradeConformer,
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
        ILidoLocator locator = ILidoLocator(VAULT_FACTORY.LIDO_LOCATOR());
        address lazyOracle = locator.lazyOracle();

        if (_configuration == WrapperConfiguration.NO_MINTING_NO_STRATEGY) {
            (wrapperProxy, withdrawalQueueProxy) = _deployWrapperA(
                dashboard,
                lazyOracle,
                _allowlistEnabled,
                _nodeOperator,
                _upgradeConformer
            );
        } else if (_configuration == WrapperConfiguration.MINTING_NO_STRATEGY) {
            (wrapperProxy, withdrawalQueueProxy) = _deployWrapperB(
                dashboard,
                lazyOracle,
                _allowlistEnabled,
                _nodeOperator,
                _upgradeConformer
            );
        } else if (_configuration == WrapperConfiguration.MINTING_AND_STRATEGY) {
            (wrapperProxy, withdrawalQueueProxy) = _deployWrapperC(
                dashboard,
                lazyOracle,
                _allowlistEnabled,
                _nodeOperator,
                _upgradeConformer,
                _strategy
            );
        } else {
            revert("Invalid configuration");
        }

        WrapperBase wrapper = WrapperBase(payable(wrapperProxy));

        // Configure the system
        _dashboard.grantRole(_dashboard.FUND_ROLE(), wrapperProxy);
        _dashboard.grantRole(_dashboard.WITHDRAW_ROLE(), withdrawalQueueProxy);

        // For WrapperB and WrapperC, grant mint/burn roles
        if (_configuration != WrapperConfiguration.NO_MINTING_NO_STRATEGY) {
            _dashboard.grantRole(_dashboard.MINT_ROLE(), wrapperProxy);
            _dashboard.grantRole(_dashboard.BURN_ROLE(), wrapperProxy);
        }

        wrapper.setWithdrawalQueue(withdrawalQueueProxy);

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

    function _deployWrapperA(
        address dashboard,
        address lazyOracle,
        bool _allowlistEnabled,
        address _nodeOperator,
        address _upgradeConformer
    ) internal returns (address payable wrapperProxy, address withdrawalQueueProxy) {
        // Step 1: Create wrapper implementation
        WrapperA wrapperImpl = new WrapperA(dashboard, _allowlistEnabled);

        // Step 2: Deploy wrapper proxy
        wrapperProxy = payable(address(new ERC1967Proxy(
            address(wrapperImpl),
            abi.encodeCall(WrapperA.initialize, (address(this), _upgradeConformer, NAME, SYMBOL))
        )));

        // Step 3: Deploy withdrawal queue implementation with known wrapper address
        uint256 maxFinalizationTime = 30 days;
        WithdrawalQueue wqImpl = new WithdrawalQueue(WrapperBase(wrapperProxy), lazyOracle, maxFinalizationTime);

        // Step 4: Deploy withdrawal queue proxy
        withdrawalQueueProxy = address(new ERC1967Proxy(
            address(wqImpl),
            abi.encodeCall(WithdrawalQueue.initialize, (_nodeOperator, _nodeOperator))
        ));
    }

    function _deployWrapperB(
        address dashboard,
        address lazyOracle,
        bool _allowlistEnabled,
        address _nodeOperator,
        address _upgradeConformer
    ) internal returns (address payable wrapperProxy, address withdrawalQueueProxy) {
        // Step 1: Create wrapper implementation
        WrapperB wrapperImpl = new WrapperB(dashboard, STETH, _allowlistEnabled);

        // Step 2: Deploy wrapper proxy
        wrapperProxy = payable(address(new ERC1967Proxy(
            address(wrapperImpl),
            abi.encodeCall(WrapperB.initialize, (address(this), _upgradeConformer, NAME, SYMBOL))
        )));

        // Step 3: Deploy withdrawal queue implementation with known wrapper address
        uint256 maxFinalizationTime = 30 days;
        WithdrawalQueue wqImpl = new WithdrawalQueue(WrapperBase(wrapperProxy), lazyOracle, maxFinalizationTime);

        // Step 4: Deploy withdrawal queue proxy
        withdrawalQueueProxy = address(new ERC1967Proxy(
            address(wqImpl),
            abi.encodeCall(WithdrawalQueue.initialize, (_nodeOperator, _nodeOperator))
        ));
    }

    function _deployWrapperC(
        address dashboard,
        address lazyOracle,
        bool _allowlistEnabled,
        address _nodeOperator,
        address _upgradeConformer,
        address _strategy
    ) internal returns (address payable wrapperProxy, address withdrawalQueueProxy) {
        // Step 1: Create wrapper implementation with zero strategy initially
        WrapperC wrapperImpl = new WrapperC(dashboard, STETH, _allowlistEnabled, address(0));

        // Step 2: Deploy wrapper proxy
        wrapperProxy = payable(address(new ERC1967Proxy(
            address(wrapperImpl),
            abi.encodeCall(WrapperB.initialize, (address(this), _upgradeConformer, NAME, SYMBOL))
        )));

        // Step 3: Deploy withdrawal queue implementation with known wrapper address
        uint256 maxFinalizationTime = 30 days;
        WithdrawalQueue wqImpl = new WithdrawalQueue(WrapperBase(wrapperProxy), lazyOracle, maxFinalizationTime);

        // Step 4: Deploy withdrawal queue proxy
        withdrawalQueueProxy = address(new ERC1967Proxy(
            address(wqImpl),
            abi.encodeCall(WithdrawalQueue.initialize, (_nodeOperator, _nodeOperator))
        ));

        // Step 5: Set the strategy on the wrapper
        if (_strategy == address(0)) {
            // If no strategy provided, create a default LoopStrategy
            uint256 loops = 1; // Default number of loops
            LoopStrategy strategyImpl = new LoopStrategy(STETH, wrapperProxy, loops);
            WrapperC(wrapperProxy).setStrategy(address(strategyImpl));
        } else {
            // Use the provided strategy
            WrapperC(wrapperProxy).setStrategy(_strategy);
        }
    }
}