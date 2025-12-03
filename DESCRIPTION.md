# Attempt to describe the system

## Purpose

- Provide a tokenized position (STV) for assets in a Lido V3 StakingVault.
- Allow users to borrow stETH/wstETH against STV while keeping vault‑level solvency.
- Absorb Lido’s staking dynamics (rebases, slashing, exits) while keeping user‑level risk bounded via LTV, liquidation, and loss socialization caps.
- Preserve safe exit for users even in stressed validator / oracle conditions, via withdrawal queue and emergency controls.

## Scope

### Docs
- separate by reader:
	- actors, roles, levers, ACL
		- where it goes?
	- invariants, security properties
		- to scaffold test plan on top level
	- test plan
	- extreme states and mitigations
		- used for test plan
		- just put to repo as docs
	- top-level (for arwer)


- for us:
	- for test plan
	- SPEC
- for NO https://github.com/lidofinance/docs/blob/v3-docs-update/run-on-lido/stvaults/building-guides/pooled-staking-product.md
	- how to deploy a pool
	- how to maintain a pool
	- how to deploy UI
- for partner protocols who build on top of Lido
	- for strategy developers
- for security assestors? are anybody 'd like to evaludate wrapper?
- docs.lido.fi: general description, router for in-depth tutorials

### CLI

### Lido alerting

TODO

### On-chian

#### Inside

##### Wrapper Layer

- Factory: Deploys new StvPool / StvStETHPool / StvStETHPool + GGVStrategy / StvStETHPool + arbitrary strategy.
- StvPool: Base ERC20 token implementation (STV).
- StvStETHPool: Extended pool with stETH borrowing & rebalancing logic.
- Withdrawal Queue: Manages exit requests, delays, and finalization.
- Distributor: Handles reward distribution (if applicable).
- AllowList: Manages deposit permissions (optional).
- TimelockController: Admin of the StvPool and WithdrawalQueue proxies.

#### Strategy Layer

- GGVStrategy: Specific GGV strategy implementation.
- Arbitrary strategy (follows `IStrategy`): Generic interface.

#### On the edge

- Dashboard: The owner/controller of the StakingVault.
- StakingVault: Holds the ETH and Validator credentials (0x02...).
-
- NO's validator lifecycle ?

#### Outside

- Lido V3 (Vaults)
- Lido V2
    - Lido Oracle reports
    - stETH / wstETH token
- Ethereum Network
    - Execution layer
        - (Gas, Block time, Fusaka TX limit, ...)
    - Consensus Layer
        - Validators status (Active, Exited, Slashed).
        - Rewards/Penalties skimming.
- Points / Rewards:
  - Off-chain or on-chain incentives obtained by NO

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


## Stocks (state)

These are the things that build up over time and stick around until something changes them.

⚠️ Proxy, OpenZeppelin ACL, features are not included.

