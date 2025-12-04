## Actors, roles, levers

### User Actions

- Deposit: ETH -> STV
- Mint: Pledge STV -> Borrow stETH / wstETH
- Burn: Repay stETH / wstETH -> Unpledge STV
- Withdraw: Queue STV -> Wait -> Claim ETH
- Transfer: Move STV (checks health factor if debt exists)
- TransferWithLiability: Atomic move of STV + stETH debt

### System Actions

- Pool deployment
- Finalize: Process queued withdrawals (burn STV, unlock ETH).
- Rebalance:
  - Internal: Burn STV to repay stETH debt.
  - Force Rebalance: Liquidation of unhealthy users (Permissionless).
  - Socialize Loss: Spread bad debt across all users if necessary (Requires Role).
- Pause/Resume
- SyncVaultParameters: Update Reserve Ratio/Threshold from VaultHub.
- Disconnect Vault:
  - Voluntary: Initiated by Timelock/Admin. Requires 0 liability.
  - Forced: Triggered by Validator exits and rebalancing.
- Trigger Validator Withdrawals: Force exit validators on Beacon Chain (EIP-7002).

### Events

- stETH Rebase:
  - Positive: Liability grows slower than assets (good).
  - Negative: Liability grows (slashing), potentially causing undercollateralization.
- Vault slashing
- Vault rewards
- Vault performance related to Core
  - underperformed
  - overperformed
- Lido Core oracle report missed for some time


### Comprehensive onchain actors-roles-levers table

This section details the actors within the system, their underlying principals, the specific "levers" (roles/permissions) they hold, and their function within the system's control loops. It also describes how these permissions are granted, particularly during the system deployment via `Factory`.

