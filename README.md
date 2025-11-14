## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deployment

The Factory orchestrates deployment of the entire pool system (Vault, Dashboard, Pool, Withdrawal Queue, Distributor, Timelock, and optionally a Strategy) via dedicated implementation factories and proxies.

#### Overview: Three Pool Types

The system supports three pool types, each with different capabilities:

| Pool Type | Minting | Strategy | Allowlist | Reserve Ratio Gap | Use Case |
|-----------|---------|----------|-----------|-------------------|----------|
| **StvPool** | ❌ No | ❌ No | Optional | N/A | Basic staking pool |
| **StvStETHPool** | ✅ Yes | ❌ No | Optional | Required | Advanced pool with stETH minting |
| **StvStrategyPool** (GGV) | ✅ Yes | ✅ Yes | ✅ Required | Required | Pool with external strategy integration |

#### Two-Phase Deployment Process

All pool deployments use a two-phase approach for security and gas optimization:

1. **Start Phase** (`createPoolStart`): Deploys core components and emits `PoolCreationStarted` with deployment parameters
2. **Finish Phase** (`createPoolFinish`): Completes initialization, wires roles, and validates deployment integrity

The two-phase design ensures:
- Configuration parameters are cryptographically committed in the start phase
- No parameter tampering between start and finish
- Same sender must complete both phases
- Completion must occur within `DEPLOY_START_FINISH_SPAN_SECONDS` (1 day)

#### Deployment Using Justfile

##### 1. Deploy Factory

```bash
# Deploy factory and all implementation factories for given env
just -E .env.hoodi.local deploy-factory
```

**Underlying contract calls:**
```solidity
// 1. Deploy sub-factories
StvPoolFactory stvPoolFactory = new StvPoolFactory();
StvStETHPoolFactory stvStETHPoolFactory = new StvStETHPoolFactory();
WithdrawalQueueFactory wqFactory = new WithdrawalQueueFactory();
DistributorFactory distributorFactory = new DistributorFactory();
GGVStrategyFactory ggvStrategyFactory = new GGVStrategyFactory(teller, boringQueue);
TimelockFactory timelockFactory = new TimelockFactory();

// 2. Deploy main Factory
Factory factory = new Factory(
    locatorAddress,
    Factory.SubFactories({
        stvPoolFactory: address(stvPoolFactory),
        stvStETHPoolFactory: address(stvStETHPoolFactory),
        withdrawalQueueFactory: address(wqFactory),
        distributorFactory: address(distributorFactory),
        ggvStrategyFactory: address(ggvStrategyFactory),
        timelockFactory: address(timelockFactory)
    })
);
```

**Output:** `deployments/pool-factory-latest.json`

##### 2. Deploy Individual Pools

**Option A: Deploy Single Pool (Two-Phase)**

```bash
# Phase 1: Start deployment
just deploy-pool-start $FACTORY_ADDRESS config/hoodi-stv.json

# Phase 2: Finish deployment (using intermediate JSON from phase 1)
just deploy-pool-finish $FACTORY_ADDRESS deployments/intermediate-<timestamp>.json
```

**Option B: Deploy All Three Pool Types**

```bash
# Deploys all three pool types in sequence
just deploy-all .env.hoodi.local
```

This executes:
1. Factory deployment
2. StvPool deployment (start + finish)
3. StvStETHPool deployment (start + finish)
4. StvStrategyPool with GGV strategy (start + finish)

#### Pool Type Configuration Examples

##### Type 1: Basic StvPool (No Minting, No Strategy)

**Config:** `config/hoodi-stv.json`
```json
{
  "auxiliaryPoolConfig": {
    "allowlistEnabled": false,
    "mintingEnabled": false,      // ← No minting
    "reserveRatioGapBP": 0
  },
  "strategyFactory": "0x0000000000000000000000000000000000000000"  // ← No strategy
}
```

**Deployment calls:**
```solidity
// START PHASE
Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: 1 ether}(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,     // mintingEnabled: false
    timelockConfig,
    address(0),          // strategyFactory: none
    ""                   // strategyDeployBytes: empty
);

// FINISH PHASE
Factory.PoolDeployment memory deployment = factory.createPoolFinish(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,
    timelockConfig,
    address(0),
    "",
    intermediate
);
```