| Stock (State Variable)                                                          | Contract          | Type                                                                                        | Inflow                                                                                                                                                                                                  | Outflow                                                                                                                                                                                                                        | Description                                                                                                                                                  |
| :------------------------------------------------------------------------------ | :---------------- | :------------------------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------- |
|                                                                                 |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| **Operational State**                                                           |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                | *Variables changed during regular flows*                                                                                                                     |
| `stv_supply`                                                                    | `StvPool`         | `uint256`                                                                                   | `StvPool.initialize`<br>`StvPool.depositETH`<br>`StvStETHPool.depositETHAndMintStethShares`<br>`StvStETHPool.depositETHAndMintWsteth`                                                                   | `WithdrawalQueue.burnStvForWithdrawalQueue`<br>`StvStETHPool.rebalanceMintedStethSharesForWithdrawalQueue`                                                                                                                     | `totalSupply`. Total supply of the STV (Staking Vault) token.                                                                                                |
| `stv_of`                                                                        | `StvPool`         | `address -> uint256`                                                                        | `StvPool.depositETH`<br>`StvPool.transfer`<br>`StvStETHPool.transferWithLiability`<br>`WithdrawalQueue.transferFromForWithdrawalQueue`<br>`WithdrawalQueue.transferFromWithLiabilityForWithdrawalQueue` | `StvPool.transfer`<br>`StvStETHPool.transferWithLiability`<br>`WithdrawalQueue.transferFromForWithdrawalQueue`<br>`WithdrawalQueue.transferFromWithLiabilityForWithdrawalQueue`<br>`WithdrawalQueue.burnStvForWithdrawalQueue` | ERC20 `balanceOf`. Per-account STV balances.                                                                                                                 |
| `unlocked_stv_of` *computed*                                                    | `StvStETHPool`    | `uint256`                                                                                   | N/A (computed from `balanceOf` and `mintedStethShares`)                                                                                                                                                 | N/A (computed)                                                                                                                                                                                                                 | `unlockedStvOf`. Amount of STV that can be unlocked if a specified amount of stETH shares is burned.                                                         |
| `stv_of_wq`                                                                     | `StvPool`         | `uint256`                                                                                   | `StvPool.transferFromForWithdrawalQueue`<br>`StvStETHPool.transferFromWithLiabilityForWithdrawalQueue`                                                                                                  | `StvPool.burnStvForWithdrawalQueue`                                                                                                                                                                                            | `balanceOf(WITHDRAWAL_QUEUE)`. STV balance held by the WithdrawalQueue contract for pending withdrawal requests.                                             |
| `assets_pool_total` *computed*                                                  | `StvPool`         | `uint256`                                                                                   | `StvPool.depositETH`<br>`StvPool.receive()`<br>`StvStETHPool.depositETHAndMintStethShares`<br>`StvStETHPool.depositETHAndMintWsteth`<br>Vault rewards/rebases (oracle reports)                          | `WithdrawalQueue.finalize` (via `burnStvForWithdrawalQueue`)<br>Vault slashing/penalties (oracle reports)                                                                                                                      | `totalAssets`. Total assets in the pool computed from vault value plus exceeding minted stETH (or minus unassigned liability).                               |
| `assets_of` *computed*                                                          | `StvPool`         | `address -> uint256`                                                                        | `StvPool.depositETH`<br>`StvPool.receive()`<br>`StvPool.transfer`<br>`StvStETHPool.depositETHAndMintStethShares`<br>`StvStETHPool.depositETHAndMintWsteth`<br>`StvStETHPool.transferWithLiability`      | `StvPool.transfer`<br>`StvStETHPool.transferWithLiability`<br>`WithdrawalQueue.transferFromForWithdrawalQueue`<br>`WithdrawalQueue.transferFromWithLiabilityForWithdrawalQueue`                                                | `assetsOf`. Per-account assets computed from STV balance as proportional share of total assets.                                                              |
| `unlocked_assets_of` *computed*                                                 | `StvStETHPool`    | `uint256`                                                                                   | N/A (computed from `assetsOf` and `mintedStethShares`)                                                                                                                                                  | N/A (computed)                                                                                                                                                                                                                 | `unlockedAssetsOf`. Amount of assets that can be withdrawn if a specified amount of stETH shares is burned. Computed as assets minus required locked amount. |
|                                                                                 |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| `stv_allowance_user`                                                            | `StvPool`         | `address -> address -> uint256`                                                             | `StvPool.approve`<br>`StvPool.increaseAllowance`                                                                                                                                                        | `StvPool.decreaseAllowance`<br>`StvPool.transferFrom`                                                                                                                                                                          | ERC20 `allowance`. Approved spending limits for third-party spenders.                                                                                        |
| `liability_user`                                                                | `StvStETHPool`    | `address -> uint256`                                                                        | `StvStETHPool.mintStethShares`<br>`StvStETHPool.mintWsteth`<br>`StvStETHPool.depositETHAndMintStethShares`<br>`StvStETHPool.depositETHAndMintWsteth`                                                    | `StvStETHPool.burnStethShares`<br>`StvStETHPool.burnWsteth`<br>`StvStETHPool.forceRebalance`<br>`StvStETHPool.forceRebalanceAndSocializeLoss`<br>`WithdrawalQueue.transferFromWithLiabilityForWithdrawalQueue`                 | Current per-user stETH share liability in the wrapper pool.                                                                                                  |
| `total_pool_minted_steth_shares`                                                | `StvStETHPool`    | `uint256`                                                                                   | `StvStETHPool.mintStethShares`<br>`StvStETHPool.mintWsteth`<br>`StvStETHPool.depositETHAndMintStethShares`<br>`StvStETHPool.depositETHAndMintWsteth`                                                    | `StvPool.rebalanceUnassignedLiability`<br>`StvStETHPool.burnStethShares`<br>`StvStETHPool.burnWsteth`<br>`StvStETHPool.rebalanceMintedStethSharesForWithdrawalQueue`                                                           | Current total stETH share liability across all users in the wrapper pool.                                                                                    |
| `liability_pool_unassigned`<br>*computed*                                       | `StvStETHPool`    | `uint256`                                                                                   | N/A (computed from `vault_liability_shares` and user liabilities)                                                                                                                                       | `StvPool.rebalanceUnassignedLiability`<br>`StvPool.rebalanceUnassignedLiabilityWithEther`                                                                                                                                      | `VaultLiability` - `TotalUserLiability`. Liability not assigned to any specific user.                                                                        |
| `liability_pool_exceeding`<br>*computed*                                        | `StvStETHPool`    | `uint256`                                                                                   | N/A (computed from `liability_pool_total` and `vault_liability_shares`)                                                                                                                                 |                                                                                                                                                                                                                                | Excess minted stETH over vault liability when rebalancing happens on StakingVault bypassing wrapper.                                                         |
| `is_healthy_user`<br>*computed*                                                 | `StvStETHPool`    | `bool`                                                                                      |                                                                                                                                                                                                         |                                                                                                                                                                                                                                | false if the forced rebalance threshold is breached                                                                                                          |
| `is_undercollateralized`<br>*computed*                                          |                   | `bool`                                                                                      |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| `wq_locked_stv`                                                                 | `WithdrawalQueue` | `mapping`                                                                                   | `WithdrawalQueue.requestWithdrawal`<br>`WithdrawalQueue.requestWithdrawalBatch`                                                                                                                         | `WithdrawalQueue.finalize`<br>`WithdrawalQueue.burnStvForWithdrawalQueue`                                                                                                                                                      | Portion of `requests.cumulativeStv` representing STV currently locked in the queue.                                                                          |
| `wq_requests`                                                                   | `WithdrawalQueue` | `mapping`                                                                                   | `WithdrawalQueue.requestWithdrawal`<br>`WithdrawalQueue.requestWithdrawalBatch`                                                                                                                         | `WithdrawalQueue.finalize`                                                                                                                                                                                                     | `requests`. Details of each withdrawal request (owner, amount, status).                                                                                      |
| `wq_requests_by_owner`                                                          | `WithdrawalQueue` | `address -> set<uint256>`                                                                   | `WithdrawalQueue.requestWithdrawal`<br>`WithdrawalQueue.requestWithdrawalBatch`                                                                                                                         | `WithdrawalQueue.finalize`<br>`WithdrawalQueue.claimWithdrawal`<br>`WithdrawalQueue.claimWithdrawalBatch`                                                                                                                      | `requestsByOwner`. Per-user index of withdrawal request IDs.                                                                                                 |
| `wq_counters`                                                                   | `WithdrawalQueue` | `uint128 lastRequestId`<br>`uint128 lastFinalizedRequestId`<br>`uint96 lastCheckpointIndex` | `WithdrawalQueue.requestWithdrawal`<br>`WithdrawalQueue.requestWithdrawalBatch`<br>`WithdrawalQueue.finalize`                                                                                           | N/A (monotonic counters)                                                                                                                                                                                                       | `lastRequestId`, `lastFinalizedRequestId`, `lastCheckpointIndex` track queue progress.                                                                       |
| `wq_total_locked_assets`                                                        | `WithdrawalQueue` | `uint96`                                                                                    | `WithdrawalQueue.finalize`                                                                                                                                                                              | `WithdrawalQueue.claimWithdrawal`<br>`WithdrawalQueue.claimWithdrawalBatch`                                                                                                                                                    | `totalLockedAssets`. ETH locked in the withdrawal queue available for claiming.                                                                              |
| `wq_checkpoints`                                                                | `WithdrawalQueue` | `mapping`                                                                                   | `WithdrawalQueue.finalize`                                                                                                                                                                              | N/A                                                                                                                                                                                                                            | `checkpoints`. Snapshots of STV and stETH share rates for finalized ranges.                                                                                  |
| `distributor_claimed`                                                           | `Distributor`     | `mapping`                                                                                   | `Distributor.claim`                                                                                                                                                                                     | N/A (cumulative)                                                                                                                                                                                                               | `claimed`. Tracks amount of tokens claimed by each user per token.                                                                                           |
| `ggv_user_call_forwarder`                                                       | `GGVStrategy`     | `address -> address`                                                                        | `GGVStrategy.supply`<br>`GGVStrategy.requestExitByWsteth`<br>`GGVStrategy.requestWithdrawalFromPool`<br>`GGVStrategy.burnWsteth`<br>`GGVStrategy.recoverERC20`                                          | N/A                                                                                                                                                                                                                            | `userCallForwarder`. User address -> `StrategyCallForwarder` address.                                                                                        |
|                                                                                 |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| **Lido Core (V2 + V3)**                                                         |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                | *Stocks in Lido Core V2 contracts (stETH, wstETH) and Lido V3 Vaults layer.*                                                                                 |
| `vault_total_value`                                                             | `VaultHub`        | `uint256`                                                                                   | `VaultHub.applyVaultReport`                                                                                                                                                                             | `VaultHub.applyVaultReport`                                                                                                                                                                                                    | `VaultRecord.report.totalValue` (+ `inOutDelta`). Effective ETH value of a vault.                                                                            |
| `vault_liability_shares`                                                        | `VaultHub`        | `uint96`                                                                                    | `VaultHub.mintShares`, `VaultHub.applyVaultReport`, `VaultHub.socializeBadDebt`                                                                                                                         | `VaultHub.burnShares`, `VaultHub.applyVaultReport`, `VaultHub.internalizeBadDebt`                                                                                                                                              | `VaultRecord.liabilityShares`. stETH-share liability of a vault to Core Pool.                                                                                |
| `vault_max_liability_shares`                                                    | `VaultHub`        | `uint96`                                                                                    | `VaultHub.applyVaultReport`                                                                                                                                                                             | `VaultHub.applyVaultReport`                                                                                                                                                                                                    | `VaultRecord.maxLiabilityShares`. Peak liability shares used for reserve locking.                                                                            |
| `vault_redemption_shares`                                                       | `VaultHub`        | `uint128`                                                                                   | `VaultHub.setLiabilitySharesTarget`                                                                                                                                                                     | `VaultHub.applyVaultReport`, `VaultHub.burnShares`                                                                                                                                                                             | `VaultRecord.redemptionShares`. Shares earmarked for Lido Core redemptions.                                                                                  |
| `vault_cumulative_lido_fees`                                                    | `VaultHub`        | `uint128`                                                                                   | `VaultHub.applyVaultReport`                                                                                                                                                                             | N/A (cumulative)                                                                                                                                                                                                               | `VaultRecord.cumulativeLidoFees`. Total protocol fees accrued on a vault.                                                                                    |
| `vault_settled_lido_fees`                                                       | `VaultHub`        | `uint128`                                                                                   | `VaultHub.settleLidoFees`                                                                                                                                                                               | N/A (cumulative)                                                                                                                                                                                                               | `VaultRecord.settledLidoFees`. Portion of fees already paid to treasury.                                                                                     |
| `vault_bad_debt_to_internalize`                                                 | `VaultHub`        | `uint256`                                                                                   | `VaultHub.internalizeBadDebt`                                                                                                                                                                           | `VaultHub.decreaseInternalizedBadDebt`                                                                                                                                                                                         | `badDebtToInternalize`. Shares of bad debt to be socialized as protocol loss.                                                                                |
| `vault_minimal_reserve`                                                         | `VaultHub`        | `uint128`                                                                                   | `VaultHub.connectVault`, `VaultHub.applyVaultReport`                                                                                                                                                    | `VaultHub.applyVaultReport`                                                                                                                                                                                                    | `VaultRecord.minimalReserve`. Minimum extra ETH that must remain locked per vault.                                                                           |
| `vault_assets`                                                                  | `StakingVault`    | `uint256`                                                                                   | `StakingVault.fund`, Beacon rewards                                                                                                                                                                     | `StakingVault.withdraw`, `StakingVault.depositToBeaconChain`, validator exits                                                                                                                                                  | `address(this).balance`. Total ETH held by a specific staking vault.                                                                                         |
| `vault_staged_balance`                                                          | `StakingVault`    | `uint256`                                                                                   | `StakingVault.stage`                                                                                                                                                                                    | `StakingVault.depositFromStaged`, `StakingVault.unstage`                                                                                                                                                                       | `stagedBalance`. ETH staged for future validator activations.                                                                                                |
| Fee Leftover                                                                    | `Dashboard`       | `uint128`                                                                                   | `Dashboard.voluntaryDisconnect` (via `_collectFeeLeftover`)                                                                                                                                             | `Dashboard.recoverFeeLeftover`                                                                                                                                                                                                 | `feeLeftover`. Node operator fees collected when the vault is disconnected.                                                                                  |
|                                                                                 |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| `steth_total_supply`                                                            | `Lido (stETH)`    | `uint256`                                                                                   | `Lido.submit`, `Lido.mintShares`, Oracle reward application<br>`StvStETHPool.depositETHAndMintStethShares`                                                                                              | `Lido.burnShares`, withdrawal queue redemptions, negative rebase                                                                                                                                                               | ERC20 `totalSupply` of stETH across Core Pool and stVault-backed positions.                                                                                  |
| `steth_total_shares`                                                            | `Lido (stETH)`    | `uint256`                                                                                   | `Lido.submit`, `Lido.mintShares`                                                                                                                                                                        | `Lido.burnShares`                                                                                                                                                                                                              | Internal `totalShares` backing all stETH balances.                                                                                                           |
| `steth_approve_of_pool_for_dashboard`<br>`wsteth_approve_of_pool_for_dashboard` |                   |                                                                                             | `StvStETHPool.initialize`                                                                                                                                                                               |                                                                                                                                                                                                                                | `STETH.approve(address(DASHBOARD), type(uint256).max);`<br>`WSTETH.approve(address(DASHBOARD), type(uint256).max);`                                          |
| `wsteth_total_supply`                                                           | `wstETH`          | `uint256`                                                                                   | `wstETH.wrap` (stETH -> wstETH)<br>`StvStETHPool.depositETHAndMintWsteth`                                                                                                                               | `wstETH.unwrap` (wstETH -> stETH)                                                                                                                                                                                              | ERC20 `totalSupply` of non-rebasing wstETH.                                                                                                                  |
|                                                                                 |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                |                                                                                                                                                              |
| **Administrative State**                                                        |                   |                                                                                             |                                                                                                                                                                                                         |                                                                                                                                                                                                                                | *Variables changed seldomly, requiring special permissions*                                                                                                  |
| Allow List                                                                      | `AllowList`       | `mapping`                                                                                   | `AllowList.addToAllowList`                                                                                                                                                                              | `AllowList.removeFromAllowList`                                                                                                                                                                                                | Addresses with `DEPOSIT_ROLE` allowed to deposit when allowlist is enabled.                                                                                  |
| `pool_rr`, `pool_force_rebalance_rr`                                            | `StvStETHPool`    | `uint16`, `uint16`                                                                          | `StvStETHPool.initialize`<br>`StvStETHPool.syncVaultParameters`                                                                                                                                         | `StvStETHPool.syncVaultParameters`                                                                                                                                                                                             | `reserveRatioBP`. Target ratio of collateral to debt.<br>`forcedRebalanceThresholdBP`. Health threshold (in BP) at which positions must be force-rebalanced. |
| Max Loss Socialization                                                          | `StvStETHPool`    | `uint16`                                                                                    | `StvStETHPool.setMaxLossSocializationBP`                                                                                                                                                                | `StvStETHPool.setMaxLossSocializationBP`                                                                                                                                                                                       | `maxLossSocializationBP`. Max basis points of loss that can be socialized.                                                                                   |
| Merkle Root                                                                     | `Distributor`     | `bytes32`                                                                                   | `Distributor.setMerkleRoot`                                                                                                                                                                             | Overwritten                                                                                                                                                                                                                    | `root`. Root of the Merkle tree for reward distribution.                                                                                                     |
| IPFS CID                                                                        | `Distributor`     | `string`                                                                                    | `Distributor.setMerkleRoot`                                                                                                                                                                             | Overwritten                                                                                                                                                                                                                    | `cid`. IPFS Content Identifier for the distribution data.                                                                                                    |
| Supported Tokens                                                                | `Distributor`     | `Set`                                                                                       | `Distributor.addToken`                                                                                                                                                                                  | N/A                                                                                                                                                                                                                            | `tokens`. Set of tokens supported for distribution.                                                                                                          |
| Distribution Last Processed Block                                               | `Distributor`     | `uint256`                                                                                   | `Distributor.setMerkleRoot`                                                                                                                                                                             | Overwritten                                                                                                                                                                                                                    | `lastProcessedBlock`. Block number used for off-chain indexing / monitoring.                                                                                 |
| Withdrawal Gas Cost Coverage                                                    | `WithdrawalQueue` | `uint64`                                                                                    | `WithdrawalQueue.setFinalizationGasCostCoverage`                                                                                                                                                        | Overwritten                                                                                                                                                                                                                    | `gasCostCoverage`. Per-request ETH compensation for finalizers inside checkpoints.                                                                           |
| Deployment Intermediate State                                                   | `Factory`         | `bytes32 -> uint256`                                                                        | `Factory.createPoolStart`                                                                                                                                                                               | `Factory.createPoolFinish` (marks finished), expiry                                                                                                                                                                            | `intermediateState`. Tracks per-deployment finish deadlines and completion markers.                                                                          |