| Actor                     | Component                                 | Role / Permission                        | Lever / Capability                                                                              | Source / Notes                                                    |
| :------------------------ | :---------------------------------------- | :--------------------------------------- | :---------------------------------------------------------------------------------------------- | :---------------------------------------------------------------- |
| User                      | `StvPool`                                 | `DEPOSIT_ROLE` (if AllowList enabled)    | `depositETH` (Fund)                                                                             | Granted by `ALLOW_LIST_MANAGER_ROLE`                              |
|                           | `StvPool`                                 | -                                        | `transfer`, `approve`                                                                           | Permissionless                                                    |
|                           | `StvStETHPool`                            | -                                        | `mintStethShares`, `mintWsteth` (Leverage)                                                      | Permissionless (if minting enabled)                               |
|                           | `StvStETHPool`                            | -                                        | `burnStethShares`, `burnWsteth` (Deleverage)                                                    | Permissionless                                                    |
|                           | `StvStETHPool`                            | -                                        | `transferWithLiability`                                                                         | Permissionless                                                    |
|                           | `StvStETHPool`                            | -                                        | `forceRebalance` (Permissionless liquidation)                                                   | Permissionless                                                    |
|                           | `WithdrawalQueue`                         | -                                        | `requestWithdrawal`, `requestWithdrawalBatch`                                                   | Permissionless                                                    |
|                           | `WithdrawalQueue`                         | -                                        | `claimWithdrawal`, `claimWithdrawalBatch`                                                       | Permissionless                                                    |
|                           | `GGVStrategy`                             | -                                        | `supply`, `requestExitByWsteth`                                                                 | Permissionless                                                    |
|                           | `GGVStrategy`                             | -                                        | `cancelGGVOnChainWithdraw`,<br>`replaceGGVOnChainWithdraw`                                      | Permissionless                                                    |
|                           | `Distributor`                             | -                                        | `claim`                                                                                         | Permissionless                                                    |
| Finalizer Bot             | `WithdrawalQueue`                         | `FINALIZE_ROLE`                          | `finalize`, `setFinalizationGasCostCoverage`                                                    | Granted by Admin (Timelock) after deployment                      |
| Node Operator             | `Dashboard`                               | `TRIGGER_VALIDATOR_WITHDRAWAL_ROLE`      | `triggerValidatorWithdrawals`                                                                   | Granted by Admin (Timelock) after deployment                      |
|                           | `Dashboard`                               | `REQUEST_VALIDATOR_EXIT_ROLE`            | `requestValidatorExit`                                                                          | Granted by Admin (Timelock) after deployment                      |
|                           | `Dashboard`                               | `UNGUARANTEED_BEACON_CHAIN_DEPOSIT_ROLE` | `unguaranteedDepositToBeaconChain`                                                              | Granted by Admin (Timelock) after deployment                      |
|                           | `StakingVault`                            | -                                        | `depositToBeaconChain` (if depositor)                                                           | Set in `StakingVault` during initialization                       |
| Node Operator Manager     | `Dashboard`                               | `NODE_OPERATOR_MANAGER_ROLE`             | `addFeeExemption`, `setFeeRecipient`, `setFeeRate`                                              | Initialized by Factory during `createPoolStart`                   |
|                           | `Distributor`                             | `MANAGER_ROLE`                           | `addToken`, `setMerkleRoot`                                                                     | Initialized by Factory during `createPoolStart`                   |
| AllowList Manager == NO ? | `StvPool`                                 | `ALLOW_LIST_MANAGER_ROLE`                | `addToAllowList`, `removeFromAllowList`                                                         | Granted by Admin (Timelock) after deployment                      |
| Emergency Committee       | `StvPool`                                 | `DEPOSITS_PAUSE_ROLE`                    | `pauseDeposits`                                                                                 | Granted by Factory during `createPoolFinish`                      |
|                           | `StvStETHPool`                            | `MINTING_PAUSE_ROLE`                     | `pauseMinting`                                                                                  | Granted by Factory during `createPoolFinish`                      |
|                           | `WithdrawalQueue`                         | `WITHDRAWALS_PAUSE_ROLE`                 | `pauseWithdrawals`                                                                              | Granted by Factory during `createPoolFinish`                      |
|                           | `WithdrawalQueue`                         | `FINALIZE_PAUSE_ROLE`                    | `pauseFinalization`                                                                             | Granted by Factory during `createPoolFinish`                      |
|                           | `GGVStrategy`                             | `SUPPLY_PAUSE_ROLE`                      | `pauseSupply`                                                                                   | Granted by Factory during `createPoolFinish`                      |
|                           | `Dashboard`                               | `PAUSE_BEACON_CHAIN_DEPOSITS_ROLE`       | `pauseBeaconChainDeposits`                                                                      | Granted by Factory during `createPoolFinish`                      |
| Timelock Controller       | `OssifiableProxy`<br>of `StvPool`         | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Transferred by Factory during `createPoolFinish`                  |
|                           | `StvPool`                                 | `DEFAULT_ADMIN_ROLE`                     | `grantRole`, `revokeRole`                                                                       | Granted by Factory during `createPoolFinish`                      |
|                           | `OssifiableProxy`<br>of `StvStETHPool`    | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Transferred by Factory during `createPoolFinish`                  |
|                           | `StvStETHPool`                            | `DEFAULT_ADMIN_ROLE`                     | `setMaxLossSocializationBP` + all above                                                         | Granted by Factory during `createPoolFinish`                      |
|                           | `StvStETHPool`                            | `MINTING_RESUME_ROLE`                    | `resumeMinting`                                                                                 | Granted by Admin (self) after deployment                          |
|                           | `StvPool`                                 | `DEPOSITS_RESUME_ROLE`                   | `resumeDeposits`                                                                                | Granted by Admin (self) after deployment                          |
|                           | `OssifiableProxy`<br>of `WithdrawalQueue` | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Transferred by Factory during `createPoolFinish`                  |
|                           | `WithdrawalQueue`                         | `DEFAULT_ADMIN_ROLE`                     | `grantRole`, `revokeRole`                                                                       | Granted by Factory during `createPoolFinish`                      |
|                           | `WithdrawalQueue`                         | `WITHDRAWALS_RESUME_ROLE`                | `resumeWithdrawals`                                                                             | Granted by Admin (self) after deployment                          |
|                           | `WithdrawalQueue`                         | `FINALIZE_RESUME_ROLE`                   | `resumeFinalization`                                                                            | Granted by Admin (self) after deployment                          |
|                           | `OssifiableProxy`<br>of `GGVStrategy`     | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Transferred by Factory during `createPoolFinish`                  |
|                           | `GGVStrategy`                             | `DEFAULT_ADMIN_ROLE`                     | `grantRole`, `revokeRole`                                                                       | Granted by Factory during `createPoolFinish`                      |
|                           | `GGVStrategy`                             | `SUPPLY_RESUME_ROLE`                     | `resumeSupply`                                                                                  | Granted by Admin (self) after deployment                          |
|                           | `OssifiableProxy`<br>of `Dashboard`       | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Transferred by Factory during `createPoolFinish`                  |
|                           | `Dashboard`                               | `DEFAULT_ADMIN_ROLE`                     | `setConfirmExpiry`, `setPDGPolicy`, `recoverERC20`                                              | Granted by Factory during `createPoolFinish`                      |
|                           | `Dashboard`                               | `RESUME_BEACON_CHAIN_DEPOSITS_ROLE`      | `resumeBeaconChainDeposits`                                                                     | Granted by Admin (self) after deployment                          |
|                           | `Dashboard`                               | `CHANGE_TIER_ROLE`                       | `changeTier`, `updateShareLimit`                                                                | Granted by Admin (self) after deployment                          |
|                           | `Dashboard`                               | `VOLUNTARY_DISCONNECT_ROLE`              | `voluntaryDisconnect`                                                                           | Granted by Admin (self) after deployment                          |
|                           | `Dashboard`                               | `VAULT_CONFIGURATION_ROLE`               | `connectToVaultHub`, `transferVaultOwnership`                                                   | Granted by Admin (self) after deployment                          |
|                           | `StvStETHPool`                            | `LOSS_SOCIALIZER_ROLE`                   | `forceRebalanceAndSocializeLoss`                                                                | Granted by Admin (Timelock) after deployment                      |
| `StvPool`                 | `Dashboard`                               | `FUND_ROLE`                              | `fund`                                                                                          | Granted by Factory during `createPoolFinish`                      |
|                           | `Dashboard`                               | `REBALANCE_ROLE`                         | `rebalanceVaultWithShares`                                                                      | Granted by Factory during `createPoolFinish`                      |
| `StvStETHPool`            | `Dashboard`                               | `MINT_ROLE`                              | `mintShares`, `mintWstETH`                                                                      | Granted by Factory during `createPoolFinish`                      |
|                           | `Dashboard`                               | `BURN_ROLE`                              | `burnShares`, `burnWstETH`                                                                      | Granted by Factory during `createPoolFinish`                      |
| `WithdrawalQueue`         | `Dashboard`                               | `WITHDRAW_ROLE`                          | `withdraw`                                                                                      | Granted by Factory during `createPoolFinish`                      |
|                           | `StvStETHPool`                            | -                                        | `rebalanceMintedStethSharesForWithdrawalQueue`<br>`transferFromWithLiabilityForWithdrawalQueue` | Always has the permission by design.                              |
| PDG / DSM TODO            |                                           |                                          |                                                                                                 |                                                                   |
| Lido Core Oracle          | `VaultHub`                                | -                                        | `applyVaultReport`                                                                              | Called by `LazyOracle`                                            |
| Lido DAO (`Agent`)        | `VaultHub`                                | `VAULT_MASTER_ROLE`                      | `disconnect`                                                                                    | Governance                                                        |
|                           | `VaultHub`                                | `REDEMPTION_MASTER_ROLE`                 | `setLiabilitySharesTarget`                                                                      | Governance                                                        |
|                           | `VaultHub`                                | `BAD_DEBT_MASTER_ROLE`                   | `socializeBadDebt`, `internalizeBadDebt`                                                        | Governance                                                        |
| `Factory`                 | `OssifiableProxy`<br>of `StvPool`         | Proxy Admin                              | `upgradeTo`, `changeAdmin`                                                                      | Held temporarily between `createPoolStart` and `createPoolFinish` |
| (Pool Deployer)           | `StvPool`                                 | (temporarily) `DEFAULT_ADMIN_ROLE`       | `grantRole`, `revokeRole`                                                                       | Held temporarily between `createPoolStart` and `createPoolFinish` |
|                           | `StvPool`                                 | -                                        | Grants `DEPOSITS_PAUSE_ROLE`                                                                    | To Emergency Committee during `createPoolFinish`                  |
|                           | `Dashboard`                               | -                                        | Grants `FUND_ROLE`, `REBALANCE_ROLE`, `MINT_ROLE`, `BURN_ROLE`                                  | To `StvPool` during `createPoolFinish`                            |
|                           | `Dashboard`                               | -                                        | Grants `WITHDRAW_ROLE`                                                                          | Granted to `WithdrawalQueue` during `createPoolFinish`            |

