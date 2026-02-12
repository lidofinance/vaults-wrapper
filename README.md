# Vaults Wrapper

Liquid staking pool system built on Lido V3 vaults with support for minting and external yield strategies.

## Quick Start

```bash
# Build
forge build

# Run tests
just test-unit                              # Unit tests (no env needed)
just -E .env.hoodi.local test-integration   # Integration tests (requires env)

# Format code
forge fmt
```

**Note:** Integration tests and deployment scripts require environment variables. Use `.env.*` files with `just -E`:
```bash
just -E .env.hoodi.local <command>    # Hoodi testnet
just -E .env.local <command>          # Local development
```

## Architecture

The system consists of:
- **Pool** (ERC20) - User-facing liquid staking token
- **Vault** - Lido V3 staking vault with validators
- **Dashboard** - Vault role management and operations interface
- **Withdrawal Queue** - Handles unstaking requests
- **Distributor** - Fee distribution to node operators
- **Timelock** - Admin for all components with execution delay
- **Strategy** (optional) - External yield optimization

## Pool Types

| Type | Minting | Strategy | Allowlist | Use Case |
|------|---------|----------|-----------|----------|
| **StvPool** | ❌ | ❌ | Optional | Basic staking pool |
| **StvStETHPool** | ✅ | ❌ | Optional | Pool with stETH liquidity management |
| **StvStrategyPool** | ✅ | ✅ | Required | Pool with external strategy (e.g., GGV) |

- **Minting**: Pool can mint/burn stETH for advanced liquidity operations
- **Strategy**: Pool integrates with external yield optimizer
- **Allowlist**: Restricts deposits to approved addresses

## Deployment

### Two-Phase Process

All deployments use a two-phase pattern for security:

1. **Start** - Deploys components, emits `PoolCreationStarted` with cryptographic commitment
2. **Finish** - Initializes contracts, wires roles, validates integrity (must complete within 24h)

### Using Just

```bash
# Deploy factory (one-time)
just -E .env.hoodi.local deploy-factory

# Deploy all pool types
just deploy-all .env.hoodi.local

# Deploy single pool (two-phase)
just deploy-pool-start $FACTORY_ADDRESS config/hoodi-stv.json
just deploy-pool-finish $FACTORY_ADDRESS deployments/intermediate-<timestamp>.json
```

### Configuration

Each pool type requires a JSON config. See `config/` directory for examples.

**Required fields:**
- `vaultConfig` - Node operator, manager, fees, confirmation expiry
- `timelockConfig` - Minimum delay, proposer, executor addresses
- `commonPoolConfig` - Token name/symbol, withdrawal delay, emergency committee
- `auxiliaryPoolConfig` - Minting, allowlist, reserve ratio gap settings
- `strategyFactory` - Address of strategy factory (or zero address)

### Factory Contract

**Constructor:**
```solidity
new Factory(locatorAddress, SubFactories({
    stvPoolFactory,
    stvStETHPoolFactory,
    withdrawalQueueFactory,
    distributorFactory,
    timelockFactory
}))
```

**Deployment Functions:**
```solidity
// Simplified wrappers
createPoolStvStart(vaultConfig, timelockConfig, commonPoolConfig, allowlistEnabled)
createPoolStvStETHStart(vaultConfig, timelockConfig, commonPoolConfig, allowlistEnabled, reserveRatioGapBP)

// Generic (used by wrappers above)
createPoolStart(vaultConfig, timelockConfig, commonPoolConfig, auxiliaryConfig, strategyFactory, strategyDeployBytes)

// Finalization (for all pool types)
createPoolFinish(vaultConfig, timelockConfig, commonPoolConfig, auxiliaryConfig, strategyFactory, strategyDeployBytes, intermediate)
```

### Start Phase Deploys

1. Timelock controller
2. Pool proxy (uninitialized with DummyImplementation)
3. Withdrawal queue proxy (uninitialized)
4. Vault + Dashboard (not connected to VaultHub yet)
5. Withdrawal queue implementation
6. Distributor
7. Pool implementation (StvPool or StvStETHPool based on config)
8. Stores deployment hash with 24h deadline