## Properties of the system

This section documents the critical invariants and security properties enforced by the system, organized by pool configuration and with references to integration and unit tests that validate them.

### Deposits

Deposits (`depositETH`) revert if any of:
- deposits are paused (`DEPOSITS_PAUSE_ROLE`)
- allow list is enabled and sender is not allowed
- vault report is stale
- the vault has bad debt
- pool has unassigned liability

### Deposits with minting

TODO

### Supplying to GGV strategy

TODO

edge

### Overall accounting



### STV transfers

With and without liabilities.

STV transfers revert if any of:
- the vault has bad debt
- pool has unassigned liability
- if minting enabled:
  - `LTV > TOTAL_BP - RR` for sender after transfer
  - if transfer with liability:
    - transferred amounts of stv and liability maintain its `LTV > TOTAL_BP - RR`

Properties:
- **Sender Solvency**: Sender maintains `LTV <= TOTAL_BP - RR` (Reserve Ratio) after transfer
- **Transferred Solvency**: Transferred STV covers transferred liability with `LTV <= TOTAL_BP - RR` (if transferring liability)

### Minting

Minting (`mintStethShares`, `mintWsteth`) reverts if any of:
- minting is paused (`MINTING_PAUSE_ROLE`)
- `remainingMintingCapacitySharesOf` is insufficient (user would become unhealthy or exceed reserve ratio)

Properties:
- **Guarantee of minted amount**: Minted amount of stETH / wstETH is guaranteed to be exactly (with 1 wei accuracy) to match the `RR`
- **User Solvency**: User maintains `LTV <= TOTAL_BP - RR` (Reserve Ratio) after minting