## Upgradability

The system uses a mixed upgradability approach with different proxy patterns for different components. The proxy types used are:

- **OssifiableProxy** is a custom ERC1967-based transparent proxy that extends OpenZeppelin's pattern with "ossification" capability taken from Lido V2 core
    - NB: Ossifiable version of the proxy has been taken due to being already battle-tested in Lido V2, not specificly for the ossification feature
- TODO: about strategy per-user proxies
- TODO: semi-proxying mechanics of `GGVStrategy`

### Upgradeable Components (via OssifiableProxy)

- **StvPool / StvStETHPool**:
  - Created during `createPoolStart` with DummyImplementation
  - Upgraded to real implementation in `createPoolFinish`

- **WithdrawalQueue**: Deployed behind `OssifiableProxy`
  - Same deployment pattern as Pool

- **GGVStrategy**:
  - Created in `createPoolFinish` for strategy pools
  - Implementation deployed via `GGVStrategyFactory`

### Upgradeable Components (via Lido's Proxy Patterns)

- **StakingVault**: Uses `PinnedBeaconProxy` (Lido V3 pattern)
  - Deployed by `VaultFactory` from BEACON
  - Can be "pinned" to specific implementation version (ossified)
  - When pinned, ignores beacon upgrades and uses pinned implementation
  - Managed by Lido protocol governance