**What gets deployed:**
1. **Vault + Dashboard** (via `VaultFactory.createVaultWithDashboard`)
2. **Timelock** (via `TimelockFactory`)
3. **Pool Proxy** (OssifiableProxy with temp admin)
4. **Withdrawal Queue** (proxy + implementation)
5. **Distributor** (for fee distribution)
6. **StvPool Implementation** (via `StvPoolFactory.deploy`)

**Roles granted:**
- Dashboard: `FUND_ROLE`, `REBALANCE_ROLE` → Pool; `WITHDRAW_ROLE` → Withdrawal Queue
- Pool: `DEFAULT_ADMIN_ROLE` → Timelock
- Withdrawal Queue: `FINALIZE_ROLE` → Node Operator
- Distributor: `MANAGER_ROLE` → Node Operator Manager

##### Type 2: StvStETHPool (With Minting, No Strategy)

**Config:** `config/hoodi-stv-steth.json`
```json
{
  "auxiliaryPoolConfig": {
    "allowlistEnabled": false,
    "mintingEnabled": true,       // ← Minting enabled
    "reserveRatioGapBP": 250      // ← 2.5% gap on top of vault reserve ratio
  },
  "strategyFactory": "0x0000000000000000000000000000000000000000"  // ← No strategy
}
```

**Deployment calls:**
```solidity
// START PHASE  
Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: 1 ether}(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,     // mintingEnabled: true, reserveRatioGapBP: 250
    timelockConfig,
    address(0),          // strategyFactory: none
    ""
);

// FINISH PHASE
Factory.PoolDeployment memory deployment = factory.createPoolFinish(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,
    timelockConfig,
    address(0),
    "",
    intermediate
);
```

**What gets deployed:**
1-5. Same as StvPool
6. **StvStETHPool Implementation** (via `StvStETHPoolFactory.deploy`)

**Additional roles (vs Type 1):**
- Dashboard: `MINT_ROLE`, `BURN_ROLE` → Pool (for stETH minting/burning)

**Key difference:** Pool can mint/burn stETH shares for advanced liquidity management

##### Type 3: StvStrategyPool with GGV (With Minting + Strategy)

**Config:** `config/hoodi-stv-ggv.json`
```json
{
  "auxiliaryPoolConfig": {
    "allowlistEnabled": true,     // ← Allowlist required for strategy
    "mintingEnabled": true,       // ← Minting required for strategy
    "reserveRatioGapBP": 250
  },
  "strategyFactory": "0x3a2E87c2aC5f34F48a832Ed0205c2630B951e1F6"  // ← GGV strategy factory
}
```

**Deployment calls:**
```solidity
// START PHASE
Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: 1 ether}(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,     // mintingEnabled: true, allowlistEnabled: true
    timelockConfig,
    ggvStrategyFactory,  // ← GGV strategy factory address
    ""                   // strategyDeployBytes (empty for GGV)
);

// FINISH PHASE  
Factory.PoolDeployment memory deployment = factory.createPoolFinish(
    vaultConfig,
    commonPoolConfig,
    auxiliaryConfig,
    timelockConfig,
    ggvStrategyFactory,
    "",
    intermediate
);
```

**What gets deployed:**
1-5. Same as StvStETHPool
6. **GGV Strategy Implementation** (via `GGVStrategyFactory.deploy`)
7. **Strategy Proxy** (OssifiableProxy wrapping strategy implementation)
8. **StvStETHPool Implementation** (via `StvStETHPoolFactory.deploy`)

**Additional setup (vs Type 2):**
- Strategy proxy initialized with timelock as admin
- Strategy address added to pool's allowlist
- Pool can only accept deposits from allowlisted addresses (including the strategy)

**Key difference:** Pool integrates with external GGV strategy for yield optimization

#### Underlying Factory Contract Calls (Detailed)

##### Prerequisites

Addresses required to deploy `Factory`:
- **Core (auto-discovered from Locator)**: `IVaultFactory`, `IVaultHub`, `stETH`, `wstETH`, `lazyOracle`
- **Implementation factories**: `StvPoolFactory`, `StvStETHPoolFactory`, `WithdrawalQueueFactory`, `DistributorFactory`, `GGVStrategyFactory`, `TimelockFactory`
- **Proxy stub**: `DummyImplementation` (for `OssifiableProxy` bootstrap, deployed during Factory construction)

##### Factory Constructor