### Burning

Burning (`burnStethShares`, `burnWsteth`) reverts if any of:
- user has insufficient minted shares
- `WSTETH.transferFrom` fails (for `burnWsteth`)

Properties:
- **Health Improvement**: Decreases user liability, improving LTV and Health Factor

### Withdrawal requests

Withdrawal requesting (`stv`, `_stethSharesToRebalance`) reverts if any of:
1. value (assets - liabilities) < `MIN_WITHDRAWAL_VALUE`
2. `previewRedeem(stv)` > `MAX_WITHDRAWAL_ASSETS`
3. transfer of (`stv`, `_stethSharesToRebalance`) from `msg.sender` to `WithdrawalQueue` reverts

Condition (3) implies that a user cannot request any withdrawal if their position is unhealty.

Properties:
- **Sender Solvency**: Sender maintains `LTV <= TOTAL_BP - RR` (Reserve Ratio) on remaining position
- **Request Solvency**: Locked STV covers locked liability (if any) with `LTV <= TOTAL_BP - RR`

### Claiming withdrawals

Claiming (`claimWithdrawal`, `claimWithdrawalBatch`) reverts if any of:
- `_requestId` is invalid (0 or > last finalized)
- request is not finalized
- request is already claimed
- `msg.sender` is not the owner of the request
- ETH transfer to recipient fails

Properties:
- **Finality**: Request marked as claimed, preventing double-spending

### Rebalancing user position

Rebalancing could be of different types:
- force rebalance
- force rebalance with loss socialization
- special rebalance of `WithdrawalQueue` (callable only by `WithdrawalQueue`)

Force rebalancing (`_account`) reverts if:
- the vault has bad debt
- pool has unassigned liability
- `_account` is `WithdrawalQueue`

No-op if:
- `isHealtyOf(_account)`

Properties:
- **Health Restoration**: User position restored to `LTV <= TOTAL_BP - RR` (Reserve Ratio)
- **Loss Cap**: Socialized loss (if any) limited by `maxLossSocializationBP`

#### Withdrawal Queue Integrity

**Property**: Withdrawal requests must be processed fairly and in order.

- **Request → Finalize → Claim flow**: Strict state progression for withdrawal requests
  - **Request**: User queues STV for withdrawal, STV locked in queue
  - **Finalize**: Finalizer bot burns STV, unlocks proportional ETH
  - **Claim**: User receives finalized ETH from queue
  - *Tested in*: `test/unit/withdrawal-queue/HappyPath.test.sol`, `test/integration/stv-pool.test.sol`

- **Checkpoint integrity**: Finalized ranges recorded with exchange rate snapshots
  - Each finalization creates a checkpoint with `cumulativeStv` and `cumulativeShares`
  - Exchange rate at finalization determines ETH claimable per request
  - *Tested in*: `test/unit/withdrawal-queue/Checkpoints.test.sol`, `test/unit/withdrawal-queue/Finalization.test.sol`

- **Gas cost coverage**: Finalizers reimbursed for gas costs via `gasCostCoverage`
  - Per-request ETH deduction to compensate finalizer
  - Admin-configurable via `setFinalizationGasCostCoverage`
  - *Tested in*: `test/unit/withdrawal-queue/GasCostCoverage.test.sol`, `test/unit/withdrawal-queue/GasCostCoverageConfig.test.sol`

- **Withdrawal queue locked assets**: STV locked in queue tracked separately from circulating supply
  - `wq_locked_stv` tracks total STV in pending requests
  - Finalization burns locked STV and unlocks proportional ETH
  - *Tested in*: `test/unit/stv-pool/WithdrawalQueue.test.sol`, `test/unit/withdrawal-queue/Views.test.sol`

#### Factory Deployment Security

**Property**: Pool deployments must be atomic, secure and prevent locking of the `CONNECT_DEPOSIT` ether.

- **Two-phase deployment**: `createPoolStart` → `createPoolFinish` prevents incomplete setups
  - `createPoolStart`: Deploys proxies, grants temporary Factory admin
  - `createPoolFinish`: Initializes contracts, configures roles, transfers admin to Timelock
  - Deployment must complete within `DEPLOY_START_FINISH_SPAN_SECONDS` (1 day)
  - *Tested in*: `test/integration/factory.test.sol`

- **Intermediate state protection**: Hash-based state tracking prevents replay and race conditions
  - `intermediateState[deploymentHash]` tracks finish deadline
  - Each deployment uniquely identified by creation params hash
  - State cleared after successful completion or expiry
  - *Tested in*: `test/integration/factory.test.sol`

- **Role initialization**: Complete role setup in `createPoolFinish`
  - Emergency committee granted pause roles
  - Timelock granted admin roles and proxy admin rights
  - Pool contracts granted interaction roles (FUND_ROLE, MINT_ROLE, etc.)
  - *Tested in*: `test/integration/dashboard-roles.test.sol`, `test/integration/factory.test.sol`

#### Circuit Breakers & Emergency Controls

**Property**: System parts must be pausable in emergencies.

- **Pause/Resume deposits**: Emergency committee can pause deposits to prevent new entries during crisis
  - `pauseDeposits` / `resumeDeposits` controlled by dedicated roles
  - *Tested in*: `test/unit/stv-pool/DepositsPause.test.sol`

- **Pause/Resume withdrawals**: Emergency committee can pause withdrawal requests
  - `pauseWithdrawals` / `resumeWithdrawals` controlled by dedicated roles
  - Does not prevent claiming already finalized withdrawals
  - *Tested in*: `test/unit/withdrawal-queue/InitialPause.test.sol`

- **Pause/Resume finalization**: Emergency committee can pause withdrawal processing
  - `pauseFinalization` / `resumeFinalization` controlled by dedicated roles
  - Requests remain queued but not processed during pause
  - *Tested in*: WithdrawalQueue pause tests

#### Vault Disconnection

**Property**: Vaults can safely exit the system while protecting user claims.

- **Voluntary disconnect preconditions**:
  - All user liabilities must be zero (`pool_liability_total == 0`)
  - Unassigned liability must be zero
  - Deposits, minting, and withdrawals must be paused
  - Requires Timelock to initiate `voluntaryDisconnect`
  - *Tested in*: `test/integration/disconnect.test.sol`

- **Disconnect workflow**: Multi-step process ensures safe vault exit
  1. Pause all user operations
  2. Force all users to deleverage (burn stETH if applicable)
  3. Trigger validator withdrawals (exit validators)
  4. Rebalance vault liability to zero
  5. Initiate voluntary disconnect via Timelock
  6. Finalize disconnect via oracle report
  7. Transfer vault ownership away from Dashboard
  - *Tested in*: `test/integration/disconnect.test.sol`

- **Post-disconnect claims**: Users can still claim their STV proportional to remaining assets
  - Withdrawal queue remains operational after disconnect
  - Final ETH distribution based on vault assets at disconnect

### Any pool

Properties that apply to all pool types: base `StvPool`, `StvStETHPool` (with or without strategy).

#### Vault Report Freshness

**Property**: Some operations must use fresh vault reports to prevent stale price exploitation.

- **Freshness enforcement**: Some operations revert if vault report is stale
  - **Deposits**: `depositETH` requires fresh report
  - **Withdrawals**: `requestWithdrawal`, `requestWithdrawalBatch` require fresh report
  - **Finalization**: `finalize` requires fresh report
  - **Minting** (if applicable): `mintStethShares`, `mintWsteth` require fresh report
  - **Burning** (if applicable): `burnStethShares`, `burnWsteth` require fresh report
  - **Force rebalance** (if applicable): `forceRebalance`, `forceRebalanceAndSocializeLoss` require fresh report
  - *Tested in*: `test/integration/report-freshness.test.sol` (comprehensive freshness validation)

- **Stale oracle protection**: if report stale for long time users must be able to claim their funds somehow TODO

#### Basic Solvency & Accounting

