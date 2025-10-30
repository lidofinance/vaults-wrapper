// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {BasePool} from "./BasePool.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {StvPoolFactory} from "./factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "./factories/StvStETHPoolFactory.sol";
import {StvStrategyPoolFactory} from "./factories/StvStrategyPoolFactory.sol";
import {WithdrawalQueueFactory} from "./factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "./factories/DistributorFactory.sol";
import {LoopStrategyFactory} from "./factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "./factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "./factories/TimelockFactory.sol";
import {OssifiableProxy} from "./proxy/OssifiableProxy.sol";
import {Distributor} from "./Distributor.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

error InvalidConfiguration();

contract Factory {
    struct WrapperConfig {
        address vaultFactory;
        address steth;
        address wsteth;
        address lazyOracle;
        address stvPoolFactory;
        address stvStETHPoolFactory;
        address stvStrategyPoolFactory;
        address withdrawalQueueFactory;
        address distributorFactory;
        address loopStrategyFactory;
        address ggvStrategyFactory;
        address dummyImplementation;
        address timelockFactory;
    }

    struct TimelockConfig {
        uint256 minDelaySeconds;
    }

    IVaultFactory public immutable VAULT_FACTORY;
    address public immutable STETH;
    address public immutable WSTETH;
    address public immutable LAZY_ORACLE;
    StvPoolFactory public immutable STV_POOL_FACTORY;
    StvStETHPoolFactory public immutable STV_STETH_POOL_FACTORY;
    StvStrategyPoolFactory public immutable STV_STRATEGY_POOL_FACTORY;
    WithdrawalQueueFactory public immutable WITHDRAWAL_QUEUE_FACTORY;
    DistributorFactory public immutable DISTRIBUTOR_FACTORY;
    LoopStrategyFactory public immutable LOOP_STRATEGY_FACTORY;
    GGVStrategyFactory public immutable GGV_STRATEGY_FACTORY;
    TimelockFactory public immutable TIMELOCK_FACTORY;
    address public immutable DUMMY_IMPLEMENTATION;
    uint256 public immutable TIMELOCK_MIN_DELAY;
    uint256 public constant TOTAL_BASIS_POINTS = 100_00;
    string constant NAME = "Staked ETH Vault Wrapper";
    string constant SYMBOL = "stvToken";

    event VaultWrapperCreated(
        address indexed vault,
        address indexed pool,
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

    constructor(WrapperConfig memory poolConfig, TimelockConfig memory timelockConfig) {
        VAULT_FACTORY = IVaultFactory(poolConfig.vaultFactory);
        STETH = poolConfig.steth;
        WSTETH = poolConfig.wsteth;
        LAZY_ORACLE = poolConfig.lazyOracle;
        STV_POOL_FACTORY = StvPoolFactory(poolConfig.stvPoolFactory);
        STV_STETH_POOL_FACTORY = StvStETHPoolFactory(poolConfig.stvStETHPoolFactory);
        STV_STRATEGY_POOL_FACTORY = StvStrategyPoolFactory(poolConfig.stvStrategyPoolFactory);
        WITHDRAWAL_QUEUE_FACTORY = WithdrawalQueueFactory(poolConfig.withdrawalQueueFactory);
        DISTRIBUTOR_FACTORY = DistributorFactory(poolConfig.distributorFactory);
        LOOP_STRATEGY_FACTORY = LoopStrategyFactory(poolConfig.loopStrategyFactory);
        GGV_STRATEGY_FACTORY = GGVStrategyFactory(poolConfig.ggvStrategyFactory);
        DUMMY_IMPLEMENTATION = poolConfig.dummyImplementation;
        TIMELOCK_FACTORY = TimelockFactory(poolConfig.timelockFactory);

        TIMELOCK_MIN_DELAY = timelockConfig.minDelaySeconds;
    }

    function createVaultWithConfiguredWrapper(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        WrapperType _configuration,
        address _strategy,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _timelockExecutor
    )
        external
        payable
        returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor)
    {
        bool isRebalancingSupported = _configuration == WrapperType.NO_MINTING_NO_STRATEGY ? false : true;

        IDashboard _dashboard;
        address payable _poolProxy;
        address _withdrawalQueueProxy;
        address _distributor;
        (vault, dashboard, _dashboard, _poolProxy, _withdrawalQueueProxy, _distributor) = _setupVaultAndProxies(
            _nodeOperator, _nodeOperatorManager, _nodeOperatorFeeBP, _confirmExpiry, _maxFinalizationTime, _minWithdrawalDelayTime, isRebalancingSupported
        );

        address usedStrategy = _strategy;
        if (_configuration == WrapperType.LOOP_STRATEGY && usedStrategy == address(0)) {
            usedStrategy = LOOP_STRATEGY_FACTORY.deploy(STETH, address(_poolProxy), 1);
        }

        BasePool pool = _deployAndInitWrapper(
            _configuration,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            _distributor,
            usedStrategy,
            _poolProxy
        );

        _configureAndFinalize(
            _dashboard, pool, _poolProxy, _withdrawalQueueProxy, vault, _configuration, usedStrategy
        );
        _finalizeDistributor(_distributor);

        _finalizeGovernance(_poolProxy, _withdrawalQueueProxy, _timelockExecutor);
        return (vault, dashboard, _poolProxy, _withdrawalQueueProxy, _distributor);
    }

    // =================================================================================
    // Overloads per configuration
    // =================================================================================

    function createVaultWithNoMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        address _timelockExecutor
    )
        external
        payable
        returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor)
    {
        return _createVaultWithNoMintingNoStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _timelockExecutor
        );
    }

    // Backward-compatible overload without timelock executor
    function createVaultWithNoMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled
    ) external payable returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor) {
        return _createVaultWithNoMintingNoStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            address(0)
        );
    }

    function _createVaultWithNoMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        address _timelockExecutor
    ) internal returns (address vault, address dashboard, address payable _poolProxy, address _withdrawalQueueProxy, address _distributor) {
        IDashboard _dashboard;
        (vault, dashboard, _dashboard, _poolProxy, _withdrawalQueueProxy, _distributor) = _setupVaultAndProxies(
            _nodeOperator, _nodeOperatorManager, _nodeOperatorFeeBP, _confirmExpiry, _maxFinalizationTime, _minWithdrawalDelayTime, false
        );

        BasePool pool = _deployAndInitWrapper(
            WrapperType.NO_MINTING_NO_STRATEGY,
            dashboard,
            _allowlistEnabled,
            0,
            _withdrawalQueueProxy,
            _distributor,
            address(0),
            _poolProxy
        );

        _configureAndFinalize(
            _dashboard,
            pool,
            _poolProxy,
            _withdrawalQueueProxy,
            vault,
            WrapperType.NO_MINTING_NO_STRATEGY,
            address(0)
        );
        _finalizeDistributor(_distributor);

        _finalizeGovernance(_poolProxy, _withdrawalQueueProxy, _timelockExecutor);
    }

    function createVaultWithMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _timelockExecutor
    )
        external
        payable
        returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor)
    {
        return _createVaultWithMintingNoStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _timelockExecutor
        );
    }

    // Backward-compatible overload without timelock executor
    function createVaultWithMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP
    ) external payable returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address distributor) {
        return _createVaultWithMintingNoStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            address(0)
        );
    }

    function _createVaultWithMintingNoStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _timelockExecutor
    ) internal returns (address vault, address dashboard, address payable _poolProxy, address _withdrawalQueueProxy, address _distributor) {
        IDashboard _dashboard;

        (vault, dashboard, _dashboard, _poolProxy, _withdrawalQueueProxy, _distributor) = _setupVaultAndProxies(
            _nodeOperator, _nodeOperatorManager, _nodeOperatorFeeBP, _confirmExpiry, _maxFinalizationTime, _minWithdrawalDelayTime, true
        );

        BasePool pool = _deployAndInitWrapper(
            WrapperType.MINTING_NO_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            _distributor,
            address(0),
            _poolProxy
        );

        _configureAndFinalize(
            _dashboard,
            pool,
            _poolProxy,
            _withdrawalQueueProxy,
            vault,
            WrapperType.MINTING_NO_STRATEGY,
            address(0)
        );
        
        _finalizeDistributor(_distributor);
        _finalizeGovernance(_poolProxy, _withdrawalQueueProxy, _timelockExecutor);
    }

    function createVaultWithLoopStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        uint256 _loops,
        address _timelockExecutor
    )
        external
        payable
        returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address strategy, address distributor)
    {
        return _createVaultWithLoopStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _loops,
            _timelockExecutor
        );
    }

    // Backward-compatible overload without timelock executor
    function createVaultWithLoopStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        uint256 _loops
    ) external payable returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address strategy, address distributor) {
        return _createVaultWithLoopStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _loops,
            address(0)
        );
    }

    function _createVaultWithLoopStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        uint256 _loops,
        address _timelockExecutor
    ) internal returns (address vault, address dashboard, address payable _poolProxy, address _withdrawalQueueProxy, address loopStrategy, address _distributor) {
        IDashboard _dashboard;
        (vault, dashboard, _dashboard, _poolProxy, _withdrawalQueueProxy, _distributor) = _setupVaultAndProxies(
            _nodeOperator, _nodeOperatorManager, _nodeOperatorFeeBP, _confirmExpiry, _maxFinalizationTime, _minWithdrawalDelayTime, true
        );

        loopStrategy = LOOP_STRATEGY_FACTORY.deploy(STETH, address(_poolProxy), _loops);

        BasePool pool = _deployAndInitWrapper(
            WrapperType.LOOP_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            _distributor,
            loopStrategy,
            _poolProxy
        );

        _configureAndFinalize(
            _dashboard, pool, _poolProxy, _withdrawalQueueProxy, vault, WrapperType.LOOP_STRATEGY, loopStrategy
        );
        _finalizeDistributor(_distributor);

        _finalizeGovernance(_poolProxy, _withdrawalQueueProxy, _timelockExecutor);
    }

    function createVaultWithGGVStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _teller,
        address _boringQueue,
        address _timelockExecutor
    )
        external
        payable
        returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address strategy, address distributor)
    {
        return _createVaultWithGGVStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _teller,
            _boringQueue,
            _timelockExecutor
        );
    }

    // Backward-compatible overload without timelock executor
    function createVaultWithGGVStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _teller,
        address _boringQueue
    ) external payable returns (address vault, address dashboard, address payable poolProxy, address withdrawalQueueProxy, address strategy, address distributor) {
        return _createVaultWithGGVStrategy(
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _teller,
            _boringQueue,
            address(0)
        );
    }

    function _createVaultWithGGVStrategy(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address _teller,
        address _boringQueue,
        address _timelockExecutor
    ) internal returns (address vault, address dashboard, address payable _poolProxy, address _withdrawalQueueProxy, address ggvStrategy, address _distributor) {
        IDashboard _dashboard;
        (vault, dashboard, _dashboard, _poolProxy, _withdrawalQueueProxy, _distributor) = _setupVaultAndProxies(
            _nodeOperator, _nodeOperatorManager, _nodeOperatorFeeBP, _confirmExpiry, _maxFinalizationTime, _minWithdrawalDelayTime, true
        );

        ggvStrategy = GGV_STRATEGY_FACTORY.deploy(_poolProxy, STETH, WSTETH, _teller, _boringQueue);

        BasePool pool = _deployAndInitWrapper(
            WrapperType.GGV_STRATEGY,
            dashboard,
            _allowlistEnabled,
            _reserveRatioGapBP,
            _withdrawalQueueProxy,
            _distributor,
            ggvStrategy,
            _poolProxy
        );

        _configureAndFinalize(
            _dashboard, pool, _poolProxy, _withdrawalQueueProxy, vault, WrapperType.GGV_STRATEGY, ggvStrategy
        );
        _finalizeDistributor(_distributor);

        _finalizeGovernance(_poolProxy, _withdrawalQueueProxy, _timelockExecutor);
    }

    function _deployWrapper(
        WrapperType _configuration,
        address dashboard,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address withdrawalQueueProxy,
        address distributor,
        address _strategy
    ) internal returns (address poolImpl) {
        if (_reserveRatioGapBP >= TOTAL_BASIS_POINTS) revert InvalidConfiguration();

        if (_configuration == WrapperType.NO_MINTING_NO_STRATEGY) {
            poolImpl = STV_POOL_FACTORY.deploy(dashboard, _allowlistEnabled, withdrawalQueueProxy, distributor);
            assert(keccak256(bytes(BasePool(payable(poolImpl)).wrapperType())) == keccak256(bytes("StvPool")));
        } else if (_configuration == WrapperType.MINTING_NO_STRATEGY) {
            poolImpl = STV_STETH_POOL_FACTORY.deploy(dashboard, _allowlistEnabled, _reserveRatioGapBP, withdrawalQueueProxy, distributor);
            assert(keccak256(bytes(BasePool(payable(poolImpl)).wrapperType())) == keccak256(bytes("StvStETHPool")));
        } else if (_configuration == WrapperType.LOOP_STRATEGY || _configuration == WrapperType.GGV_STRATEGY) {
            if (_strategy == address(0)) revert InvalidConfiguration();
            poolImpl = STV_STRATEGY_POOL_FACTORY.deploy(
                dashboard,
                _allowlistEnabled,
                _reserveRatioGapBP,
                withdrawalQueueProxy,
                distributor
            );
            assert(keccak256(bytes(BasePool(payable(poolImpl)).wrapperType())) == keccak256(bytes("StvStrategyPool")));
        } else {
            revert InvalidConfiguration();
        }
    }

    function _setupVaultAndProxies(
        address _nodeOperator,
        address _nodeOperatorManager,
        uint256 _nodeOperatorFeeBP,
        uint256 _confirmExpiry,
        uint256 _maxFinalizationTime,
        uint256 _minWithdrawalDelayTime,
        bool _isRebalancingSupported
    )
        internal
        returns (
            address vault,
            address dashboard,
            IDashboard _dashboard,
            address payable poolProxy,
            address withdrawalQueueProxy,
            address distributor
        )
    {
        (vault, dashboard) = VAULT_FACTORY.createVaultWithDashboard{value: msg.value}(
            address(this),
            _nodeOperator,
            _nodeOperatorManager,
            _nodeOperatorFeeBP,
            _confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        _dashboard = IDashboard(payable(dashboard));

        poolProxy = payable(address(new OssifiableProxy(DUMMY_IMPLEMENTATION, address(this), bytes(""))));
        
        distributor = DISTRIBUTOR_FACTORY.deploy(address(this));
        
        address wqImpl = WITHDRAWAL_QUEUE_FACTORY.deploy(
            address(poolProxy),
            dashboard,
            _dashboard.VAULT_HUB(),
            _dashboard.STETH(),
            vault,
            LAZY_ORACLE,
            _maxFinalizationTime,
            _minWithdrawalDelayTime,
            _isRebalancingSupported
        );
        withdrawalQueueProxy = address(
            new OssifiableProxy(
                wqImpl, address(this), abi.encodeCall(WithdrawalQueue.initialize, (_nodeOperator, _nodeOperator))
            )
        );
    }

    function _deployAndInitWrapper(
        WrapperType _configuration,
        address dashboard,
        bool _allowlistEnabled,
        uint256 _reserveRatioGapBP,
        address withdrawalQueueProxy,
        address distributor,
        address _strategy,
        address payable poolProxy
    ) internal returns (BasePool pool) {
        address poolImpl = _deployWrapper(
            _configuration, dashboard, _allowlistEnabled, _reserveRatioGapBP, withdrawalQueueProxy, distributor, _strategy
        );

        OssifiableProxy(poolProxy).proxy__upgradeToAndCall(
            poolImpl, abi.encodeCall(BasePool.initialize, (address(this), NAME, SYMBOL))
        );
        pool = BasePool(payable(address(poolProxy)));
    }

    function _finalizeGovernance(
        address payable _poolProxy,
        address _withdrawalQueueProxy,
        address _timelockExecutor
    ) internal {
        uint256 minDelay = TIMELOCK_MIN_DELAY;
        address proposer = msg.sender;
        address timelock = TIMELOCK_FACTORY.deploy(minDelay, proposer, _timelockExecutor);

        OssifiableProxy(_poolProxy).proxy__changeAdmin(timelock);
        OssifiableProxy(payable(_withdrawalQueueProxy)).proxy__changeAdmin(timelock);
    }

    function _configureAndFinalize(
        IDashboard _dashboard,
        BasePool pool,
        address payable poolProxy,
        address withdrawalQueueProxy,
        address vault,
        WrapperType _configuration,
        address _strategy
    ) internal {
        _dashboard.grantRole(_dashboard.FUND_ROLE(), address(poolProxy));
        _dashboard.grantRole(_dashboard.WITHDRAW_ROLE(), withdrawalQueueProxy);
        _dashboard.grantRole(_dashboard.REBALANCE_ROLE(), address(poolProxy));

        if (_configuration != WrapperType.NO_MINTING_NO_STRATEGY) {
            _dashboard.grantRole(_dashboard.MINT_ROLE(), address(poolProxy));
            _dashboard.grantRole(_dashboard.BURN_ROLE(), address(poolProxy));
        }

        // Add strategy to allowlist if provided
        if (_strategy != address(0)) {
            pool.grantRole(pool.DEPOSIT_ROLE(), _strategy);
        }

        pool.grantRole(pool.ALLOW_LIST_MANAGER_ROLE(), msg.sender);
        pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), msg.sender);
        pool.revokeRole(pool.DEFAULT_ADMIN_ROLE(), address(this));

        _dashboard.grantRole(_dashboard.DEFAULT_ADMIN_ROLE(), msg.sender);
        _dashboard.revokeRole(_dashboard.DEFAULT_ADMIN_ROLE(), address(this));

        emit VaultWrapperCreated(vault, address(pool), withdrawalQueueProxy, _strategy, _configuration);
    }

    function _finalizeDistributor(address _distributor) internal {
        Distributor distributor = Distributor(_distributor);
        distributor.grantRole(distributor.DEFAULT_ADMIN_ROLE(), msg.sender);
        distributor.grantRole(distributor.MANAGER_ROLE(), msg.sender);
        distributor.revokeRole(distributor.MANAGER_ROLE(), address(this));
        distributor.revokeRole(distributor.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
