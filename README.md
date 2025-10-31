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
  - **Core (auto-discovered from Locator)**: `IVaultFactory`, `stETH`, `wstETH`, `lazyOracle`
  - **Implementation factories**: `StvPoolFactory`, `StvStETHPoolFactory`, `StvStETHPoolFactory`, `WithdrawalQueueFactory`, `LoopStrategyFactory`, `GGVStrategyFactory`
  - **Proxy stub**: `DummyImplementation` (for `OssifiableProxy` bootstrap)

- Deploy `Factory` (either deploy the factories yourself or use `script/DeployWrapperFactory.s.sol`):
  - `DeployWrapperFactory` now requires `CORE_LOCATOR_ADDRESS` and `FACTORY_PARAMS_JSON`; it derives all core addresses from the Locator.
- Constructor shape for reference: `new Factory(locator, SubFactories{ ... }, TimelockConfig{ ... }, StrategyParameters{ ggvTeller, ggvBoringOnChainQueue })`

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