**Property**: All pools must maintain basic accounting integrity and handle insolvency.

- **STV supply conservation**: `Total STV Supply` accurately reflects `(Total Vault Assets - Total Vault Liability) / exchangeRate`
  - Deposits mint proportional STV based on vault asset value
  - Withdrawals burn STV and return proportional assets
  - *Tested in*: `test/unit/stv-pool/Conversion.test.sol`, `test/unit/stv-pool/Views.test.sol`

- **Vault-level solvency**: System detects and handles vault insolvency (bad debt)
  - Deposits and transfers blocked when `totalAssets < totalLiabilities`
  - Withdrawal claims protected during vault insolvency
  - *Tested in*: `test/unit/stv-pool/BadDebt.test.sol`, `test/unit/withdrawal-queue/BadDebt.test.sol`

- **Unassigned liability tracking**: System debt not owned by users must be tracked
  - `Unassigned Liability = vault_liability_shares - pool_liability_total`
  - Acts as a buffer for rounding errors and system-wide adjustments
  - *Tested in*: `test/unit/stv-pool/UnassignedLiability.test.sol`

- **Unassigned liability rebalancing**: System debt must be cleared via rebalancing
  - `rebalanceUnassignedWithEther` burns STV to reduce unassigned liability
  - `rebalanceUnassignedWithShares` uses stETH shares for rebalancing
  - Unassigned liability must be zero before voluntary disconnect
  - *Tested in*: `test/unit/stv-pool/RebalanceUnassignedWithEther.test.sol`, `test/unit/stv-pool/RebalanceUnassignedWithShares.test.sol`

### StvStETHPool w/o a strategy

Properties specific to `StvStETHPool` when no external strategy is attached. Users can deposit ETH, mint (borrow) stETH/wstETH against their STV, and withdraw.

#### User-Level Collateralization

**Property**: Individual user positions must remain properly collateralized.

- **Collateralization invariant**: `User Assets (STV value) >= User Liability (minted stETH)`
  - Enforced on: deposits, mints, burns, transfers, withdrawals
  - Health factor must remain above force rebalance threshold (`forcedRebalanceThresholdBP`)
  - *Tested in*: `test/unit/stv-steth-pool/HealthCheck.test.sol`, `test/unit/stv-steth-pool/ForceRebalance.test.sol`

- **Minting capacity constraint**: Amount of minted stETH cannot exceed vault + pool reserve ratios
  - `maxMintable = (userAssets * (10000 - poolRR)) / poolRR`
  - Reserve ratio enforcement prevents over-leveraging
  - *Tested in*: `test/unit/stv-steth-pool/MintingCapacity.test.sol`, `test/unit/stv-steth-pool/ExceedingMintedSteth.test.sol`

- **Transfer blocking on unhealthy positions**: Transfers are blocked if sender's health factor would be violated
  - Transfers with debt require sufficient collateral to remain
  - Unrestricted transfers allowed when user has no liability
  - *Tested in*: `test/unit/stv-steth-pool/TransferBlocking.test.sol`, `test/integration/stv-steth-pool.test.sol`

- **Transfer with liability**: Atomic transfer of both STV and debt
  - `transferWithLiability` allows users to transfer position with associated liability
  - Recipient must have sufficient health factor after receiving
  - Sender can overpay liability to give recipient extra collateral
  - *Tested in*: `test/unit/stv-steth-pool/TransferWithLiability.test.sol`, `test/integration/stv-steth-pool.test.sol`

- **Force rebalance liquidation**: Permissionless liquidation of unhealthy accounts
  - Anyone can trigger `forceRebalance` on undercollateralized accounts
  - Burns user STV to repay outstanding debt and restore system health
  - *Tested in*: `test/unit/stv-steth-pool/ForceRebalance.test.sol`

##### Detailed Restriction Conditions for STV Positions

**For STV positions WITHOUT liability (no minted stETH debt):**
- ✅ **Unrestricted transfers**: Users can freely transfer any amount of STV
- ✅ **Unrestricted withdrawals**: Can request withdrawal of any/all STV via WithdrawalQueue
- ✅ **No health checks**: No collateralization requirements apply
- ⚠️ **Implementation**: `_update()` hook in StvStETHPool skips health checks when `mintedStethSharesOf(_from) == 0` (src/StvStETHPool.sol:790-791)

**For STV positions WITH liability (minted stETH debt > 0):**

*Health Factor Definition:*
```
assetsThreshold = liabilityInStETH * TOTAL_BASIS_POINTS / (TOTAL_BASIS_POINTS - forcedRebalanceThresholdBP)
isHealthy = userAssets >= assetsThreshold
```
Where `liabilityInStETH = STETH.getPooledEthBySharesRoundUp(mintedStethShares)`

*Restriction Conditions:*

1. **Regular STV transfers (`transfer`, `transferFrom`):**
   - ❌ **BLOCKED** if sender's health factor would be violated after transfer
   - ✅ **ALLOWED** if sender maintains sufficient collateral after transfer
   - **Formula**: `assetsOf(sender) - transferAmount >= calcAssetsToLockForStethShares(mintedStethSharesOf(sender))`
   - **Reserve ratio lock formula**: `assetsToLock = liabilityInStETH * TOTAL_BASIS_POINTS / (TOTAL_BASIS_POINTS - reserveRatioBP)`
   - **Implementation**: `_update()` checks `isHealthyOf(_from)` after transfer (src/StvStETHPool.sol:787-794)
   - **Enforcement point**: Reverts with threshold breach error if sender becomes unhealthy

2. **Transfer with liability (`transferWithLiability`):**
   - ✅ **ALLOWED** for any user to initiate
   - **Minimum STV requirement**: Transferred STV must satisfy `_stv >= calcStvToLockForStethShares(_stethShares)`
   - **Calculation**: `stvToLock = convertToStv(assetsToLock, RoundingCeil)` where `assetsToLock = liabilityInStETH * TOTAL_BASIS_POINTS / (TOTAL_BASIS_POINTS - reserveRatioBP)`
   - **Sender can overpay**: Can transfer more STV than minimum to give recipient extra collateral buffer
   - **Recipient health**: No explicit health check on recipient (they receive proportional collateral for liability)
   - **Atomic operation**: Both STV and liability transfer together in single transaction
   - **Implementation**: src/StvStETHPool.sol:195-203, 772-777

3. **Minting restrictions:**
   - ❌ **BLOCKED** if minting would exceed user's minting capacity
   - **Capacity formula**: `maxMintableShares = calcStethSharesToMintForAssets(assetsOf(user))`
   - **Which equals**: `maxMintableShares = userAssets * (TOTAL_BASIS_POINTS - reserveRatioBP) / liabilityInStETH`
   - **Remaining capacity**: `remainingCapacity = maxMintableShares - mintedStethSharesOf(user)`
   - ❌ **BLOCKED** if minting paused via `MINTING_PAUSE_ROLE`

4. **Withdrawal request restrictions:**
   - **Can withdraw unlocked STV only**: Must burn sufficient stETH shares to unlock the STV amount
   - **Unlocked assets formula**: `unlockedAssets = assetsOf(user) - calcAssetsToLockForStethShares(mintedStethSharesAfterBurn)`
   - **Process**: User specifies how much stETH to burn, which unlocks corresponding STV for withdrawal
   - ✅ **ALLOWED** to request withdrawal of all assets if all debt is repaid (burn all minted stETH)
   - ⚠️ **Partial withdrawals**: Must maintain health factor on remaining position

##### WithdrawalQueue Transfer Mechanics for Requesting Withdrawals

When users request withdrawals via `WithdrawalQueue.requestWithdrawal()` or `requestWithdrawalBatch()`, the system performs specialized transfers to lock STV (and optionally liability) in the queue:

**Transfer Path Selection (src/WithdrawalQueue.sol:399-405):**

1. **For positions WITHOUT liability** (`_stethShares == 0`):
   - Calls `POOL.transferFromForWithdrawalQueue(_from, _stv)`
   - Simple ERC20 transfer of STV from user to WithdrawalQueue
   - No liability involved