```solidity
new Factory(locatorAddress, SubFactories({
    stvPoolFactory: address(stvPoolFactory),
    stvStETHPoolFactory: address(stvStETHPoolFactory),
    withdrawalQueueFactory: address(wqFactory),
    distributorFactory: address(distributorFactory),
    ggvStrategyFactory: address(ggvStrategyFactory),
    timelockFactory: address(timelockFactory)
}))
```

##### Reusing Existing Deployment

Export `FACTORY_ADDRESS` (alongside `CORE_LOCATOR_ADDRESS`) before running scripts or integration tests. When set, the harness logs `Using predeployed factory from FACTORY_ADDRESS ...` and skips deploying a fresh `Factory` instance.

##### Pool Deployment Entry Points

The Factory provides three specialized start functions and one generic start function:

1. **`createPoolStvStart`** - Basic StvPool (no minting, no strategy)
   ```solidity
   function createPoolStvStart(
       VaultConfig memory _vaultConfig,
       TimelockConfig memory _timelockConfig,
       CommonPoolConfig memory _commonPoolConfig,
       bool _allowListEnabled
   ) external returns (PoolIntermediate memory)
   ```

2. **`createPoolStvStETHStart`** - StvStETHPool (with minting, no strategy)
   ```solidity
   function createPoolStvStETHStart(
       VaultConfig memory _vaultConfig,
       TimelockConfig memory _timelockConfig,
       CommonPoolConfig memory _commonPoolConfig,
       bool _allowListEnabled,
       uint256 _reserveRatioGapBP
   ) external returns (PoolIntermediate memory)
   ```

3. **`createPoolGGVStart`** - StvStrategyPool with GGV (minting + strategy, allowlist auto-enabled)
   ```solidity
   function createPoolGGVStart(
       VaultConfig memory _vaultConfig,
       TimelockConfig memory _timelockConfig,
       CommonPoolConfig memory _commonPoolConfig,
       uint256 _reserveRatioGapBP
   ) external returns (PoolIntermediate memory)
   ```

4. **`createPoolStart`** - Generic pool deployment (called by all specialized functions)
   ```solidity
   function createPoolStart(
       VaultConfig memory _vaultConfig,
       TimelockConfig memory _timelockConfig,
       CommonPoolConfig memory _commonPoolConfig,
       AuxiliaryPoolConfig memory _auxiliaryConfig,
       address _strategyFactory,
       bytes memory _strategyDeployBytes
   ) public returns (PoolIntermediate memory)
   ```

All pools are finalized using the same function:

5. **`createPoolFinish`** - Completes deployment (requires `msg.value >= VAULT_HUB.CONNECT_DEPOSIT()`)
   ```solidity
   function createPoolFinish(
       VaultConfig memory _vaultConfig,
       TimelockConfig memory _timelockConfig,
       CommonPoolConfig memory _commonPoolConfig,
       AuxiliaryPoolConfig memory _auxiliaryConfig,
       address _strategyFactory,
       bytes memory _strategyDeployBytes,
       PoolIntermediate calldata _intermediate
   ) external payable returns (PoolDeployment memory)
   ```

##### Configuration Structures

```solidity
struct VaultConfig {
    address nodeOperator;           // Vault node operator
    address nodeOperatorManager;    // Manager for node operator settings
    uint256 nodeOperatorFeeBP;      // Fee in basis points
    uint256 confirmExpiry;          // Confirmation expiry time
}

struct TimelockConfig {
    uint256 minDelaySeconds;        // Minimum delay for timelock operations
    address proposer;               // Address authorized to propose
    address executor;               // Address authorized to execute
}

struct CommonPoolConfig {
    uint256 minWithdrawalDelayTime; // Minimum withdrawal delay
    string name;                    // ERC20 token name
    string symbol;                  // ERC20 token symbol
    address emergencyCommittee;     // Emergency pause authority
}

struct AuxiliaryPoolConfig {
    bool allowlistEnabled;          // Require allowlist for deposits
    bool mintingEnabled;            // Enable stETH minting
    uint256 reserveRatioGapBP;      // Reserve ratio gap (basis points)
}

struct PoolIntermediate {
    address dashboard;              // Deployed dashboard address
    address poolProxy;              // Pool proxy (uninitialized)
    address poolImpl;               // Pool implementation
    address withdrawalQueueProxy;   // WQ proxy (uninitialized)
    address wqImpl;                 // WQ implementation
    address timelock;               // Timelock controller
}
```

