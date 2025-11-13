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

- Prerequisites (addresses required to deploy `Factory`):
  - **Core (auto-discovered from Locator)**: `IVaultFactory`, `stETH`, `wstETH`, `lazyOracle`
  - **Implementation factories**: `StvPoolFactory`, `StvStETHPoolFactory`, `StvStETHPoolFactory`, `WithdrawalQueueFactory`, `LoopStrategyFactory`, `GGVStrategyFactory`
  - **Proxy stub**: `DummyImplementation` (for `OssifiableProxy` bootstrap)

- Reusing an existing deployment: export `FACTORY_ADDRESS` (alongside `CORE_LOCATOR_ADDRESS`) before running scripts or integration tests. When the variable is set, the harness logs `Using predeployed factory from FACTORY_ADDRESS ...` and skips deploying a fresh `Factory` instance.

- Deploy `Factory` (either deploy the factories yourself or use `script/DeployFactory.s.sol`):
  - `DeployFactory` requires `CORE_LOCATOR_ADDRESS` and `FACTORY_PARAMS_JSON`; it derives all core addresses from the Locator and wires the `GGVStrategyFactory` inputs.
- Constructor shape for reference: `new Factory(locator, SubFactories{ ... })`

- Create a complete pool system using one of the specialized entrypoints (send `msg.value == VaultHub.CONNECT_DEPOSIT`):
  - `createVaultWithNoMintingNoStrategy(nodeOperator, nodeOperatorManager, nodeOperatorFeeBP, confirmExpiry, allowlistEnabled)`
  - `createVaultWithMintingNoStrategy(nodeOperator, nodeOperatorManager, nodeOperatorFeeBP, confirmExpiry, allowlistEnabled, reserveRatioGapBP)`
  - `createVaultWithLoopStrategy(nodeOperator, nodeOperatorManager, nodeOperatorFeeBP, confirmExpiry, allowlistEnabled, reserveRatioGapBP, loops)`
  - `createVaultWithGGVStrategy(nodeOperator, nodeOperatorManager, nodeOperatorFeeBP, confirmExpiry, allowlistEnabled, reserveRatioGapBP, teller, boringQueue)`

What gets deployed and by whom

1) Vault + Dashboard
- By: `Factory` via `IVaultFactory.createVaultWithDashboard{value: msg.value}()`
- Config: `nodeOperator`, `nodeOperatorManager`, `nodeOperatorFeeBP`, `confirmExpiry`

2) Wrapper proxy and Withdrawal Queue proxy
- By: `Factory`
- Wrapper proxy: `new OssifiableProxy(DummyImplementation, Factory, "")`
- Withdrawal Queue: impl via `WithdrawalQueueFactory.deploy(poolProxy, MAX_FINALIZATION_TIME)`, proxied and initialized with `initialize(nodeOperator, nodeOperator)`

3) Wrapper implementation (selected by configuration)
- By: `Factory` using the implementation factory
  - A: `StvPoolFactory.deploy(dashboard, allowlistEnabled, withdrawalQueue)`
  - B: `StvStETHPoolFactory.deploy(dashboard, stETH, allowlistEnabled, reserveRatioGapBP, withdrawalQueue)`
  - C (strategy): `StvStETHPoolFactory.deploy(dashboard, stETH, allowlistEnabled, strategy, reserveRatioGapBP, withdrawalQueue)`

4) Strategy (only for C)
- Loop: `LoopStrategyFactory.deploy(stETH, poolProxy, loops)` (pool address required)
- GGV: `GGVStrategyFactory.deploy(stETH, teller, boringQueue)`

5) Initialize pool proxy and wire roles
- Proxy upgrade + init: `proxy__upgradeToAndCall(poolImpl, abi.encodeCall(StvPool.initialize, (Factory, NAME, SYMBOL)))`
- Dashboard roles: grant `FUND_ROLE` to pool, `WITHDRAW_ROLE` to withdrawal queue; for B/C also grant `MINT_ROLE` and `BURN_ROLE`
- Admin handover: transfer `DEFAULT_ADMIN_ROLE` on pool and dashboard from `Factory` to `msg.sender`
- Event: `VaultWrapperCreated(vault, pool, withdrawalQueue, strategy, configuration)`

Configuration summary

- Common: `nodeOperator`, `nodeOperatorManager`, `nodeOperatorFeeBP`, `confirmExpiry`, `allowlistEnabled`
- B/C only: `reserveRatioGapBP` (extra reserve ratio on top of vault RR)
- Loop strategy: `loops` (leverage cycles); strategy address is auto-deployed and passed to `StvStETHPool`
- GGV strategy: `teller`, `boringQueue`
- Funding: `msg.value` must equal `VaultHub.CONNECT_DEPOSIT`

Note on circular dependencies and gas savings

- Wrapper ↔ Withdrawal Queue and StvStETHPool ↔ Strategy have apparent circular dependencies (each needs the other's address).
- This is solved by pre-deploying proxies first:
  - Deploy pool proxy upfront (with `DummyImplementation`), obtain its address
  - Deploy Withdrawal Queue implementation passing the pool proxy address; then proxy + initialize
  - For Loop strategy, deploy the strategy with the pool proxy address
  - Finally, deploy pool implementation with concrete dependencies (WQ, strategy) and upgrade the pool proxy to it
- Because the definitive addresses are known at constructor-time for implementations, contracts store them as `immutable` (e.g., `StvPool` references, `StvStETHPool.STRATEGY`, strategy's `WRAPPER`). This reduces storage reads and saves gas on regular transactions.

Dedicated factories for wrappers, withdrawal queue and strategies are required to keep Factory contract bytecode size withing the limit.

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