2. **For positions WITH liability** (`_stethShares > 0`):
   - Calls `POOL.transferFromWithLiabilityForWithdrawalQueue(_from, _stv, _stethShares)`
   - Atomically transfers both STV and stETH share liability from user to WithdrawalQueue
   - **Implementation**: src/StvStETHPool.sol:204-208

**Transfer Requirements for WithdrawalQueue:**

- **Minimum STV enforcement**:
  - `_stv >= calcStvToLockForStethShares(_stethShares)` (checked in `_checkMinStvToLock`)
  - Ensures sufficient collateral backs the liability being transferred
  - Uses ceiling rounding to protect the system

- **User can overpay STV**:
  - Transferring more STV than minimum is allowed
  - Extra STV provides buffer for WithdrawalQueue position
  - Enables users to withdraw more assets than strictly required by their debt

- **Liability transfer**:
  - `_transferStethSharesLiability(user, WithdrawalQueue, _stethShares)` (src/StvStETHPool.sol:775)
  - Decrements `mintedStethShares[user]` by `_stethShares`
  - Increments `mintedStethShares[WithdrawalQueue]` by `_stethShares`
  - Maintains total system liability invariant

- **STV transfer**:
  - Standard ERC20 `_transfer(user, WithdrawalQueue, _stv)` (src/StvStETHPool.sol:776)
  - After transfer, user's health is checked via `_update()` hook
  - Sender must maintain healthy position on remaining STV/liability (if any remains)

**WithdrawalQueue Position Accumulation:**

- WithdrawalQueue accumulates STV balance: `balanceOf(WITHDRAWAL_QUEUE)` increases with each request
- WithdrawalQueue accumulates liability: `mintedStethSharesOf(WITHDRAWAL_QUEUE)` increases with liability transfers
- During finalization, queue rebalances its position via `rebalanceMintedStethSharesForWithdrawalQueue()`

**Finalization & Rebalancing (src/WithdrawalQueue.sol:584, src/StvStETHPool.sol:549-556):**

When `WithdrawalQueue.finalize()` is called:

1. **Rebalance accumulated liability**:
   - Calls `POOL.rebalanceMintedStethSharesForWithdrawalQueue(totalStethShares, maxStvToRebalance)`
   - Burns STV from WithdrawalQueue to repay accumulated stETH share debt
   - Returns actual STV burned (may be less than max if exceeding minted stETH exists)

2. **Burn finalized STV**:
   - After rebalancing, burns remaining STV to convert to claimable ETH
   - STV burns reduce total supply and WithdrawalQueue balance

3. **Lock ETH for claims**:
   - Finalized requests record amount of ETH to distribute
   - ETH held in WithdrawalQueue contract until users call `claimWithdrawal()`

**Key Invariants for WithdrawalQueue Transfers:**

- ✅ **Queue-only permission**: Only WithdrawalQueue can call `transferFromWithLiabilityForWithdrawalQueue()`
- ✅ **Minimum collateral**: Transferred STV must always satisfy reserve ratio for transferred liability
- ✅ **System health preservation**: User's remaining position (if any) must remain healthy after transfer
- ✅ **Atomic liability movement**: STV and liability transfer together, maintaining collateralization
- ✅ **No undercollateralization**: Queue never receives undercollateralized positions (protected by minimum STV check)

#### Liability Accounting

**Property**: Total system liabilities must be accurately tracked and reconciled.

- **Total liability accounting**: `Total Vault Liability = Sum of User Liabilities + Unassigned Liability`
  - All minted stETH shares tracked at user level (`pool_liability_user`)
  - System-wide liability tracked (`pool_liability_total`)
  - Unassigned liability = `vault_liability_shares - pool_liability_total`
  - *Tested in*: `test/unit/stv-pool/UnassignedLiability.test.sol`

- **Locked vs unlocked assets**: Assets locked in reserves + withdrawal queue + unassigned liability <= total vault assets
  - `lockedAssets = (liabilityShares * reserveRatioBP) / 10000`
  - `unlockedAssets = totalAssets - lockedAssets - wqLockedAssets`
  - *Tested in*: `test/unit/stv-steth-pool/UnlockedAssets.test.sol`, `test/unit/stv-steth-pool/LockCalculations.test.sol`

#### Loss Socialization & Risk Management

**Property**: Losses must be fairly distributed and capped to protect users.

- **Loss socialization cap**: Socialized loss cannot exceed `maxLossSocializationBP` per operation
  - Hard limit prevents excessive loss socialization in a single action
  - Admin-configurable parameter (basis points)
  - *Tested in*: `test/unit/stv-steth-pool/LossSocializationLimiter.test.sol`

- **Force rebalance with loss socialization**: When liquidation alone is insufficient, losses can be socialized
  - Requires `LOSS_SOCIALIZER_ROLE`
  - `forceRebalanceAndSocializeLoss` spreads bad debt across all users
  - User liabilities reduced proportionally to absorb vault insolvency
  - *Tested in*: `test/integration/ggv.test.sol` (complex rebase with loss handling)

- **Unassigned liability loss absorption**: Rounding errors and socialized losses accumulate as unassigned liability
  - Acts as a buffer for system-wide debt not owned by specific users
  - Must be rebalanced using vault assets or protocol intervention
  - *Tested in*: `test/unit/stv-pool/UnassignedLiability.test.sol`

#### Minting & Burning Controls

**Property**: Minting and burning operations must maintain system health.

- **Minting capacity**: System calculates and enforces remaining minting capacity
  - `remainingMintingCapacity` accounts for current liabilities and reserve requirements
  - Cannot mint beyond vault's ability to maintain reserve ratio
  - *Tested in*: `test/unit/stv-steth-pool/MintingCapacity.test.sol`

- **Pause/Resume minting**: Emergency committee can pause leverage operations
  - `pauseMinting` / `resumeMinting` controlled by dedicated roles
  - `MINTING_PAUSE_ROLE` / `MINTING_RESUME_ROLE`
  - *Tested in*: `test/unit/stv-steth-pool/MintingPause.test.sol`

- **Deposit and mint atomicity**: Users can deposit and mint in single transaction
  - Atomic operation reduces transaction overhead
  - Subject to same reserve ratio and health factor checks
  - *Tested in*: `test/unit/stv-steth-pool/DepositAndMint.test.sol`

### StvStETHPool w/ or w/o a strategy

Properties that apply to all `StvStETHPool` configurations, regardless of whether an external strategy is attached. These are fundamental to the stETH borrowing mechanics.

#### Reserve Ratio Synchronization

**Property**: Pool parameters must stay synchronized with VaultHub configuration.

- **Sync vault parameters**: Reserve ratio and force rebalance threshold sync from VaultHub
  - `syncVaultParameters` updates `reserveRatioBP` and `forcedRebalanceThresholdBP`
  - Parameters derived from VaultHub's tier configuration
  - Must be called periodically to reflect governance changes
  - *Tested in*: `test/unit/stv-steth-pool/SyncVaultParameters.test.sol`, `test/unit/stv-steth-pool/VaultParameters.test.sol`

#### Minting Mechanics (stETH & wstETH)

**Property**: Both stETH and wstETH minting must work correctly with rebasing mechanics.

- **stETH share minting**: Users can mint stETH shares against STV collateral
  - `mintStethShares` increases user liability in shares
  - Subject to reserve ratio and health factor checks
  - *Tested in*: `test/unit/stv-steth-pool/MintingStethShares.test.sol`

- **wstETH minting**: Users can mint wstETH (non-rebasing wrapper) against STV collateral
  - `mintWsteth` wraps stETH into wstETH before sending to user
  - Liability tracked in underlying stETH shares
  - *Tested in*: `test/unit/stv-steth-pool/MintingWsteth.test.sol`