##### Start Phase: What Gets Deployed

The `createPoolStart` function deploys the following components:

1. **Timelock Controller**
   - Via: `TimelockFactory.deploy(minDelaySeconds, proposer, executor)`
   - Admin for all system components

2. **Pool Proxy** (uninitialized)
   - Via: `new OssifiableProxy(DUMMY_IMPLEMENTATION, address(this), "")`
   - Temporary admin: Factory contract

3. **Withdrawal Queue Proxy** (uninitialized)
   - Via: `new OssifiableProxy(DUMMY_IMPLEMENTATION, address(this), "")`
   - Temporary admin: Factory contract

4. **Vault + Dashboard**
   - Via: `VAULT_FACTORY.createVaultWithDashboardWithoutConnectingToVaultHub(...)`
   - Note: Does NOT connect to VaultHub yet (no ETH required)
   - Temporary admin: Factory contract

5. **Withdrawal Queue Implementation**
   - Via: `WITHDRAWAL_QUEUE_FACTORY.deploy(poolProxy, dashboard, vaultHub, stETH, vault, lazyOracle, minWithdrawalDelayTime, mintingEnabled)`

6. **Distributor**
   - Via: `DISTRIBUTOR_FACTORY.deploy(timelock, nodeOperatorManager)`

7. **Pool Implementation** (type determined by `derivePoolType`)
   - Type A (StvPool): `STV_POOL_FACTORY.deploy(dashboard, allowlistEnabled, wqProxy, distributor, poolType)`
   - Type B/C (StvStETHPool): `STV_STETH_POOL_FACTORY.deploy(dashboard, allowlistEnabled, reserveRatioGapBP, wqProxy, distributor, poolType)`

8. **Deployment Hash Storage**
   - Computes: `keccak256(abi.encode(sender, vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, strategyDeployBytes, intermediate))`
   - Stores: `intermediateState[hash] = block.timestamp + DEPLOY_START_FINISH_SPAN_SECONDS`

9. **Event Emission**
   - Emits: `PoolCreationStarted` with all parameters and finish deadline

##### Finish Phase: Initialization and Role Wiring

The `createPoolFinish` function completes deployment:

1. **Validates Deployment State**
   - Recomputes deployment hash from all parameters
   - Checks: hash exists, not already finished, deadline not passed
   - Marks: `intermediateState[hash] = DEPLOY_FINISHED`

2. **Connects to VaultHub**
   - Via: `dashboard.connectToVaultHub{value: msg.value}()`
   - Requires: `msg.value >= VAULT_HUB.CONNECT_DEPOSIT()`

3. **Initializes Pool Proxy**
   - Upgrades to implementation: `proxy__upgradeToAndCall(poolImpl, abi.encodeCall(StvPool.initialize, (address(this), name, symbol)))`
   - Changes admin to timelock: `proxy__changeAdmin(timelock)`

4. **Initializes Withdrawal Queue Proxy**
   - Upgrades to implementation: `proxy__upgradeToAndCall(wqImpl, abi.encodeCall(WithdrawalQueue.initialize, (timelock, nodeOperator, emergencyCommittee, emergencyCommittee)))`
   - Changes admin to timelock: `proxy__changeAdmin(timelock)`

5. **Deploys Strategy** (if `_strategyFactory != address(0)`)
   - Implementation: `IStrategyFactory(_strategyFactory).deploy(address(pool), _strategyDeployBytes)`
   - Proxy: `new OssifiableProxy(strategyImpl, timelock, abi.encodeCall(IStrategy.initialize, (timelock, emergencyCommittee)))`
   - Adds strategy to pool allowlist: `pool.addToAllowList(strategyProxy)`

6. **Grants Emergency Committee Roles** (if `emergencyCommittee != address(0)`)
   - Pool: `DEPOSITS_PAUSE_ROLE` → emergencyCommittee
   - Pool (if minting): `MINTING_PAUSE_ROLE` → emergencyCommittee
   - Dashboard: `PAUSE_BEACON_CHAIN_DEPOSITS_ROLE` → emergencyCommittee

7. **Grants Pool Roles**
   - Pool: `DEFAULT_ADMIN_ROLE` → timelock
   - Pool: revoke `DEFAULT_ADMIN_ROLE` from Factory

