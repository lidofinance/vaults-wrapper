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

The Factory orchestrates deployment of the entire pool system (Vault, Dashboard, Wrapper, Withdrawal Queue, and optionally a Strategy) via dedicated implementation factories and proxies.

- Prerequisites (addresses required to deploy `Factory`):
  - **Core**: `IVaultFactory` (Lido `VaultFactory`), `stETH` token address
  - **Implementation factories**: `StvPoolFactory`, `StvStETHPoolFactory`, `StvStrategyPoolFactory`, `WithdrawalQueueFactory`, `LoopStrategyFactory`, `GGVStrategyFactory`
  - **Proxy stub**: `DummyImplementation` (for `OssifiableProxy` bootstrap)

- Deploy `Factory` (either deploy the factories yourself or use `script/DeployWrapperFactory.s.sol`):
  - `new Factory(WrapperConfig{ vaultFactory, stETH, wstETH, lazyOracle, stvPoolFactory, stvStETHPoolFactory, stvStrategyPoolFactory, withdrawalQueueFactory, loopStrategyFactory, ggvStrategyFactory, dummyImplementation, timelockFactory }, TimelockConfig{ minDelaySeconds })`

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
  - C (strategy): `StvStrategyPoolFactory.deploy(dashboard, stETH, allowlistEnabled, strategy, reserveRatioGapBP, withdrawalQueue)`

4) Strategy (only for C)
- Loop: `LoopStrategyFactory.deploy(stETH, poolProxy, loops)` (pool address required)
- GGV: `GGVStrategyFactory.deploy(stETH, teller, boringQueue)`

5) Initialize pool proxy and wire roles
- Proxy upgrade + init: `proxy__upgradeToAndCall(poolImpl, abi.encodeCall(BasePool.initialize, (Factory, NAME, SYMBOL)))`
- Dashboard roles: grant `FUND_ROLE` to pool, `WITHDRAW_ROLE` to withdrawal queue; for B/C also grant `MINT_ROLE` and `BURN_ROLE`
- Admin handover: transfer `DEFAULT_ADMIN_ROLE` on pool and dashboard from `Factory` to `msg.sender`
- Event: `VaultWrapperCreated(vault, pool, withdrawalQueue, strategy, configuration)`

Configuration summary

- Common: `nodeOperator`, `nodeOperatorManager`, `nodeOperatorFeeBP`, `confirmExpiry`, `allowlistEnabled`
- B/C only: `reserveRatioGapBP` (extra reserve ratio on top of vault RR)
- Loop strategy: `loops` (leverage cycles); strategy address is auto-deployed and passed to `StvStrategyPool`
- GGV strategy: `teller`, `boringQueue`
- Funding: `msg.value` must equal `VaultHub.CONNECT_DEPOSIT`

Note on circular dependencies and gas savings

- Wrapper ↔ Withdrawal Queue and StvStrategyPool ↔ Strategy have apparent circular dependencies (each needs the other's address).
- This is solved by pre-deploying proxies first:
  - Deploy pool proxy upfront (with `DummyImplementation`), obtain its address
  - Deploy Withdrawal Queue implementation passing the pool proxy address; then proxy + initialize
  - For Loop strategy, deploy the strategy with the pool proxy address
  - Finally, deploy pool implementation with concrete dependencies (WQ, strategy) and upgrade the pool proxy to it
- Because the definitive addresses are known at constructor-time for implementations, contracts store them as `immutable` (e.g., `BasePool` references, `StvStrategyPool.STRATEGY`, strategy’s `WRAPPER`). This reduces storage reads and saves gas on regular transactions.

Dedicated factories for wrappers, withdrawal queue and strategies are required to keep Factory contract bytecode size withing the limit.

Local deployment (quickstart)

- Files/scripts:
  - `lido-core/deployed-local.json` (core addresses produced by `make core-deploy`)
  - `script/HarnessCore.s.sol` + `script/harness-core.sh` (prepares core via impersonation: sets epoch, resumes Lido, submits initial ETH)
  - `script/DeployWrapperFactory.s.sol` (deploys Factory + implementation factories; writes `deployments/pool-local.json`)
  - `script/DeployWrapper.s.sol` (deploys a pool instance from the Factory using `script/deploy-local-config.json`)
  - `foundry.toml` (`fs_permissions` allow writing to `deployments/`)
- Procedure:
  - Start RPC (e.g., Anvil on `http://localhost:9123`).
  - `make core-deploy` (deploys core and writes `lido-core/deployed-local.json`).
  - `bash script/harness-core.sh` (prepares core; default initial submission ≈ 15k ETH; override `INITIAL_LIDO_SUBMISSION` if needed).
  - `bash script/deploy-local.sh` (deploys Factory and then a Wrapper using `script/deploy-local-config.json`).
  - Artifacts:
    - `deployments/pool-local.json`: deployed `Factory` and implementation factory addresses
    - `deployments/pool-instance.json`: deployed Vault, Dashboard, Wrapper proxy, Withdrawal Queue, and Strategy (if applicable)

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