- **stETH share burning**: Users can repay stETH shares to reduce liability
  - `burnStethShares` decreases user liability
  - Improves health factor and unlocks STV for transfer
  - *Tested in*: `test/unit/stv-steth-pool/BurningStethShares.test.sol`

- **wstETH burning**: Users can repay wstETH to reduce liability
  - `burnWsteth` unwraps wstETH to stETH shares before burning
  - Liability reduced by underlying share amount
  - *Tested in*: `test/unit/stv-steth-pool/BurningWsteth.test.sol`

#### Internal Rebalancing

**Property**: System can rebalance positions to maintain health.

- **Rebalance minted stETH shares**: Internal rebalancing using vault assets
  - Automatically adjusts user or system liabilities
  - Used during finalization and force rebalance operations
  - *Tested in*: `test/unit/stv-steth-pool/RebalanceMintedStethShares.test.sol`

#### Asset Accounting

**Property**: Total assets must be accurately calculated including all sources.

- **Total assets calculation**: `totalAssets` includes vault balance, staged balance, and beacon chain validators
  - Accounts for ETH held in vault, staged for deposits, and active in validators
  - Updated based on oracle reports from Lido
  - *Tested in*: `test/unit/stv-steth-pool/Assets.test.sol`

### StvStETHPool + GGVStrategy

Properties specific to `StvStETHPool` when integrated with the GGV (presumably "Generic Gain Vault") strategy. The strategy allows borrowed stETH/wstETH to be supplied to an external protocol for additional yield.

#### Strategy Integration

**Property**: External strategies must integrate safely with pool mechanics and prevent cross-user attacks.

- **Per-user call forwarder**: Each user gets isolated `StrategyCallForwarder` proxy
  - Lazy deployment on first strategy interaction
  - User-specific proxy prevents cross-user attacks and isolates risk
  - Forwarder address tracked in `ggv_user_call_forwarder` mapping
  - *Tested in*: `test/integration/ggv.test.sol`

- **Strategy capacity enforcement**: Total supplied to strategy limited by vault parameters
  - Reserve ratio applies to strategy supplies (cannot over-leverage)
  - Minting capacity considers assets already in strategy
  - *Tested in*: `test/integration/ggv.test.sol`

- **Allowlist enforcement for strategy**: Strategy deposits may require allowlist permission
  - Additional access control layer for strategy interactions
  - Separate from base pool allowlist
  - *Tested in*: `test/integration/ggv.test.sol`

#### GGV-Specific Operations

**Property**: GGV strategy operations must maintain system integrity.

- **Supply to GGV**: Users can supply borrowed wstETH to GGV strategy
  - `supply` function routes wstETH through user's call forwarder
  - Strategy tracks supplied amounts per user
  - *Tested in*: `test/integration/ggv.test.sol`

- **Exit requests**: Users can request to withdraw wstETH from GGV
  - `requestExitByWsteth` initiates strategy withdrawal
  - May require time delay based on strategy mechanics
  - *Tested in*: `test/integration/ggv.test.sol`

- **Cancel/Replace GGV on-chain withdrawals**: Users can manage their pending GGV withdrawal requests
  - `cancelGGVOnChainWithdraw` cancels a pending withdrawal
  - `replaceGGVOnChainWithdraw` updates withdrawal request parameters
  - Provides flexibility during queue solving process
  - *Tested in*: `test/integration/ggv.test.sol`

#### GGV Queue Solving & Rebalancing

**Property**: GGV withdrawal queue must be processed fairly and efficiently.

- **GGV solver processing**: On-chain withdrawal queue processed via solver mechanism
  - Solver matches exit requests with available liquidity
  - Ensures fair execution of withdrawals
  - *Tested in*: `test/integration/ggv.test.sol` (complex rebase scenarios)

- **Surplus wstETH recovery**: Excess wstETH from strategy can be recovered
  - Strategy may accumulate surplus from yields or rebases
  - Recovery mechanism prevents value from being locked
  - *Tested in*: `test/integration/ggv.test.sol`

- **Complex rebase handling with strategy**: System handles stETH rebases while assets are in strategy
  - Positive rebases increase user equity
  - Negative rebases may trigger loss socialization if severe
  - Strategy assets included in total collateral calculations
  - *Tested in*: `test/integration/ggv.test.sol` (complex rebase with loss handling)

#### Strategy Circuit Breakers

**Property**: Strategy operations must be pausable independently.

<!--- **Pause/Resume strategy supply**: Emergency committee can pause strategy deposits-->
  - `pauseSupply` / `resumeSupply` controlled by dedicated roles
  - `SUPPLY_PAUSE_ROLE` / `SUPPLY_RESUME_ROLE`
  - Prevents new supplies while allowing exits
  - *Tested in*: Via Factory integration tests

## Regular flows

## Regular feedback loops

### User's LTV breached RR threshold yet not FRR

- user position is still healty
- minting is blocked

#### Feedback loops

- User improves their LTV
	- *Incentivized actors*: User (to restore minting capacity for additional leverage); liquidators monitor for further deterioration
	- *Detection*: `remainingMintingCapacitySharesOf(user)` returns zero; mint operations revert
	- *Preconditions*: ?
###


- **User's LTV breached RR threshold yet not FRR**: User position healthy but at reserve ratio limit, cannot mint more until burning debt or adding collateral
  - *Incentivized actors*: User (to restore minting capacity for additional leverage); liquidators monitor for further deterioration
  - *Detection*: `remainingMintingCapacitySharesOf(user)` returns zero; mint operations revert
  - *Preconditions*: ?

- **User has bad debt**: User position undercollateralized (assets < liability), requires permissionless force rebalancing to restore health
  - *Incentivized actors*: Anyone (permissionless `forceRebalance` liquidates position); user (to avoid liquidation by burning debt proactively)
  - *Detection*: `isHealthyOf(user)` returns false; `assetsOf(user) < calcAssetsToLockForStethShares(mintedStethSharesOf(user))`; user operations (transfer, withdrawal) blocked
  - *Preconditions*: Oracle report must be fresh; sufficient `exceedingMintedStethShares` available or vault rebalance creates it; force rebalance burns user STV to repay debt; if exceeding insufficient, may require `LOSS_SOCIALIZER_ROLE` to call `forceRebalanceAndSocializeLoss`

- **Withdrawal Queue has unfinalized requests**: Normal operational state where users have queued STV for withdrawal awaiting finalizer processing
  - *Incentivized actors*: Finalizer bot (receives `gasCostCoverage` per finalized request via `FINALIZE_ROLE`); users waiting for finalization to claim
  - *Detection*: `WithdrawalQueue.getLastRequestId() > getLastFinalizedRequestId()`; view functions show pending request count; users see "pending" status on withdrawal requests
  - *Preconditions*: Vault must have sufficient liquid ETH (not locked in CL validators); oracle report must be fresh; finalization not paused; finalizer bot operational with `FINALIZE_ROLE`; requests processed in FIFO order

- **Vault report is not fresh**: Most operations blocked
  - *Incentivized actors*: Lido oracle operators (protocol-level responsibility to report regularly); users must wait, cannot accelerate
  - *Detection*: `_requireFreshVaultReport()` checks fail; operations revert with staleness error; time since last `VaultHub.applyVaultReport` exceeds freshness threshold
  - *Preconditions*: Oracle reporting cycle must complete; typical oracle report frequency defines maximum wait time; no user-level or NO-level mitigation available; only view operations remain available during staleness

## Extreme states and stabilizing feedback loops

- **NO / NO manager keys** lost:
  - TODO

- **NO / NO manager keys compromised**:
  - TODO

- **Large withdrawal queue**:
  - TODO

- **Liability is transferred to the pooled vault from another vault**
  - TODO

- **A dangerous action is proposed on TimelockController**:
  - Examples of such actions:
    - Minting of stETH shares on the vault bypassing wrapper
    - Vault disconnection
    - Malicious / suspicious upgrade of any contract
  - TODO

