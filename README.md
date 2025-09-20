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

The Factory orchestrates deployment of the entire wrapper system (Vault, Dashboard, Wrapper, Withdrawal Queue, and optionally a Strategy) via dedicated implementation factories and proxies.

- Prerequisites (addresses required to deploy `Factory`):
  - **Core**: `IVaultFactory` (Lido `VaultFactory`), `stETH` token address
  - **Implementation factories**: `WrapperAFactory`, `WrapperBFactory`, `WrapperCFactory`, `WithdrawalQueueFactory`, `LoopStrategyFactory`, `GGVStrategyFactory`
  - **Proxy stub**: `DummyImplementation` (for `OssifiableProxy` bootstrap)

- Deploy `Factory` (either deploy the factories yourself or use `test/utils/FactoryHelper.sol` as a reference):
  - `new Factory(vaultFactory, stETH, waf, wbf, wcf, wqf, lsf, ggvf, dummyImplementation)`

- Create a complete wrapper system using one of the specialized entrypoints (send `msg.value == VaultHub.CONNECT_DEPOSIT`):
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
- Withdrawal Queue: impl via `WithdrawalQueueFactory.deploy(wrapperProxy, MAX_FINALIZATION_TIME)`, proxied and initialized with `initialize(nodeOperator, nodeOperator)`

3) Wrapper implementation (selected by configuration)
- By: `Factory` using the implementation factory
  - A: `WrapperAFactory.deploy(dashboard, allowlistEnabled, withdrawalQueue)`
  - B: `WrapperBFactory.deploy(dashboard, stETH, allowlistEnabled, reserveRatioGapBP, withdrawalQueue)`
  - C (strategy): `WrapperCFactory.deploy(dashboard, stETH, allowlistEnabled, strategy, reserveRatioGapBP, withdrawalQueue)`

4) Strategy (only for C)
- Loop: `LoopStrategyFactory.deploy(stETH, wrapperProxy, loops)` (wrapper address required)
- GGV: `GGVStrategyFactory.deploy(stETH, teller, boringQueue)`

5) Initialize wrapper proxy and wire roles
- Proxy upgrade + init: `proxy__upgradeToAndCall(wrapperImpl, abi.encodeCall(WrapperBase.initialize, (Factory, NAME, SYMBOL)))`
- Dashboard roles: grant `FUND_ROLE` to wrapper, `WITHDRAW_ROLE` to withdrawal queue; for B/C also grant `MINT_ROLE` and `BURN_ROLE`
- Admin handover: transfer `DEFAULT_ADMIN_ROLE` on wrapper and dashboard from `Factory` to `msg.sender`
- Event: `VaultWrapperCreated(vault, wrapper, withdrawalQueue, strategy, configuration)`

Configuration summary

- Common: `nodeOperator`, `nodeOperatorManager`, `nodeOperatorFeeBP`, `confirmExpiry`, `allowlistEnabled`
- B/C only: `reserveRatioGapBP` (extra reserve ratio on top of vault RR)
- Loop strategy: `loops` (leverage cycles); strategy address is auto-deployed and passed to `WrapperC`
- GGV strategy: `teller`, `boringQueue`
- Funding: `msg.value` must equal `VaultHub.CONNECT_DEPOSIT`

Note on circular dependencies and gas savings

- Wrapper ↔ Withdrawal Queue and WrapperC ↔ Strategy have apparent circular dependencies (each needs the other's address).
- This is solved by pre-deploying proxies first:
  - Deploy wrapper proxy upfront (with `DummyImplementation`), obtain its address
  - Deploy Withdrawal Queue implementation passing the wrapper proxy address; then proxy + initialize
  - For Loop strategy, deploy the strategy with the wrapper proxy address
  - Finally, deploy wrapper implementation with concrete dependencies (WQ, strategy) and upgrade the wrapper proxy to it
- Because the definitive addresses are known at constructor-time for implementations, contracts store them as `immutable` (e.g., `WrapperBase` references, `WrapperC.STRATEGY`, strategy’s `WRAPPER`). This reduces storage reads and saves gas on regular transactions.

Dedicated factories for wrappers, withdrawal queue and strategies are required to keep Factory contract bytecode size withing the limit.

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