8. **Grants Dashboard Roles**
   - Dashboard: `FUND_ROLE` → pool
   - Dashboard: `REBALANCE_ROLE` → pool
   - Dashboard: `WITHDRAW_ROLE` → withdrawalQueue
   - Dashboard (if minting): `MINT_ROLE` → pool
   - Dashboard (if minting): `BURN_ROLE` → pool
   - Dashboard: `DEFAULT_ADMIN_ROLE` → timelock
   - Dashboard: revoke `DEFAULT_ADMIN_ROLE` from Factory

9. **Event Emission**
   - Emits: `PoolCreated(vault, pool, poolType, withdrawalQueue, strategyFactory, strategyDeployBytes, strategy)`

##### Note on Circular Dependencies and Gas Optimization

- **Pool ↔ Withdrawal Queue** and **StvStETHPool ↔ Strategy** have circular dependencies.
- Solution: Pre-deploy proxies with `DummyImplementation`, then deploy implementations with concrete addresses:
  1. Deploy pool proxy → get address
  2. Deploy WQ implementation with pool proxy address
  3. Deploy pool implementation with WQ proxy address
  4. Upgrade proxies to real implementations
- All component addresses are stored as `immutable` variables (e.g., `StvPool.WITHDRAWAL_QUEUE`, `StvStETHPool.DISTRIBUTOR`) to save gas on regular transactions.

##### Dedicated Factories for Bytecode Size

Separate factories (`StvPoolFactory`, `StvStETHPoolFactory`, `WithdrawalQueueFactory`, `DistributorFactory`, `GGVStrategyFactory`, `TimelockFactory`) are required to keep the main Factory contract within the 24KB bytecode limit.

Local deployment (quickstart)

- Files/scripts:
  - `lido-core/deployed-local.json` (written by `make core-deploy`; use it to extract the Locator address)
  - `script/HarnessCore.s.sol` + `script/harness-core.sh` (prepares core via impersonation: sets epoch, resumes Lido, submits initial ETH)
  - `script/DeployWrapperFactory.s.sol` (deploys Factory + implementation factories; writes `deployments/pool-<chainId>.json`)
  - `script/DeployWrapper.s.sol` (deploys a pool instance from the Factory using your pool config JSON)
  - `foundry.toml` (`fs_permissions` allow writing to `deployments/`)
- Procedure:
  - Start RPC (e.g., Anvil or Hardhat at `http://localhost:9123`).
  - `make core-deploy` (deploys core and writes `lido-core/deployed-local.json`).
  - Export `CORE_LOCATOR_ADDRESS` from the deployed core JSON:
    ```bash
    export CORE_LOCATOR_ADDRESS=$(jq -r '.lidoLocator.proxy.address' lido-core/deployed-local.json)
    export RPC_URL=http://localhost:9123
    ```
  - Prepare core (optional best-effort):
    ```bash
    INITIAL_LIDO_SUBMISSION=20000000000000000000000 \
    CORE_LOCATOR_ADDRESS="$CORE_LOCATOR_ADDRESS" \
    RPC_URL="$RPC_URL" \
    bash script/harness-core.sh
    ```
  - Deploy Factory via Foundry script (the script auto-writes to `deployments/pool-factory-<chainId>-<timestamp>.json`):
    ```bash
    CORE_LOCATOR_ADDRESS="$CORE_LOCATOR_ADDRESS" \
    FACTORY_PARAMS_JSON=script/factory-deploy-config.json \
    forge script script/DeployWrapperFactory.s.sol:DeployWrapperFactory \
      --rpc-url "$RPC_URL" \
      --broadcast -vvv
    ```
    The script also updates a stable pointer:
    - `deployments/pool-factory-latest.json`
  - Deploy a pool instance (example; adjust config):
    ```bash
    forge script script/DeployWrapper.s.sol:DeployWrapper \
      --rpc-url "$RPC_URL" \
      --broadcast -vvv
    ```
  - Artifacts:
    - `deployments/pool-<chainId>.json`: deployed `Factory` and implementation factory addresses
    - `deployments/pool-instance.json`: deployed Vault, Dashboard, Wrapper proxy, Withdrawal Queue, and Strategy (if applicable)

- Quick verification using the test harness:
  ```bash
  FACTORY_ADDRESS=<existing_factory> \
  CORE_LOCATOR_ADDRESS=<core_locator> \
  RPC_URL=http://localhost:9123 \
  make -s test-integration
  ```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
