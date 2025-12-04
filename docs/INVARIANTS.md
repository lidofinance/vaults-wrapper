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
