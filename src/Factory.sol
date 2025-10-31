// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {StvPool} from "./StvPool.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {StvPoolFactory} from "./factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "./factories/StvStETHPoolFactory.sol";
import {WithdrawalQueueFactory} from "./factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "./factories/DistributorFactory.sol";
import {LoopStrategyFactory} from "./factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "./factories/GGVStrategyFactory.sol";
import {TimelockFactory} from "./factories/TimelockFactory.sol";
import {OssifiableProxy} from "./proxy/OssifiableProxy.sol";
import {Distributor} from "./Distributor.sol";
import {DummyImplementation} from "./proxy/DummyImplementation.sol";
import {ILidoLocator} from "./interfaces/ILidoLocator.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IStrategyFactory} from "./interfaces/IStrategyFactory.sol";

import {IVaultFactory} from "./interfaces/IVaultFactory.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";

error InvalidConfiguration();
error InsufficientConnectDeposit(uint256 required, uint256 provided);

contract Factory {

    struct SubFactories {
        address stvPoolFactory;
        address stvStETHPoolFactory;
        address withdrawalQueueFactory;
        address distributorFactory;
        address loopStrategyFactory;
        address ggvStrategyFactory;
        address timelockFactory;
    }

    struct TimelockConfig {
        uint256 minDelaySeconds;
        address executor;
    }

    struct StrategyParameters {
        address ggvTeller;
        address ggvBoringOnChainQueue;
    }

    enum PoolType {
        STV,
        STV_STETH,
        STRATEGY
    }

    IVaultFactory public immutable VAULT_FACTORY;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STETH;
    address public immutable WSTETH;
    address public immutable LAZY_ORACLE;


    StvPoolFactory public immutable STV_POOL_FACTORY;
    StvStETHPoolFactory public immutable STV_STETH_POOL_FACTORY;
    WithdrawalQueueFactory public immutable WITHDRAWAL_QUEUE_FACTORY;
    DistributorFactory public immutable DISTRIBUTOR_FACTORY;
    LoopStrategyFactory public immutable LOOP_STRATEGY_FACTORY;
    GGVStrategyFactory public immutable GGV_STRATEGY_FACTORY;
    TimelockFactory public immutable TIMELOCK_FACTORY;
    address public immutable DUMMY_IMPLEMENTATION;

    address public immutable GGV_TELLER;
    address public immutable GGV_BORING_ON_CHAIN_QUEUE;

    bytes32 public immutable DEFAULT_ADMIN_ROLE = 0x00;

    uint256 public immutable TIMELOCK_MIN_DELAY;
    address public immutable TIMELOCK_EXECUTOR;
    uint256 public constant TOTAL_BASIS_POINTS = 100_00;

    string public constant SYMBOL = "stv";

    string public constant NAME_STV = "Staked ETH Vault Pool";
    string public constant NAME_STV_STETH = "Staked ETH Vault StETH Pool";
    string public constant NAME_STV_STRATEGY = "Staked ETH Vault Strategy Pool";

    event VaultPoolCreated(
        address indexed vault,
        address indexed pool,
        address indexed withdrawalQueue,
        address strategy
    );

    struct StvPoolConfig {
        bool allowlistEnabled;
        address owner;
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
    }

    struct StvStETHPoolConfig {
        bool allowlistEnabled;
        address owner;
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        uint256 reserveRatioGapBP;
    }

    struct GGVPoolConfig {
        address owner;
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        uint256 reserveRatioGapBP;
    }

    struct PoolFullConfig {
        bool allowlistEnabled;
        bool mintingEnabled;
        address owner; // TODO: owner of what?
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        uint256 reserveRatioGapBP;
    }

    struct StrategyConfig {
        address factory;
    }

    struct StvPoolIntermediate {
        address dashboard;
        address pool;
        address timelock;
    }

    struct StvPoolDeployment {
        address pool;
        address withdrawalQueue;
        // address distributor;
    }

    constructor(
        address locatorAddress,
        SubFactories memory subFactories,
        TimelockConfig memory timelockConfig,
        StrategyParameters memory strategyParameters
    ) {
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
        LOOP_STRATEGY_FACTORY = LoopStrategyFactory(subFactories.loopStrategyFactory);
        GGV_STRATEGY_FACTORY = GGVStrategyFactory(subFactories.ggvStrategyFactory);
        TIMELOCK_FACTORY = TimelockFactory(subFactories.timelockFactory);
        DUMMY_IMPLEMENTATION = address(new DummyImplementation());

        TIMELOCK_MIN_DELAY = timelockConfig.minDelaySeconds;
        TIMELOCK_EXECUTOR = timelockConfig.executor;

        if (strategyParameters.ggvTeller == address(0) || strategyParameters.ggvBoringOnChainQueue == address(0)) {
            revert InvalidConfiguration();
        }

        GGV_TELLER = strategyParameters.ggvTeller;
        GGV_BORING_ON_CHAIN_QUEUE = strategyParameters.ggvBoringOnChainQueue;
    }

    function createPoolStvStart(StvPoolConfig memory _config) external payable returns (StvPoolIntermediate memory intermediate) {
        return createPoolStart(PoolFullConfig({
            allowlistEnabled: _config.allowlistEnabled,
            mintingEnabled: false,
            owner: _config.owner,
            nodeOperator: _config.nodeOperator,
            nodeOperatorManager: _config.nodeOperatorManager,
            nodeOperatorFeeBP: _config.nodeOperatorFeeBP,
            confirmExpiry: _config.confirmExpiry,
            maxFinalizationTime: _config.maxFinalizationTime,
            minWithdrawalDelayTime: _config.minWithdrawalDelayTime,
            reserveRatioGapBP: 0
        }), StrategyConfig({factory: address(0)}));
    }

    function createPoolStvStETHStart(StvStETHPoolConfig memory _config) external payable returns (StvPoolIntermediate memory intermediate) {
        return createPoolStart(PoolFullConfig({
            allowlistEnabled: _config.allowlistEnabled,
            mintingEnabled: true,
            owner: _config.owner,
            nodeOperator: _config.nodeOperator,
            nodeOperatorManager: _config.nodeOperatorManager,
            nodeOperatorFeeBP: _config.nodeOperatorFeeBP,
            confirmExpiry: _config.confirmExpiry,
            maxFinalizationTime: _config.maxFinalizationTime,
            minWithdrawalDelayTime: _config.minWithdrawalDelayTime,
            reserveRatioGapBP: _config.reserveRatioGapBP
        }), StrategyConfig({factory: address(0)}));
    }

    function createPoolGGVStart(GGVPoolConfig memory _config) external payable returns (StvPoolIntermediate memory intermediate) {
        return createPoolStart(PoolFullConfig({
            allowlistEnabled: true,
            mintingEnabled: true,
            owner: _config.owner,
            nodeOperator: _config.nodeOperator,
            nodeOperatorManager: _config.nodeOperatorManager,
            nodeOperatorFeeBP: _config.nodeOperatorFeeBP,
            confirmExpiry: _config.confirmExpiry,
            maxFinalizationTime: _config.maxFinalizationTime,
            minWithdrawalDelayTime: _config.minWithdrawalDelayTime,
            reserveRatioGapBP: _config.reserveRatioGapBP
        }), StrategyConfig({factory: address(GGV_STRATEGY_FACTORY)}));
    }

    function createPoolStart(PoolFullConfig memory config, StrategyConfig memory strategyConfig) public payable returns (StvPoolIntermediate memory intermediate) {
        if (msg.value != VAULT_HUB.CONNECT_DEPOSIT()) {
            revert InsufficientConnectDeposit(VAULT_HUB.CONNECT_DEPOSIT(), msg.value);
        }

        PoolType poolType = PoolType.STV;
        string memory name = NAME_STV;
        if (strategyConfig.factory != address(0)) {
            poolType = PoolType.STRATEGY;
            name = NAME_STV_STRATEGY;
        } else if (config.mintingEnabled) {
            poolType = PoolType.STV_STETH;
            name = NAME_STV_STETH;
        }

        if (poolType == PoolType.STRATEGY && !config.allowlistEnabled) {
            revert InvalidConfiguration();
        }
        if (poolType == PoolType.STV_STETH && !config.mintingEnabled) {
            revert InvalidConfiguration();
        }
        // TODO: check if reserveRatioGapBP is valid


        address timelock = TIMELOCK_FACTORY.deploy(TIMELOCK_MIN_DELAY, config.nodeOperator, TIMELOCK_EXECUTOR);
        address tempAdmin = address(this);

        ( , address dashboardAddress) = VAULT_FACTORY.createVaultWithDashboard{value: msg.value}(
            tempAdmin, // TODO
            config.nodeOperator,
            config.nodeOperatorManager,
            config.nodeOperatorFeeBP,
            config.confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        address poolProxy = payable(address(new OssifiableProxy(DUMMY_IMPLEMENTATION, address(this), bytes(""))));

        IDashboard dashboard = IDashboard(payable(dashboardAddress));

        address wqImpl = WITHDRAWAL_QUEUE_FACTORY.deploy(
            poolProxy,
            address(dashboard),
            address(VAULT_HUB),
            STETH,
            address(dashboard.stakingVault()),
            LAZY_ORACLE,
            config.maxFinalizationTime,
            config.minWithdrawalDelayTime
        );

        address wqAdmin = config.owner;
        address wqFinalizeRoleHolder = config.nodeOperator;
        address withdrawalQueueProxy = address(
            new OssifiableProxy(
                wqImpl, timelock, abi.encodeCall(WithdrawalQueue.initialize, (wqAdmin, wqFinalizeRoleHolder))
            )
        );

        Distributor distributor = Distributor(DISTRIBUTOR_FACTORY.deploy(config.nodeOperator, config.nodeOperatorManager));

        address poolImpl = address(0);
        if (poolType == PoolType.STV) {
            poolImpl = STV_POOL_FACTORY.deploy(address(dashboard), config.allowlistEnabled, withdrawalQueueProxy, address(distributor));
        } else if (poolType == PoolType.STV_STETH || poolType == PoolType.STRATEGY) {
            poolImpl = STV_STETH_POOL_FACTORY.deploy(address(dashboard), config.allowlistEnabled, config.reserveRatioGapBP, withdrawalQueueProxy, address(distributor));
        }

        OssifiableProxy(payable(poolProxy)).proxy__upgradeToAndCall(
            poolImpl, abi.encodeCall(StvPool.initialize, (tempAdmin, name, SYMBOL))
        );
        OssifiableProxy(payable(poolProxy)).proxy__changeAdmin(timelock);


        // TODO
        // emit VaultPoolCreated(vault, address(pool.), withdrawalQueueProxy, strategy);

        intermediate = StvPoolIntermediate({
            dashboard: address(dashboard),
            pool: poolProxy,
            timelock: timelock
        });

    }

    function createPoolFinish(StvPoolIntermediate memory intermediate, StrategyConfig memory strategyConfig) external returns (StvPoolDeployment memory deployment) {
        IDashboard dashboard = IDashboard(payable(intermediate.dashboard));
        StvPool pool = StvPool(payable(intermediate.pool));
        address withdrawalQueue = address(pool.WITHDRAWAL_QUEUE());
        address timelock = intermediate.timelock;
        address tempAdmin = address(this);

        dashboard.grantRole(dashboard.FUND_ROLE(), address(pool));
        dashboard.grantRole(dashboard.REBALANCE_ROLE(), address(pool));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), withdrawalQueue);

        if (keccak256(bytes(pool.name())) != keccak256(bytes(NAME_STV))) {
            dashboard.grantRole(dashboard.MINT_ROLE(), address(pool));
            dashboard.grantRole(dashboard.BURN_ROLE(), address(pool));
        }

        address strategy = address(0);

        if (strategyConfig.factory == address(GGV_STRATEGY_FACTORY)) {
            strategy = IStrategyFactory(strategyConfig.factory).deploy(address(pool), STETH, WSTETH, GGV_TELLER, GGV_BORING_ON_CHAIN_QUEUE);
        }

        if (strategy != address(0)) {
            pool.grantRole(pool.ALLOW_LIST_MANAGER_ROLE(), tempAdmin);
            pool.addToAllowList(strategy);
            pool.revokeRole(pool.ALLOW_LIST_MANAGER_ROLE(), tempAdmin);

            // NB: can be shortened to:
            // pool.grantRole(pool.DEPOSIT_ROLE(), strategy); // effectively means
        }

        pool.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        pool.renounceRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        dashboard.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        dashboard.renounceRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        deployment = StvPoolDeployment({
            pool: intermediate.pool,
            withdrawalQueue: withdrawalQueue
        });

        // TODO: LOSS_SOCIALIZER_ROLE
    }

}