- **Vault has bad debt**: `totalAssets < totalLiabilities`, deposits and transfers blocked, withdrawal claims protected
  - *Detection*: `totalAssets()` check on deposits/transfers/minting operations; vault monitoring dashboards
  - *Incentivized actors*: Protocol governance (Lido DAO) to restore protocol health; NO to exit validators and restore assets
  - *Preconditions*: Oracle report must be fresh; validator exits must complete; governance must decide on bad debt handling (socialize vs internalize)

- **Multiple unhealthy positions without liquidity**: Users breach force rebalance threshold but vault lacks ETH to liquidate, requires NO to decide validator exits
  - *Detection*: NO monitoring via CLI commands TODO
  - *Incentivized actors*: NO (operational responsibility, fee collection at stake); anyone can permissionlessly force rebalance once liquidity available
  - *Preconditions*: NO must calculate total ETH needed; NO decides based on organic inflow (CL/EL rewards, deposits), existing exit queue, withdrawal demand; validators must exit and finalize on CL; vault must have available ETH

- **Mass position undercollateralization**: stETH price spike causes widespread unhealthiness across many users, likely triggers vault-level force rebalance
  - *Detection*: Individual `isHealthyOf()` checks fail; aggregate vault health monitoring shows threshold breach
  - *Incentivized actors*: Anyone (permissionless force rebalance after vault rebalances); protocol (automatic vault rebalance via oracle)
  - *Preconditions*: Oracle report must reflect new prices; vault threshold breach triggers automatic rebalance; exceeding minted stETH must be created; individual force rebalances require fresh oracle report

- **Validators completely offline**: All vault validators offline, takes ~18 days (with 0.25% gap) to breach force rebalance threshold if stETH performs well
  - *Detection*: NO infrastructure monitoring; vault performance metrics vs stETH core performance; position health checks via CLI
  - *Incentivized actors*: NO (operational responsibility, reputational risk, fee collection depends on vault health)
  - *Preconditions*: NO must monitor regularly (not constant); NO evaluates time until threshold breach; validator exits require CL processing time

- **Prolonged validator downtime**: Vault offline 4-6 months until users become undercollateralized (assets < liability), accelerated by slashing
  - *Detection*: Long-term performance monitoring; position health checks showing deterioration; vault approaching undercollateralization
  - *Incentivized actors*: NO (emergency response); protocol governance (can trigger `forceValidatorExit` if NO unresponsive)
  - *Preconditions*: Escalation path from NO to protocol governance; `VaultHub.forceValidatorExit` requires governance role; validator exits must complete

- **Mass validator slashing**: Rapid value loss accelerates path to undercollateralization and vault-level force rebalance
  - *Detection*: Oracle report reflects slashing penalties; vault value drops suddenly; position health checks fail
  - *Incentivized actors*: Oracle (automated reporting); protocol governance (loss socialization decisions); anyone (permissionless force rebalance)
  - *Preconditions*: Oracle report must arrive post-slashing; vault rebalance may trigger automatically; loss socialization requires `LOSS_SOCIALIZER_ROLE`; may require governance bad debt handling

- **Vault breaches force rebalance threshold**: Entire vault forcibly rebalanced, creates exceeding minted stETH available for user force rebalancing
  - *Detection*: Automatic detection during oracle report application; vault health check in `VaultHub.applyVaultReport`
  - *Incentivized actors*: Oracle (automated); anyone for subsequent user force rebalancing (permissionless)
  - *Preconditions*: Oracle report must arrive; vault rebalance executed automatically; exceeding minted stETH created for wrapper; fresh oracle required for user force rebalances

- **Insufficient vault liquidity for rebalancing**: Vault shortfall prevents force rebalancing users, protocol can trigger `forceValidatorExit` via VaultHub
  - *Detection*: Force rebalance attempts fail or estimate shows insufficient vault balance; NO monitoring shows liquidity shortage
  - *Incentivized actors*: Protocol governance (system stability); NO (if governance escalates)
  - *Preconditions*: Governance must hold `VAULT_MASTER_ROLE` or similar; `VaultHub.forceValidatorExit` must be called; validators must exit on CL; ETH must return to vault

- **Oracle stale for extended period**: All operations freeze (deposits, withdrawals, minting, rebalancing) until fresh report arrives
  - *Detection*: Automatic freshness checks in operations (`_requireFreshVaultReport()`); user-facing errors on operation attempts
  - *Incentivized actors*: Lido oracle operators (protocol responsibility); NO cannot resolve directly
  - *Preconditions*: Oracle cycle must complete normally; no system-level mitigation available; users must wait

- **CL exit queue congestion**: Validator exit speed bottlenecked by consensus layer, independent of NO reaction time
  - *Detection*: CL monitoring shows long exit queue; expected exit time estimates exceed liquidity needs timeline
  - *Incentivized actors*: No specific actor can accelerate (network-level constraint)
  - *Preconditions*: CL must process queue at protocol-defined rate; NO can only queue exits, not accelerate; organic inflow may partially compensate during wait

- **Vault validators underperformance relative to stETH validators**
  - TODO

- **Large unassigned liability accumulation**: System debt from rounding/socialization must be cleared before voluntary disconnect
  - *Detection*: `unassignedLiability()` view function; checks during voluntary disconnect attempts; monitoring dashboards
  - *Incentivized actors*: Admin/Timelock (required for disconnect); NO (operational cleanup)
  - *Preconditions*: Must have vault ETH available for `rebalanceUnassignedLiabilityWithEther` or stETH for `rebalanceUnassignedLiability`; operations blocked until cleared; voluntary disconnect impossible until zero

- **Withdrawal queue backlog with no ETH**: Requests pending finalization but vault lacks liquidity, requires validator exits to process
  - *Detection*: `WithdrawalQueue` view functions show pending vs finalized gap; NO monitors queue depth vs vault balance
  - *Incentivized actors*: NO (user satisfaction, operational responsibility); Finalizer bot (receives gas cost coverage per finalization)
  - *Preconditions*: NO must exit sufficient validators; ETH must return to vault; finalizer bot must have `FINALIZE_ROLE`; fresh oracle report required for finalization

- **Post-rebalance exceeding minted stETH**: Vault rebalanced bypassing wrapper, creates `liability_pool_exceeding` that can be used for user rebalancing
  - *Detection*: `exceedingMintedStethShares()` view function; vault liability < wrapper total liability
  - *Incentivized actors*: Anyone (permissionless force rebalance using exceeding); unhealthy users benefit from cheaper rebalancing
  - *Preconditions*: Vault must have been rebalanced directly (not through wrapper); exceeding amount must cover user liability; fresh oracle report required

- **Critical yet solvable vulnarability found in Wrapper contracts**:
  - *Detection*: occasional self-review, immunify security report, Lido monitoring
  - *Incentivized actors*: Lido contributors, Emergency committee
  - *Actions*:
    - Emergency committee: pauses required features of
    - TODO: upgrade

- **Critical yet solvable vulnarability found in Vault contracts**:
  - TODO

- **Critical yet solvable vulnarability found in Lido Core**:
  - TODO
  - how the executor committee is insentivised to handle proper and improper proposed timelocked actions?



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

## Alerting

Monitoring system.

TODO

## Other PoA (Points of Attention)

- Oracle Freshness:
  - Critical for all value calculations.
  - Stale oracle = System freeze (no deposits/withdrawals/rebalancing/minting).
- attaching multiple strategies
- Unassigned Liability:
  - "System Debt" that accumulates from rounding errors or socialized losses.
  - Must be cleared before certain operations (e.g., voluntary disconnect).
- Rounding Issues:
  - 1 wei discrepancies between `stETH` (shares) and `ETH` (assets).
- Socialized Losses:
  - The mechanism to handle insolvency at the user level to protect the vault level.
- UI:
  - How complex system states (e.g., "Queued", "Claimable", "Rebalancing") are shown to users.
  - Warning users about Stale Oracle state.
- Initial user expectations: STV behaves as ERC-20 token, can withdraw
- APR/APY calculation
- cli
