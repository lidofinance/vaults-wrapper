// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperBase} from "./WrapperBase.sol";
import {WrapperA} from "./WrapperA.sol";
import {WrapperB} from "./WrapperB.sol";
import {WrapperC} from "./WrapperC.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {WrapperAFactory} from "./factories/WrapperAFactory.sol";
import {WrapperBFactory} from "./factories/WrapperBFactory.sol";
import {WrapperCFactory} from "./factories/WrapperCFactory.sol";
import {WithdrawalQueueFactory} from "./factories/WithdrawalQueueFactory.sol";
import {LoopStrategy} from "./strategy/LoopStrategy.sol";
import {LoopStrategyFactory} from "./factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "./factories/GGVStrategyFactory.sol";
import {OssifiableProxy} from "./proxy/OssifiableProxy.sol";
import {DummyImplementation} from "./proxy/DummyImplementation.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

error InvalidConfiguration();

contract Factory {
    struct WrapperConfig {
        address vaultFactory;
        address steth;
        address wrapperAFactory;
        address wrapperBFactory;
        address wrapperCFactory;
        address withdrawalQueueFactory;
        address loopStrategyFactory;
        address ggvStrategyFactory;
        address dummyImplementation;
        uint256 maxFinalizationTime;
    }
    IVaultFactory public immutable VAULT_FACTORY;
    address public immutable STETH;
    WrapperAFactory public immutable WRAPPER_A_FACTORY;
    WrapperBFactory public immutable WRAPPER_B_FACTORY;
    WrapperCFactory public immutable WRAPPER_C_FACTORY;
    WithdrawalQueueFactory public immutable WITHDRAWAL_QUEUE_FACTORY;
    LoopStrategyFactory public immutable LOOP_STRATEGY_FACTORY;
    GGVStrategyFactory public immutable GGV_STRATEGY_FACTORY;
    address public immutable DUMMY_IMPLEMENTATION;
    uint256 public immutable MAX_FINALIZATION_TIME;
    string constant NAME = "Staked ETH Vault Wrapper";
    string constant SYMBOL = "stvToken";

    event VaultWrapperCreated(
        address indexed vault,
        address indexed wrapper,
        address indexed withdrawalQueue,
        address strategy,
        WrapperType configuration
    );

    enum WrapperType {
        NO_MINTING_NO_STRATEGY,
        MINTING_NO_STRATEGY,
        LOOP_STRATEGY,
        GGV_STRATEGY
    }

    constructor(WrapperConfig memory a) {
        VAULT_FACTORY = IVaultFactory(a.vaultFactory);
        STETH = a.steth;
        WRAPPER_A_FACTORY = WrapperAFactory(a.wrapperAFactory);
        WRAPPER_B_FACTORY = WrapperBFactory(a.wrapperBFactory);
        WRAPPER_C_FACTORY = WrapperCFactory(a.wrapperCFactory);
        WITHDRAWAL_QUEUE_FACTORY = WithdrawalQueueFactory(a.withdrawalQueueFactory);
        LOOP_STRATEGY_FACTORY = LoopStrategyFactory(a.loopStrategyFactory);
        GGV_STRATEGY_FACTORY = GGVStrategyFactory(a.ggvStrategyFactory);
        DUMMY_IMPLEMENTATION = a.dummyImplementation;
        MAX_FINALIZATION_TIME = a.maxFinalizationTime;
    }

    function createVaultWithConfiguredWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        WrapperType _configuration,
        address _strategy,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP
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
        IDashboard _dashboard;
        address payable _wrapperProxy;
        address _withdrawalQueueProxy;
        (vault, dashboard, _dashboard, _wrapperProxy, _withdrawalQueueProxy) = _setupVaultAndProxies(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry
        );

        address usedStrategy = _strategy;
        if (_configuration == WrapperType.LOOP_STRATEGY && usedStrategy == address(0)) {
            usedStrategy = LOOP_STRATEGY_FACTORY.deploy(STETH, address(_wrapperProxy), 1);
        }

        WrapperBase wrapper = _deployAndInitWrapper(
            _configuration,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            usedStrategy,
            _wrapperProxy
        );

        _configureAndFinalize(_dashboard, wrapper, _wrapperProxy, _withdrawalQueueProxy, vault, _configuration, usedStrategy);

        return (vault, dashboard, _wrapperProxy, _withdrawalQueueProxy);
    }

    // =================================================================================
    // Overloads per configuration
    // =================================================================================

    function createVaultWithNoMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
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
        IDashboard _dashboard;
        address payable _wrapperProxy;
        address _withdrawalQueueProxy;
        (vault, dashboard, _dashboard, _wrapperProxy, _withdrawalQueueProxy) = _setupVaultAndProxies(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry
        );

        WrapperBase wrapper = _deployAndInitWrapper(
            WrapperType.NO_MINTING_NO_STRATEGY,
            dashboard,
            _allowlistEnabled,
            0,
            _withdrawalQueueProxy,
            address(0),
            _wrapperProxy
        );

        _configureAndFinalize(_dashboard, wrapper, _wrapperProxy, _withdrawalQueueProxy, vault, WrapperType.NO_MINTING_NO_STRATEGY, address(0));

        return (vault, dashboard, _wrapperProxy, _withdrawalQueueProxy);
    }

    function createVaultWithMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP
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
        IDashboard _dashboard;
        address payable _wrapperProxy;
        address _withdrawalQueueProxy;
        (vault, dashboard, _dashboard, _wrapperProxy, _withdrawalQueueProxy) = _setupVaultAndProxies(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry
        );

        WrapperBase wrapper = _deployAndInitWrapper(
            WrapperType.MINTING_NO_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            address(0),
            _wrapperProxy
        );

        _configureAndFinalize(_dashboard, wrapper, _wrapperProxy, _withdrawalQueueProxy, vault, WrapperType.MINTING_NO_STRATEGY, address(0));

        return (vault, dashboard, _wrapperProxy, _withdrawalQueueProxy);
    }

    function createVaultWithLoopStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        uint256 _loops
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
        IDashboard _dashboard;
        address payable _wrapperProxy;
        address _withdrawalQueueProxy;
        (vault, dashboard, _dashboard, _wrapperProxy, _withdrawalQueueProxy) = _setupVaultAndProxies(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry
        );

        address loopStrategy = LOOP_STRATEGY_FACTORY.deploy(STETH, address(_wrapperProxy), _loops);

        WrapperBase wrapper = _deployAndInitWrapper(
            WrapperType.LOOP_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            loopStrategy,
            _wrapperProxy
        );

        _configureAndFinalize(_dashboard, wrapper, _wrapperProxy, _withdrawalQueueProxy, vault, WrapperType.LOOP_STRATEGY, loopStrategy);

        return (vault, dashboard, _wrapperProxy, _withdrawalQueueProxy);
    }

    function createVaultWithGGVStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _teller,
        address _boringQueue
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
        IDashboard _dashboard;
        address payable _wrapperProxy;
        address _withdrawalQueueProxy;
        (vault, dashboard, _dashboard, _wrapperProxy, _withdrawalQueueProxy) = _setupVaultAndProxies(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry
        );

        address ggvStrategy = GGV_STRATEGY_FACTORY.deploy(STETH, _teller, _boringQueue);

        WrapperBase wrapper = _deployAndInitWrapper(
            WrapperType.GGV_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            ggvStrategy,
            _wrapperProxy
        );

        _configureAndFinalize(_dashboard, wrapper, _wrapperProxy, _withdrawalQueueProxy, vault, WrapperType.GGV_STRATEGY, ggvStrategy);

        return (vault, dashboard, _wrapperProxy, _withdrawalQueueProxy);
    }

    function _deployWrapper(
        WrapperType _configuration,
        address dashboard,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address withdrawalQueueProxy,
        address _strategy
    ) internal returns (address wrapperImpl) {
        if (_configuration == WrapperType.NO_MINTING_NO_STRATEGY) {
            wrapperImpl = WRAPPER_A_FACTORY.deploy(dashboard, _allowlistEnabled, withdrawalQueueProxy);
        } else if (_configuration == WrapperType.MINTING_NO_STRATEGY) {
            wrapperImpl = WRAPPER_B_FACTORY.deploy(dashboard, STETH, _allowlistEnabled, _reserveRatioGapBP, withdrawalQueueProxy);
        } else if (
            _configuration == WrapperType.LOOP_STRATEGY ||
            _configuration == WrapperType.GGV_STRATEGY
        ) {
            if (_strategy == address(0)) revert InvalidConfiguration();
            wrapperImpl = WRAPPER_C_FACTORY.deploy(
                dashboard,
                STETH,
                _allowlistEnabled,
                _strategy,
                _reserveRatioGapBP,
                withdrawalQueueProxy
            );
        } else {
            revert InvalidConfiguration();
        }
    }

    function _setupVaultAndProxies(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry
    ) internal returns (
        address vault,
        address dashboard,
        IDashboard _dashboard,
        address payable wrapperProxy,
        address withdrawalQueueProxy
    ) {
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard{ value: msg.value }(
            address(this),
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        _dashboard = IDashboard(payable(dashboard));

        wrapperProxy = payable(address(new OssifiableProxy(DUMMY_IMPLEMENTATION, address(this), bytes(""))));
        address wqImpl = WITHDRAWAL_QUEUE_FACTORY.deploy(address(wrapperProxy), MAX_FINALIZATION_TIME);
        withdrawalQueueProxy = address(new OssifiableProxy(wqImpl, address(this), abi.encodeCall(WithdrawalQueue.initialize, (_nodeOperator, _nodeOperator))));
    }

    function _deployAndInitWrapper(
        WrapperType _configuration,
        address dashboard,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address withdrawalQueueProxy,
        address _strategy,
        address payable wrapperProxy
    ) internal returns (WrapperBase wrapper) {
        address wrapperImpl = _deployWrapper(
            _configuration,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            withdrawalQueueProxy,
            _strategy
        );

        OssifiableProxy(wrapperProxy).proxy__upgradeToAndCall(wrapperImpl, abi.encodeCall(WrapperBase.initialize, (address(this), NAME, SYMBOL)));
        wrapper = WrapperBase(payable(address(wrapperProxy)));
    }

    function _configureAndFinalize(
        IDashboard _dashboard,
        WrapperBase wrapper,
        address payable wrapperProxy,
        address withdrawalQueueProxy,
        address vault,
        WrapperType _configuration,
        address _strategy
    ) internal {
        _dashboard.grantRole(_dashboard.FUND_ROLE(), address(wrapperProxy));
        _dashboard.grantRole(_dashboard.WITHDRAW_ROLE(), withdrawalQueueProxy);

        if (_configuration != WrapperType.NO_MINTING_NO_STRATEGY) {
            _dashboard.grantRole(_dashboard.MINT_ROLE(), address(wrapperProxy));
            _dashboard.grantRole(_dashboard.BURN_ROLE(), address(wrapperProxy));
        }

        wrapper.grantRole(wrapper.DEFAULT_ADMIN_ROLE(), msg.sender);
        wrapper.revokeRole(wrapper.DEFAULT_ADMIN_ROLE(), address(this));

        _dashboard.grantRole(_dashboard.DEFAULT_ADMIN_ROLE(), msg.sender);
        _dashboard.revokeRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(
            vault,
            address(wrapper),
            withdrawalQueueProxy,
            _strategy,
            _configuration
        );
    }

}