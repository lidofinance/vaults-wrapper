// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Distributor} from "./Distributor.sol";
import {StvPool} from "./StvPool.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {DistributorFactory} from "./factories/DistributorFactory.sol";
import {GGVStrategyFactory} from "./factories/GGVStrategyFactory.sol";
import {StvPoolFactory} from "./factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "./factories/StvStETHPoolFactory.sol";
import {TimelockFactory} from "./factories/TimelockFactory.sol";
import {WithdrawalQueueFactory} from "./factories/WithdrawalQueueFactory.sol";
import {IStrategyFactory} from "./interfaces/IStrategyFactory.sol";
import {ILidoLocator} from "./interfaces/core/ILidoLocator.sol";
import {IVaultHub} from "./interfaces/core/IVaultHub.sol";
import {DummyImplementation} from "./proxy/DummyImplementation.sol";
import {OssifiableProxy} from "./proxy/OssifiableProxy.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {IDashboard} from "./interfaces/core/IDashboard.sol";
import {IVaultFactory} from "./interfaces/core/IVaultFactory.sol";

/// @title Factory
/// @notice Main factory contract for deploying complete pool ecosystems with vaults, withdrawal queues, distributors, etc
/// @dev Implements a two-phase deployment process (start/finish) to ensure robust setup of all components and roles
contract Factory {
    //
    // Structs
    //

    /// @notice Addresses of all sub-factory contracts used for deploying components
    /// @param stvPoolFactory Factory for deploying StvPool implementations
    /// @param stvStETHPoolFactory Factory for deploying StvStETHPool implementations
    /// @param withdrawalQueueFactory Factory for deploying WithdrawalQueue implementations
    /// @param distributorFactory Factory for deploying Distributor implementations
    /// @param ggvStrategyFactory Factory for deploying GGV strategy implementations
    /// @param timelockFactory Factory for deploying Timelock controllers
    struct SubFactories {
        address stvPoolFactory;
        address stvStETHPoolFactory;
        address withdrawalQueueFactory;
        address distributorFactory;
        address ggvStrategyFactory;
        address timelockFactory;
    }

    /// @notice Configuration parameters for vault creation
    /// @param nodeOperator Address of the node operator managing the vault
    /// @param nodeOperatorManager Address authorized to manage node operator settings
    /// @param nodeOperatorFeeBP Node operator fee in basis points (1 BP = 0.01%)
    /// @param confirmExpiry Time period for confirmation expiry
    struct VaultConfig {
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
    }

    /// @notice Configuration for timelock controller deployment
    /// @param minDelaySeconds Minimum delay before executing queued operations
    /// @param proposer Address authorized to propose operations
    /// @param executor Address authorized to execute operations
    struct TimelockConfig {
        uint256 minDelaySeconds;
        address proposer;
        address executor;
    }

    /// @notice Common configuration shared across all pool types
    /// @param minWithdrawalDelayTime Minimum delay time for processing withdrawals
    /// @param name ERC20 token name for the pool shares
    /// @param symbol ERC20 token symbol for the pool shares
    struct CommonPoolConfig {
        uint256 minWithdrawalDelayTime;
        string name;
        string symbol;
    }

    /// @notice Configuration specific to StvStETH pools (deprecated, kept for compatibility)
    /// @param allowlistEnabled Whether the pool requires allowlist for deposits
    /// @param reserveRatioGapBP Maximum allowed gap in reserve ratio in basis points
    struct StvStETHPoolConfig {
        bool allowlistEnabled;
        uint256 reserveRatioGapBP;
    }

    /// @notice Extended configuration for pools with minting or strategy capabilities
    /// @param allowlistEnabled Whether the pool requires allowlist for deposits
    /// @param mintingEnabled Whether the pool can mint stETH tokens
    /// @param reserveRatioGapBP Maximum allowed gap in reserve ratio in basis points
    struct AuxiliaryPoolConfig {
        bool allowlistEnabled;
        bool mintingEnabled;
        uint256 reserveRatioGapBP;
    }

    /// @notice Intermediate state returned by deployment start functions
    /// @param pool Address of the deployed pool proxy
    /// @param timelock Address of the deployed timelock controller
    /// @param strategyFactory Address of the strategy factory (zero if not using strategies)
    /// @param strategyDeployBytes ABI-encoded parameters for strategy deployment
    struct PoolIntermediate {
        address pool;
        address timelock;
        address strategyFactory;
        bytes strategyDeployBytes;
    }

    /// @notice Complete deployment result returned by finish function
    /// @param poolType Type identifier for the pool (StvPool, StvStETHPool, or StvStrategyPool)
    /// @param vault Address of the deployed vault
    /// @param dashboard Address of the deployed dashboard
    /// @param pool Address of the deployed pool
    /// @param withdrawalQueue Address of the deployed withdrawal queue
    /// @param distributor Address of the deployed distributor
    /// @param timelock Address of the deployed timelock controller
    /// @param strategy Address of the deployed strategy (zero if not using strategies)
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

    //
    // Events
    //

    /// @notice Emitted when pool deployment is initiated in the start phase
    /// @param intermediate Contains addresses of deployed components needed for finish phase
    /// @param finishDeadline Timestamp by which createPoolFinish must be called (inclusive)
    event PoolCreationStarted(PoolIntermediate intermediate, uint256 finishDeadline);

    /// @notice Emitted when pool deployment is completed in the finish phase
    /// @param vault Address of the deployed vault
    /// @param pool Address of the deployed pool
    /// @param poolType Type identifier for the pool
    /// @param withdrawalQueue Address of the deployed withdrawal queue
    /// @param strategyFactory Address of the strategy factory used (zero if none)
    /// @param strategyDeployBytes ABI-encoded parameters used for strategy deployment
    /// @param strategy Address of the deployed strategy (zero if not using strategies)
    event PoolCreated(
        address vault,
        address pool,
        bytes32 indexed poolType,
        address withdrawalQueue,
        address indexed strategyFactory,
        bytes strategyDeployBytes,
        address strategy
    );

    //
    // Custom errors
    //

    /// @notice Thrown when configuration parameters are invalid or inconsistent
    /// @param reason Human-readable description of the configuration error
    error InvalidConfiguration(string reason);

    /// @notice Thrown when insufficient ETH is sent for the vault connection deposit
    /// @param provided Amount of ETH provided in msg.value
    /// @param required Required amount for VAULT_HUB.CONNECT_DEPOSIT()
    error InsufficientConnectDeposit(uint256 provided, uint256 required);

    /// @notice Thrown when a string exceeds the maximum length for encoding to bytes32
    /// @param str The string that is too long
    error StringTooLong(string str);

    //
    // Constants and immutables
    //

    /// @notice Lido vault factory for creating vaults and dashboards
    IVaultFactory public immutable VAULT_FACTORY;

    /// @notice Lido V3 VaultHub (cached from LidoLocator for gas cost reduction)
    IVaultHub public immutable VAULT_HUB;

    /// @notice Lido stETH token address (cached from LidoLocator for gas cost reduction)
    address public immutable STETH;

    /// @notice Lido wstETH token address (cached from LidoLocator for gas cost reduction)
    address public immutable WSTETH;

    /// @notice Lido V3 LazyOracle (cached from LidoLocator for gas cost reduction)
    address public immutable LAZY_ORACLE;

    /// @notice Pool type identifier for basic StvPool
    bytes32 public immutable STV_POOL_TYPE;

    /// @notice Pool type identifier for StvStETHPool with minting capabilities
    bytes32 public immutable STV_STETH_POOL_TYPE;

    /// @notice Pool type identifier for StvStrategyPool with strategy integration
    bytes32 public immutable STRATEGY_POOL_TYPE;

    /// @notice Factory for deploying StvPool implementations
    StvPoolFactory public immutable STV_POOL_FACTORY;

    /// @notice Factory for deploying StvStETHPool implementations
    StvStETHPoolFactory public immutable STV_STETH_POOL_FACTORY;

    /// @notice Factory for deploying WithdrawalQueue implementations
    WithdrawalQueueFactory public immutable WITHDRAWAL_QUEUE_FACTORY;

    /// @notice Factory for deploying Distributor implementations
    DistributorFactory public immutable DISTRIBUTOR_FACTORY;

    /// @notice Factory for deploying GGV strategy implementations
    GGVStrategyFactory public immutable GGV_STRATEGY_FACTORY;

    /// @notice Factory for deploying Timelock controllers
    TimelockFactory public immutable TIMELOCK_FACTORY;

    /// @notice Dummy implementation used for temporary proxy initialization
    address public immutable DUMMY_IMPLEMENTATION;

    /// @notice Default admin role identifier (keccak256("") = 0x00)
    bytes32 public immutable DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Total basis points constant (100.00%)
    uint256 public constant TOTAL_BASIS_POINTS = 100_00;

    /// @notice Maximum time allowed between start and finish deployment phases
    uint256 public constant DEPLOY_START_FINISH_SPAN_SECONDS = 1 days;

    /// @notice Sentinel value marking a deployment as complete
    uint256 public constant DEPLOY_FINISHED = type(uint256).max;

    //
    // Structured storage
    //

    /// @notice Tracks deployment state by hash of intermediate state and sender
    /// @dev Maps deployment hash to finish deadline (0 = not started, DEPLOY_FINISHED = finished)
    mapping(bytes32 => uint256) public intermediateState;

    /// @notice Initializes the factory with Lido locator and sub-factory addresses
    /// @param _locatorAddress Address of the Lido locator contract containing core protocol addresses
    /// @param _subFactories Struct containing addresses of all required sub-factory contracts
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

    /// @notice Initiates deployment of a basic StvPool (first phase)
    /// @param _vaultConfig Configuration for the vault
    /// @param _timelockConfig Configuration for the timelock controller
    /// @param _commonPoolConfig Common pool parameters (name, symbol, withdrawal delay)
    /// @param _allowListEnabled Whether to enable allowlist for deposits
    /// @return intermediate Deployment state needed for finish phase
    /// @dev Requires msg.value >= VAULT_HUB.CONNECT_DEPOSIT() for vault connection
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

    /// @notice Initiates deployment of an StvStETHPool with minting capabilities (first phase)
    /// @param _vaultConfig Configuration for the vault
    /// @param _timelockConfig Configuration for the timelock controller
    /// @param _commonPoolConfig Common pool parameters (name, symbol, withdrawal delay)
    /// @param _allowListEnabled Whether to enable allowlist for deposits
    /// @param _reserveRatioGapBP Maximum allowed reserve ratio gap in basis points
    /// @return intermediate Deployment state needed for finish phase
    /// @dev Requires msg.value >= VAULT_HUB.CONNECT_DEPOSIT() for vault connection
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

    /// @notice Initiates deployment of a GGV strategy pool (first phase)
    /// @param _vaultConfig Configuration for the vault
    /// @param _timelockConfig Configuration for the timelock controller
    /// @param _commonPoolConfig Common pool parameters (name, symbol, withdrawal delay)
    /// @param _reserveRatioGapBP Maximum allowed reserve ratio gap in basis points
    /// @return intermediate Deployment state needed for finish phase
    /// @dev Requires msg.value >= VAULT_HUB.CONNECT_DEPOSIT() for vault connection
    /// @dev Automatically enables allowlist and minting for GGV pools
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

    /// @notice Generic pool deployment start function (first phase)
    /// @param _vaultConfig Configuration for the vault
    /// @param _commonPoolConfig Common pool parameters (name, symbol, withdrawal delay)
    /// @param _auxiliaryConfig Additional pool configuration (allowlist, minting, reserve ratio)
    /// @param _timelockConfig Configuration for the timelock controller
    /// @param _strategyFactory Address of strategy factory (zero for pools without strategy)
    /// @param _strategyDeployBytes ABI-encoded parameters for strategy deployment
    /// @return intermediate Deployment state needed for finish phase
    /// @dev This is the main deployment function called by all pool-specific start functions
    /// @dev Validates configuration, deploys components, and records deployment state
    /// @dev Requires msg.value >= VAULT_HUB.CONNECT_DEPOSIT() for vault connection
    /// @dev Must be followed by createPoolFinish within DEPLOY_START_FINISH_SPAN_SECONDS
    function createPoolStart(
        VaultConfig memory _vaultConfig,
        CommonPoolConfig memory _commonPoolConfig,
        AuxiliaryPoolConfig memory _auxiliaryConfig,
        TimelockConfig memory _timelockConfig,
        address _strategyFactory,
        bytes memory _strategyDeployBytes
    ) public payable returns (PoolIntermediate memory intermediate) {
        if (msg.value < VAULT_HUB.CONNECT_DEPOSIT()) {
            revert InsufficientConnectDeposit(msg.value, VAULT_HUB.CONNECT_DEPOSIT());
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

        address timelock = TIMELOCK_FACTORY.deploy(
            _timelockConfig.minDelaySeconds, _timelockConfig.proposer, _timelockConfig.executor
        );

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

        address distributor = DISTRIBUTOR_FACTORY.deploy(timelock, _vaultConfig.nodeOperatorManager);

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

        emit PoolCreationStarted(intermediate, finishDeadline);
    }

    /// @notice Completes pool deployment (second phase)
    /// @param _intermediate Deployment state returned by createPoolStart
    /// @return deployment Complete deployment information with all component addresses
    /// @dev Must be called by the same address that called createPoolStart
    /// @dev Must be called within DEPLOY_START_FINISH_SPAN_SECONDS of start
    function createPoolFinish(PoolIntermediate calldata _intermediate)
        external
        returns (PoolDeployment memory deployment)
    {
        bytes32 deploymentHash = _hashIntermediate(_intermediate, msg.sender);
        uint256 finishDeadline = intermediateState[deploymentHash];
        if (finishDeadline == 0) {
            revert InvalidConfiguration("deploy not started");
        } else if (finishDeadline == DEPLOY_FINISHED) {
            revert InvalidConfiguration("deploy already finished");
        }
        if (block.timestamp > finishDeadline) {
            revert InvalidConfiguration("deploy finish deadline passed");
        }
        intermediateState[deploymentHash] = DEPLOY_FINISHED;

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
            strategy = IStrategyFactory(_intermediate.strategyFactory)
                .deploy(address(pool), _intermediate.strategyDeployBytes);
            pool.addToAllowList(strategy);
        }

        pool.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        pool.revokeRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        dashboard.grantRole(DEFAULT_ADMIN_ROLE, timelock);
        dashboard.revokeRole(DEFAULT_ADMIN_ROLE, tempAdmin);

        deployment = PoolDeployment({
            poolType: poolType,
            vault: address(pool.VAULT()),
            dashboard: address(dashboard),
            pool: _intermediate.pool,
            withdrawalQueue: address(withdrawalQueue),
            distributor: address(pool.DISTRIBUTOR()),
            timelock: _intermediate.timelock,
            strategy: strategy
        });

        emit PoolCreated(
            deployment.vault,
            deployment.pool,
            deployment.poolType,
            deployment.withdrawalQueue,
            _intermediate.strategyFactory,
            _intermediate.strategyDeployBytes,
            deployment.strategy
        );

        // NB: The roles are not granted on purpose:
        // - LOSS_SOCIALIZER_ROLE (timelock can grant it itself)
    }

    /// @notice Computes a unique hash for tracking deployment state
    /// @param _intermediate The intermediate deployment state
    /// @param _sender Address that initiated the deployment
    /// @return result Keccak256 hash of the sender and intermediate state
    function _hashIntermediate(PoolIntermediate memory _intermediate, address _sender)
        public
        pure
        returns (bytes32 result)
    {
        result = keccak256(abi.encode(_sender, abi.encode(_intermediate)));
    }

    /// @notice Encodes a string into bytes32 format for storage efficiency
    /// @param _str The string to encode (must be 31 bytes or less)
    /// @return Encoded bytes32 value with length encoded in the least significant byte
    /// @dev Reverts with StringTooLong if the string length exceeds 31 bytes
    function _toBytes32(string memory _str) internal pure returns (bytes32) {
        bytes memory bstr = bytes(_str);
        if (bstr.length > 31) {
            revert StringTooLong(_str);
        }
        return bytes32(uint256(bytes32(bstr)) | bstr.length);
    }
}