### Finish Phase Actions

1. Validates deployment hash, deadline, and sender
2. Connects vault to VaultHub (requires ETH = `VAULT_HUB.CONNECT_DEPOSIT()`)
3. Upgrades pool proxy to real implementation and initializes
4. Upgrades withdrawal queue proxy and initializes
5. Deploys strategy (if specified) and adds to allowlist
6. Grants emergency committee roles (pause deposits/minting)
7. Grants operational roles (fund, rebalance, withdraw, mint, burn)
8. Transfers admin to timelock
9. Emits `PoolCreated` event

### Role Architecture

**Pool:**
- `DEFAULT_ADMIN_ROLE` → Timelock
- `DEPOSITS_PAUSE_ROLE` → Emergency Committee
- `MINTING_PAUSE_ROLE` → Emergency Committee (if minting enabled)

**Dashboard:**
- `DEFAULT_ADMIN_ROLE` → Timelock
- `FUND_ROLE` → Pool
- `REBALANCE_ROLE` → Pool
- `WITHDRAW_ROLE` → Withdrawal Queue
- `MINT_ROLE`, `BURN_ROLE` → Pool (if minting enabled)
- `PAUSE_BEACON_CHAIN_DEPOSITS_ROLE` → Emergency Committee

**Distributor:**
- `MANAGER_ROLE` → Node Operator Manager

### Gas Optimization Notes

- Circular dependencies (Pool ↔ Withdrawal Queue, Pool ↔ Strategy) resolved by deploying proxies first with DummyImplementation, then upgrading
- All cross-contract references stored as `immutable` to save gas on operations
- Separate factories keep main Factory under 24KB bytecode limit

## Local Development

### Setup Lido Core

```bash
# Clone and install dependencies
just core-init feat/vaults

# Deploy to local Anvil
just core-deploy lido-core 9123
```

### Deploy Pool System

```bash
# Start local node
anvil --chain-id 1 --auto-impersonate --port 9123

# In another terminal
export CORE_LOCATOR_ADDRESS=$(jq -r '.lidoLocator.proxy.address' lido-core/deployed-local.json)
export RPC_URL=http://localhost:9123

# Deploy factory
just deploy-factory

# Deploy pools
just deploy-all .env.local
```

### Testing

```bash
# Unit tests (no env required)
just test-unit

# Integration tests (requires env with RPC_URL and CORE_LOCATOR_ADDRESS)
just -E .env.hoodi.local test-integration

# Specific test file
just -E .env.hoodi.local test-integration "stv-pool.test.sol"
```

**Required environment variables:**
- `RPC_URL` - RPC endpoint with deployed Lido core
- `CORE_LOCATOR_ADDRESS` - Address of Lido Locator contract
- `DEPLOYER` - Deployer address (for deployments)
- `PRIVATE_KEY` - Private key (for deployments)

## Output Artifacts

- `deployments/pool-factory-latest.json` - Factory and sub-factory addresses
- `deployments/intermediate-<timestamp>-<config>.json` - Intermediate state for finish phase
- `deployments/pool-instance-<config>-<chainId>-<timestamp>.json` - Final deployment with all addresses

## Available Commands

```bash
just --list                              # Show all available commands

# Deployment (requires -E .env.xxx)
just -E .env.xxx deploy-factory          # Deploy factory
just -E .env.xxx deploy-pool-start ...   # Start pool deployment
just -E .env.xxx deploy-pool-finish ...  # Finish pool deployment  
just -E .env.xxx deploy-all <env>        # Deploy factory + all pool types

# Testing
just test-unit                           # Run unit tests (no env needed)
just -E .env.xxx test-integration [path] # Run integration tests (requires env)

# Local core setup
just core-init [branch]                  # Clone and setup Lido core
just core-deploy [subdir] [port]         # Deploy Lido core locally
```

## Documentation

- [Foundry Book](https://book.getfoundry.sh/)
- [Lido V3 Vaults](https://github.com/lidofinance/core)
