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
        address executor;
        // proposer is set to the node operator
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

    bytes32 public immutable STV_POOL_TYPE = keccak256("StvPool");
    bytes32 public immutable STV_STETH_POOL_TYPE = keccak256("StvStETHPool");
    bytes32 public immutable STRATEGY_POOL_TYPE = keccak256("StvStrategyPool");

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

    mapping(bytes32 => uint256) public intermediateState;

    constructor(address locatorAddress, SubFactories memory subFactories) {
        ILidoLocator locator = ILidoLocator(locatorAddress);
        VAULT_FACTORY = IVaultFactory(locator.vaultFactory());
        STETH = address(locator.lido());
        WSTETH = address(locator.wstETH());
        LAZY_ORACLE = locator.lazyOracle();
        VAULT_HUB = IVaultHub(locator.vaultHub());

        STV_POOL_FACTORY = StvPoolFactory(subFactories.stvPoolFactory);
        STV_STETH_POOL_FACTORY = StvStETHPoolFactory(subFactories.stvStETHPoolFactory);
        WITHDRAWAL_QUEUE_FACTORY = WithdrawalQueueFactory(subFactories.withdrawalQueueFactory);
        DISTRIBUTOR_FACTORY = DistributorFactory(subFactories.distributorFactory);
        GGV_STRATEGY_FACTORY = GGVStrategyFactory(subFactories.ggvStrategyFactory);
        TIMELOCK_FACTORY = TimelockFactory(subFactories.timelockFactory);
        DUMMY_IMPLEMENTATION = address(new DummyImplementation());
    }

    function createPoolStvStart(
        VaultConfig memory vaultConfig,
        TimelockConfig memory timelockConfig,
        CommonPoolConfig memory commonPoolConfig,
        bool allowListEnabled
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            vaultConfig,
            commonPoolConfig,
            AuxiliaryPoolConfig({allowlistEnabled: allowListEnabled, mintingEnabled: false, reserveRatioGapBP: 0}),
            timelockConfig,
            address(0),
            ""
        );
    }

    function createPoolStvStETHStart(
        VaultConfig memory vaultConfig,
        TimelockConfig memory timelockConfig,
        CommonPoolConfig memory commonPoolConfig,
        bool allowListEnabled,
        uint256 reserveRatioGapBP
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            vaultConfig,
            commonPoolConfig,
            AuxiliaryPoolConfig({
                allowlistEnabled: allowListEnabled, mintingEnabled: true, reserveRatioGapBP: reserveRatioGapBP
            }),
            timelockConfig,
            address(0),
            ""
        );
    }

    function createPoolGGVStart(
        VaultConfig memory vaultConfig,
        TimelockConfig memory timelockConfig,
        CommonPoolConfig memory commonPoolConfig,
        uint256 reserveRatioGapBP
    ) external payable returns (PoolIntermediate memory intermediate) {
        intermediate = createPoolStart(
            vaultConfig,
            commonPoolConfig,
            AuxiliaryPoolConfig({allowlistEnabled: true, mintingEnabled: true, reserveRatioGapBP: reserveRatioGapBP}),
            timelockConfig,
            address(GGV_STRATEGY_FACTORY),
            ""
        );
    }

    function createPoolStart(
        VaultConfig memory vaultConfig,
        CommonPoolConfig memory commonPoolConfig,
        AuxiliaryPoolConfig memory auxiliaryConfig,
        TimelockConfig memory timelockConfig,
        address strategyFactory,
        bytes memory strategyDeployBytes
    ) public payable returns (PoolIntermediate memory intermediate) {
        if (msg.value < VAULT_HUB.CONNECT_DEPOSIT()) {
            revert InsufficientConnectDeposit(VAULT_HUB.CONNECT_DEPOSIT(), msg.value);
        }

        bytes32 poolType = STV_POOL_TYPE;
        if (strategyFactory != address(0)) {
            poolType = STRATEGY_POOL_TYPE;
            if (!auxiliaryConfig.allowlistEnabled) {
                revert InvalidConfiguration("allowlistEnabled must be true if strategy factory is set");
            }
        } else if (auxiliaryConfig.mintingEnabled) {
            poolType = STV_STETH_POOL_TYPE;
        }

        // TODO: maybe check taking into account Vault's reserve ratio
        if (auxiliaryConfig.reserveRatioGapBP >= TOTAL_BASIS_POINTS) {
            revert InvalidConfiguration("reserveRatioGapBP must be less than TOTAL_BASIS_POINTS");
        }

        if (bytes(commonPoolConfig.name).length == 0 || bytes(commonPoolConfig.symbol).length == 0) {
            revert InvalidConfiguration("name and symbol must be set");
        }

        address timelock =
            TIMELOCK_FACTORY.deploy(timelockConfig.minDelaySeconds, vaultConfig.nodeOperator, timelockConfig.executor);

        address tempAdmin = address(this);

        (, address dashboardAddress) = VAULT_FACTORY.createVaultWithDashboard{value: msg.value}(
            tempAdmin, // TODO
            vaultConfig.nodeOperator,
            vaultConfig.nodeOperatorManager,
            vaultConfig.nodeOperatorFeeBP,
            vaultConfig.confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        address poolProxy = payable(address(new OssifiableProxy(DUMMY_IMPLEMENTATION, tempAdmin, bytes(""))));

        address wqImpl = WITHDRAWAL_QUEUE_FACTORY.deploy(
            poolProxy,
            dashboardAddress,
            address(VAULT_HUB),
            STETH,
            address(IDashboard(payable(dashboardAddress)).stakingVault()),
            LAZY_ORACLE,
            commonPoolConfig.minWithdrawalDelayTime,
            auxiliaryConfig.mintingEnabled
        );

        address withdrawalQueueProxy = address(
            new OssifiableProxy(
                wqImpl,
                timelock,
                abi.encodeCall(
                    WithdrawalQueue.initialize,
                    (timelock, vaultConfig.nodeOperator) // (admin, finalizerRoleHolder)
                )
            )
        );

        address distributor = DISTRIBUTOR_FACTORY.deploy(vaultConfig.nodeOperator, vaultConfig.nodeOperatorManager);

        address poolImpl = address(0);
        if (poolType == STV_POOL_TYPE) {
            poolImpl = STV_POOL_FACTORY.deploy(
                dashboardAddress, auxiliaryConfig.allowlistEnabled, withdrawalQueueProxy, distributor
            );
        } else if (poolType == STV_STETH_POOL_TYPE || poolType == STRATEGY_POOL_TYPE) {
            poolImpl = STV_STETH_POOL_FACTORY.deploy(
                dashboardAddress,
                auxiliaryConfig.allowlistEnabled,
                auxiliaryConfig.reserveRatioGapBP,
                withdrawalQueueProxy,
                distributor,
                poolType
            );
        }

        OssifiableProxy(payable(poolProxy))
            .proxy__upgradeToAndCall(
                poolImpl,
                abi.encodeCall(StvPool.initialize, (tempAdmin, commonPoolConfig.name, commonPoolConfig.symbol))
            );
        OssifiableProxy(payable(poolProxy)).proxy__changeAdmin(timelock);

        intermediate = PoolIntermediate({
            pool: poolProxy,
            timelock: timelock,
            strategyFactory: strategyFactory,
            strategyDeployBytes: strategyDeployBytes
        });

        bytes32 deploymentHash = _hashIntermediate(intermediate, msg.sender);
        uint256 finishDeadline = block.timestamp + DEPLOY_START_FINISH_SPAN_SECONDS;
        intermediateState[deploymentHash] = finishDeadline;

        emit PoolCreationStarted(intermediate);
    }

    function createPoolFinish(PoolIntermediate calldata intermediate)
        external
        returns (PoolDeployment memory deployment)
    {
        bytes32 deploymentHash = _hashIntermediate(intermediate, msg.sender);
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

        StvPool pool = StvPool(payable(intermediate.pool));
        IDashboard dashboard = pool.DASHBOARD();
        WithdrawalQueue withdrawalQueue = pool.WITHDRAWAL_QUEUE();
        address timelock = intermediate.timelock;
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
        if (intermediate.strategyFactory != address(0)) {
            strategy =
                IStrategyFactory(intermediate.strategyFactory).deploy(address(pool), intermediate.strategyDeployBytes);
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
            pool: intermediate.pool,
            withdrawalQueue: address(withdrawalQueue),
            distributor: address(pool.DISTRIBUTOR()),
            timelock: intermediate.timelock,
            strategy: strategy
        });

        emit VaultPoolCreated(
            deployment.vault,
            deployment.pool,
            deployment.withdrawalQueue,
            intermediate.strategyFactory,
            deployment.strategy
        );

        // TODO: LOSS_SOCIALIZER_ROLE
    }

    function _hashIntermediate(PoolIntermediate memory intermediate, address sender)
        public
        pure
        returns (bytes32 result)
    {
        result = keccak256(abi.encodePacked(sender, abi.encode(intermediate)));
    }
}