- **Dashboard**: Uses `OssifiableProxy`
  - Deployed by `VaultFactory` with DASHBOARD_IMPL
  - Admin rights transferred to TimelockController in `createPoolFinish`
  - Upgradeable via Lido's governance process

### Non-Upgradeable Components

Deployed directly without proxies:

- **Factory**: Immutable singleton, no upgrade path
- **Sub-Factories**: StvPoolFactory, StvStETHPoolFactory, WithdrawalQueueFactory, DistributorFactory, GGVStrategyFactory, TimelockFactory
- **Distributor**: Deployed directly, immutable per pool instance
- **TimelockController**: OpenZeppelin standard, immutable
- **StrategyCallForwarder**: Deployed per user, immutable

### Upgrade Authority

- **TimelockController** is the admin for:
  - StvPool / StvStETHPool proxy
  - WithdrawalQueue proxy
  - GGVStrategy proxy (if applicable)
  - Dashboard proxy

- **Lido Governance** controls:
  - StakingVault beacon (via VaultHub)
  - Dashboard implementation (via VaultFactory)

### Upgrade Process

To upgrade a component:
1. Deploy new implementation contract
2. Propose upgrade via TimelockController (requires PROPOSER_ROLE)
3. Wait for timelock delay (`minDelaySeconds`)
4. Execute upgrade via TimelockController (requires EXECUTOR_ROLE)
5. Call `proxy__upgradeToAndCall(newImpl, initData)` on the proxy

### Migration Considerations

- **Two-phase deployment** (start/finish) prevents incomplete setups
- **DummyImplementation** pattern ensures proxies exist before initialization
- **Temporary admin** (Factory) during deployment, then transferred to TimelockController
- **DEPLOY_START_FINISH_SPAN_SECONDS** (1 day) enforces timely completion
- **Intermediate state tracking** prevents replay attacks and ensures consistency
