// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Distributor} from "./Distributor.sol";
import {StvPool} from "./StvPool.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {DistributorFactory} from "./factories/DistributorFactory.sol";
import {GGVStrategyFactory} from "./factories/GGVStrategyFactory.sol";
import {StvPoolFactory} from "./factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "./factories/StvStETHPoolFactory.sol";
import {TimelockFactory} from "./factories/TimelockFactory.sol";
import {WithdrawalQueueFactory} from "./factories/WithdrawalQueueFactory.sol";
import {ILidoLocator} from "./interfaces/ILidoLocator.sol";
import {IStrategyFactory} from "./interfaces/IStrategyFactory.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {DummyImplementation} from "./proxy/DummyImplementation.sol";
import {OssifiableProxy} from "./proxy/OssifiableProxy.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

error InvalidConfiguration(string reason);
error InsufficientConnectDeposit(uint256 required, uint256 provided);
error StringTooLong(string str);

contract Factory {
    struct SubFactories {
        address stvPoolFactory;
        address stvStETHPoolFactory;
        address withdrawalQueueFactory;
        address distributorFactory;
        address ggvStrategyFactory;
        address timelockFactory;
    }

    struct VaultConfig {
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
    }

    struct TimelockConfig {
        uint256 minDelaySeconds;
        address proposer;
        address executor;
    }

    struct CommonPoolConfig {
        uint256 minWithdrawalDelayTime;
        string name;
        string symbol;
    }

    struct StvStETHPoolConfig {
        bool allowlistEnabled;
        uint256 reserveRatioGapBP;
    }

    struct AuxiliaryPoolConfig {
        bool allowlistEnabled;
        bool mintingEnabled;
        uint256 reserveRatioGapBP;
    }

    struct PoolIntermediate {
        address pool;
        address timelock;
        address strategyFactory;
        bytes strategyDeployBytes;
    }

    struct PoolDeployment {
        bytes32 poolType;
        address vault;
        address dashboard;
        address pool;
        address withdrawalQueue;
        address distributor;
        address timelock;
        address strategy;
    }

    event PoolCreationStarted(PoolIntermediate intermediate);

    event VaultPoolCreated(
        address vault, address pool, address withdrawalQueue, address indexed strategyFactory, address strategy
    );

    IVaultFactory public immutable VAULT_FACTORY;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STETH;
    address public immutable WSTETH;
    address public immutable LAZY_ORACLE;

    bytes32 public immutable STV_POOL_TYPE;
    bytes32 public immutable STV_STETH_POOL_TYPE;
    bytes32 public immutable STRATEGY_POOL_TYPE;

    StvPoolFactory public immutable STV_POOL_FACTORY;
    StvStETHPoolFactory public immutable STV_STETH_POOL_FACTORY;
    WithdrawalQueueFactory public immutable WITHDRAWAL_QUEUE_FACTORY;
    DistributorFactory public immutable DISTRIBUTOR_FACTORY;
    GGVStrategyFactory public immutable GGV_STRATEGY_FACTORY;
    TimelockFactory public immutable TIMELOCK_FACTORY;
    address public immutable DUMMY_IMPLEMENTATION;

    bytes32 public immutable DEFAULT_ADMIN_ROLE = 0x00;

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;

    uint256 public constant DEPLOY_START_FINISH_SPAN_SECONDS = 1 days;

    uint256 public constant DEPLOY_COMPLETE = type(uint256).max;

    //
    // Structured storage
    //

    mapping(bytes32 => uint256) public intermediateState;

    constructor(address _locatorAddress, SubFactories memory _subFactories) {
        ILidoLocator locator = ILidoLocator(_locatorAddress);
        VAULT_FACTORY = IVaultFactory(locator.vaultFactory());
        STETH = address(locator.lido());
        WSTETH = address(locator.wstETH());
        LAZY_ORACLE = locator.lazyOracle();
        VAULT_HUB = IVaultHub(locator.vaultHub());

        STV_POOL_FACTORY = StvPoolFactory(_subFactories.stvPoolFactory);
        STV_STETH_POOL_FACTORY = StvStETHPoolFactory(_subFactories.stvStETHPoolFactory);
        WITHDRAWAL_QUEUE_FACTORY = WithdrawalQueueFactory(_subFactories.withdrawalQueueFactory);
        DISTRIBUTOR_FACTORY = DistributorFactory(_subFactories.distributorFactory);
        GGV_STRATEGY_FACTORY = GGVStrategyFactory(_subFactories.ggvStrategyFactory);
        TIMELOCK_FACTORY = TimelockFactory(_subFactories.timelockFactory);

        DUMMY_IMPLEMENTATION = address(new DummyImplementation());

        STV_POOL_TYPE = _toBytes32("StvPool");
        STV_STETH_POOL_TYPE = _toBytes32("StvStETHPool");
        STRATEGY_POOL_TYPE = _toBytes32("StvStrategyPool");
    }

    function createPoolStvStart(
        VaultConfig memory _vaultConfig,
        TimelockConfig memory _timelockConfig,
        CommonPoolConfig memory _commonPoolConfig,
        bool _allowListEnabled
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            _vaultConfig,
            _commonPoolConfig,
            AuxiliaryPoolConfig({allowlistEnabled: _allowListEnabled, mintingEnabled: false, reserveRatioGapBP: 0}),
            _timelockConfig,
            address(0),
            ""
        );
    }

    function createPoolStvStETHStart(
        VaultConfig memory _vaultConfig,
        TimelockConfig memory _timelockConfig,
        CommonPoolConfig memory _commonPoolConfig,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            _vaultConfig,
            _commonPoolConfig,
            AuxiliaryPoolConfig({
                allowlistEnabled: _allowListEnabled, mintingEnabled: true, reserveRatioGapBP: _reserveRatioGapBP
            }),
            _timelockConfig,
            address(0),
            ""
        );
    }

    function createPoolGGVStart(
        VaultConfig memory _vaultConfig,
        TimelockConfig memory _timelockConfig,
        CommonPoolConfig memory _commonPoolConfig,
        uint256 _reserveRatioGapBP
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            _vaultConfig,
            _commonPoolConfig,
            AuxiliaryPoolConfig({allowlistEnabled: true, mintingEnabled: true, reserveRatioGapBP: _reserveRatioGapBP}),
            _timelockConfig,
            address(GGV_STRATEGY_FACTORY),
            ""
        );
    }

    function createPoolStart(
        VaultConfig memory _vaultConfig,
        CommonPoolConfig memory _commonPoolConfig,
        AuxiliaryPoolConfig memory _auxiliaryConfig,
        TimelockConfig memory _timelockConfig,
        address _strategyFactory,
        bytes memory _strategyDeployBytes
    ) public payable returns (PoolIntermediate memory intermediate) {
        if (msg.value < VAULT_HUB.CONNECT_DEPOSIT()) {
            revert InsufficientConnectDeposit(VAULT_HUB.CONNECT_DEPOSIT(), msg.value);
        }

        bytes32 poolType = STV_POOL_TYPE;
        if (_strategyFactory != address(0)) {
            poolType = STRATEGY_POOL_TYPE;
            if (!_auxiliaryConfig.allowlistEnabled) {
                revert InvalidConfiguration("allowlistEnabled must be true if strategy factory is set");
            }
        } else if (_auxiliaryConfig.mintingEnabled) {
            poolType = STV_STETH_POOL_TYPE;
        }

        if (bytes(_commonPoolConfig.name).length == 0 || bytes(_commonPoolConfig.symbol).length == 0) {
            revert InvalidConfiguration("name and symbol must be set");
        }

        address timelock =
            TIMELOCK_FACTORY.deploy(_timelockConfig.minDelaySeconds, _timelockConfig.proposer, _timelockConfig.executor);

        address tempAdmin = address(this);

        (, address dashboardAddress) = VAULT_FACTORY.createVaultWithDashboard{value: msg.value}(
            tempAdmin,
            _vaultConfig.nodeOperator,
            _vaultConfig.nodeOperatorManager,
            _vaultConfig.nodeOperatorFeeBP,
            _vaultConfig.confirmExpiry,
            new IVaultFactory.RoleAssignment[](0) // NB: assigned later because require pool and wq deployed
        );

        address poolProxy = payable(address(new OssifiableProxy(DUMMY_IMPLEMENTATION, tempAdmin, bytes(""))));

        address wqImpl = WITHDRAWAL_QUEUE_FACTORY.deploy(
            poolProxy,
            dashboardAddress,
            address(VAULT_HUB),
            STETH,
            address(IDashboard(payable(dashboardAddress)).stakingVault()),
            LAZY_ORACLE,
            _commonPoolConfig.minWithdrawalDelayTime,
            _auxiliaryConfig.mintingEnabled
        );

        address withdrawalQueueProxy = address(
            new OssifiableProxy(
                wqImpl,
                timelock,
                abi.encodeCall(
                    WithdrawalQueue.initialize,
                    (timelock, _vaultConfig.nodeOperator) // (admin, finalizerRoleHolder)
                )
            )
        );

        address distributor = DISTRIBUTOR_FACTORY.deploy(_vaultConfig.nodeOperator, _vaultConfig.nodeOperatorManager);

        address poolImpl = address(0);
        if (poolType == STV_POOL_TYPE) {
            poolImpl = STV_POOL_FACTORY.deploy(
                dashboardAddress, _auxiliaryConfig.allowlistEnabled, withdrawalQueueProxy, distributor, poolType
            );
        } else if (poolType == STV_STETH_POOL_TYPE || poolType == STRATEGY_POOL_TYPE) {
            poolImpl = STV_STETH_POOL_FACTORY.deploy(
                dashboardAddress,
                _auxiliaryConfig.allowlistEnabled,
                _auxiliaryConfig.reserveRatioGapBP,
                withdrawalQueueProxy,
                distributor,
                poolType
            );
        }

        OssifiableProxy(payable(poolProxy))
            .proxy__upgradeToAndCall(
                poolImpl,
                abi.encodeCall(StvPool.initialize, (tempAdmin, _commonPoolConfig.name, _commonPoolConfig.symbol))
            );
        OssifiableProxy(payable(poolProxy)).proxy__changeAdmin(timelock);

        intermediate = PoolIntermediate({
            pool: poolProxy,
            timelock: timelock,
            strategyFactory: _strategyFactory,
            strategyDeployBytes: _strategyDeployBytes
        });

        bytes32 deploymentHash = _hashIntermediate(intermediate, msg.sender);
        uint256 finishDeadline = block.timestamp + DEPLOY_START_FINISH_SPAN_SECONDS;
        intermediateState[deploymentHash] = finishDeadline;

        emit PoolCreationStarted(intermediate);
    }

    function createPoolFinish(PoolIntermediate calldata _intermediate)
        external
        returns (PoolDeployment memory deployment)
    {
        bytes32 deploymentHash = _hashIntermediate(_intermediate, msg.sender);
        uint256 finishDeadline = intermediateState[deploymentHash];
        if (finishDeadline == 0) {
            revert InvalidConfiguration("deploy not started");
        } else if (finishDeadline == DEPLOY_COMPLETE) {
            revert InvalidConfiguration("deploy already finished");
        }
        if (block.timestamp > finishDeadline) {
            revert InvalidConfiguration("deploy finish deadline passed");
        }
        intermediateState[deploymentHash] = DEPLOY_COMPLETE;

        StvPool pool = StvPool(payable(_intermediate.pool));
        IDashboard dashboard = pool.DASHBOARD();
        WithdrawalQueue withdrawalQueue = pool.WITHDRAWAL_QUEUE();
        address timelock = _intermediate.timelock;
        address tempAdmin = address(this);
        bytes32 poolType = pool.poolType();

        dashboard.grantRole(dashboard.FUND_ROLE(), address(pool));
        dashboard.grantRole(dashboard.REBALANCE_ROLE(), address(pool));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));

        if (poolType != STV_POOL_TYPE) {
            dashboard.grantRole(dashboard.MINT_ROLE(), address(pool));
            dashboard.grantRole(dashboard.BURN_ROLE(), address(pool));
        }

        address strategy = address(0);
        if (_intermediate.strategyFactory != address(0)) {
            strategy =
                IStrategyFactory(_intermediate.strategyFactory).deploy(address(pool), _intermediate.strategyDeployBytes);
            pool.addToAllowList(strategy);
        }

        pool.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        pool.revokeRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        dashboard.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        dashboard.revokeRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        deployment = PoolDeployment({
            poolType: poolType,
            vault: address(pool.STAKING_VAULT()),
            dashboard: address(dashboard),
            pool: _intermediate.pool,
            withdrawalQueue: address(withdrawalQueue),
            distributor: address(pool.DISTRIBUTOR()),
            timelock: _intermediate.timelock,
            strategy: strategy
        });

        emit VaultPoolCreated(
            deployment.vault,
            deployment.pool,
            deployment.withdrawalQueue,
            _intermediate.strategyFactory,
            deployment.strategy
        );

        // TODO: LOSS_SOCIALIZER_ROLE
    }

    function _hashIntermediate(PoolIntermediate memory _intermediate, address _sender)
        public
        pure
        returns (bytes32 result)
    {
        result = keccak256(abi.encodePacked(_sender, abi.encode(_intermediate)));
    }

    /// @dev encodes string `_str` in bytes32. Reverts if the string length > 31
    function _toBytes32(string memory _str) internal pure returns (bytes32) {
        bytes memory bstr = bytes(_str);
        if (bstr.length > 31) {
            revert StringTooLong(_str);
        }
        return bytes32(uint256(bytes32(bstr)) | bstr.length);
    }

}
