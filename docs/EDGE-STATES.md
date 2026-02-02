

# States and loops

### --- description of structure of this level sections ---

- description of the state (involving the stocks) (without explicit field naming)
- conditions (how the system could get there)
- expected propability
- loops:
  - name (without explicit field naming)
  - detection
  - actors and incentives
  - correction (actions required to restore system from the state)

### User LTV breached RR threshold yet not FRR

User position is still healthy but has breached the reserve ratio.

**Implications**:
- The user cannot mint more stETH/wstETH until burning debt or adding collateral.
- Risk of getting the user positoin getting unhealthy

**Conditions**:
- user has minted stETH shares up to their reserve ratio capacity;
- TODO

**Expected probability**: TODO

**Loops**:
- User improves their LTV
  - **Detection**: user sees on UI; mint fails
	  - TODO: implement it in UI
  - **Actors and incentives**: to enable minting; to reduce propability of getting unhealthy

### User position is unhealthy (FRR threshold breached but yet not bad debt)

User position breaches force rebalance threshold (`pool_force_rebalance_rr`) making it eligible for permissionless force rebalance, but position still has positive equity (`assets_of[user] >= liability_user[user]`). User operations (transfer, withdrawal) are blocked until health restored. Stocks involved: `liability_user[user]` relative to `assets_of[user]` exceeds force rebalance threshold but remains solvent.

**Conditions**: 
- general vault underperformance
- 

User's collateral-to-debt ratio deteriorates beyond force rebalance threshold due to vault underperformance, stETH price increase, or insufficient collateral management; position becomes liquidatable but not yet undercollateralized.

**Expected probability**: Low under normal operations; increases during vault performance issues or stETH volatility. More common than full undercollateralization due to safety buffer between force rebalance threshold and insolvency.

**Loops**:
- User self-correction to restore health
  - **Detection**: `isHealthyOf(user)` returns false; user operations (transfer, withdrawal, minting) revert; position still solvent (`assets >= liability`)
  - **Actors and incentives**: User (restore minting capability, avoid force liquidation with potential slippage/losses, maintain control over position)
  - **Preconditions**: User must either deposit additional ETH to increase collateral or burn stETH/wstETH debt to reduce liability; oracle report must be fresh

- Permissionless force rebalance by external parties
  - **Detection**: `isHealthyOf(user)` returns false; `assetsOf(user) < calcAssetsToLockForStethShares(mintedStethSharesOf(user))`; anyone can call `forceRebalance(user)`
  - **Actors and incentives**:
    - **External liquidators**: No direct economic incentive (no liquidation bonus/fee); altruistic system maintenance only
    - **Other vault users**: Minimize risk from unhealthy neighbor positions that could lead to systemic issues or loss socialization
    - **Node operator**: Maintain vault in healthy state to attract more users/stake and earn more fees; reputational incentive especially important since unhealthy positions often result from NO's own validator issues (slashing, downtime)
    - **Vault owner** (if separate from NO): Maintain healthy vault reputation to attract users to specific product/technology (e.g., DVT solutions like Obol/SSV using wrappers to expand adoption)
  - **Preconditions**: Vault must have sufficient `vault_assets` or `liability_pool_exceeding` available; oracle report fresh; if insufficient liquidity, vault-level force rebalance during oracle report will create exceeding for user liquidations (making "deadlock" scenario nearly impossible)

### User has bad debt (undercollateralized)

User position is undercollateralized where `assets_of[user] < liability_user[user]`. User's `is_healthy_user` is false. Requires permissionless force rebalancing to socialize losses.

**Conditions**: Likely ones:
- general Vault performance degradation
- TODO:

**Expected probability**: Low under normal operations; increases during validator downtime, slashing events, or stETH volatility.

- Rebalance and socialize by `LOSS_SOCIALIZER_ROLE`
  - **Detection**: TODO
  - **Actors and incentives**: Anyone (permissionless `forceRebalance` liquidates position); user (avoid liquidation by burning debt proactively before breach)
  - **Preconditions**:
    - `LOSS_SOCIALIZER_ROLE` is assigned

### One user has worse "health" others are fine

various fund proportions etc

### Vault report is stale

Most operations blocked system-wide. The oracle report freshness check fails, preventing deposits, withdrawals, minting, rebalancing, and transfers. Only view operations remain available.

**Conditions**: Time since last `VaultHub.applyVaultReport` exceeds the freshness threshold configured in the system.

**Expected probability**: Low under normal Lido operations; increases during oracle infrastructure issues or consensus layer problems.

**Loops**:
- Wait for oracle report
  - **Detection**: `_requireFreshVaultReport()` checks fail; operations revert with staleness error; time since last `VaultHub.applyVaultReport` exceeds freshness threshold
  - **Actors and incentives**: Lido oracle operators (protocol-level responsibility to report regularly); users must wait, cannot accelerate
  - **Preconditions**: Oracle reporting cycle must complete; typical oracle report frequency defines maximum wait time; no user-level or NO-level mitigation available

### Multiple unhealthy positions without liquidity

Multiple users breach force rebalance threshold (`is_healthy_user` = false for many users) but `vault_assets` insufficient for required force rebalances. Stocks involved: multiple users have `mintedStethSharesOf(user) > 0` and `isHealthyOf(user) = false`, while `vault_assets` < total ETH needed for all force rebalances.

**Conditions**: Combination of widespread user position deterioration (stETH price spike or vault underperformance) and low vault liquidity with most ETH locked in active CL validators. Often precedes or coincides with vault-level force rebalance threshold breach.

**Expected probability**: Very low. Minimum reserve ratio 2% with 0.25%+ gap to force rebalance threshold means vault must be completely offline for ~18 days to breach threshold, or 4-6 months for true undercollateralization (accelerated by slashing). When many users become unhealthy simultaneously, vault itself likely breaches force rebalance threshold first, triggering automatic vault rebalance that creates `liability_pool_exceeding` for user liquidations.

**Loops**:
- NO-managed validator exits for liquidation liquidity
  - **Detection**: NO monitoring via CLI commands to list all unhealthy positions; CLI calculates total ETH needed at current rate for all force rebalances; multiple `isHealthyOf(user)` return false; vault balance check shows insufficient ETH; anyone can attempt permissionless `forceRebalance()` but reverts with insufficient balance
  - **Actors and incentives**: Node operator (operational responsibility, monitor positions during significant vault performance drops, maintain system health); Permissionless liquidators (execute force rebalances once liquidity restored); Protocol governance (can trigger `VaultHub.forceValidatorExit()` if vault has shortfall and NO unresponsive)
  - **Preconditions**: NO uses CLI to assess: (1) total ETH needed for all unhealthy positions, (2) organic inflow rate (CL/EL rewards, new deposits), (3) existing validator exit queue, (4) withdrawal queue demand; NO decides how many validators to exit; CL processes exits (~27 hours normal, longer if congested); alternatively, if vault breaches force rebalance threshold during this period, automatic vault rebalance creates `liability_pool_exceeding` that can be used for cheaper user force rebalances without requiring as much liquid ETH; NO can rebalance users incrementally as any ETH becomes available on vault balance

### Withdrawal Queue has unfinalized requests

Normal operational state where users have queued STV for withdrawal awaiting finalizer processing. Stocks involved: `wq_locked_stv` > 0, `wq_counters.lastRequestId > wq_counters.lastFinalizedRequestId`.

**Conditions**: Users call `requestWithdrawal()` or `requestWithdrawalBatch()`, incrementing `wq_counters.lastRequestId` and locking STV in the queue.

**Expected probability**: Common; this is the normal withdrawal flow state between request and finalization.

**Loops**:
- Finalization processing
  - **Detection**: `WithdrawalQueue.getLastRequestId() > getLastFinalizedRequestId()`; view functions show pending request count; users see "pending" status on withdrawal requests
  - **Actors and incentives**: Finalizer bot (receives `gasCostCoverage` per finalized request via `FINALIZE_ROLE`); users waiting for finalization to claim their ETH
  - **Preconditions**: Oracle report must be fresh; finalization not paused; finalizer bot operational with `FINALIZE_ROLE`; requests processed in FIFO order; sufficient vault liquidity determines processing speed

### Withdrawal Queue has unfinalized requests and enough liquidity on the Vault to finalize them

Optimal operational state where withdrawal requests are pending but vault has sufficient liquid ETH (`vault_assets` adequate) to finalize immediately. Only awaiting finalizer bot execution.

**Conditions**: Users have queued withdrawals (`wq_locked_stv` > 0) and `vault_assets` (liquid ETH not locked in CL validators) exceeds the ETH value of pending requests.

**Expected probability**: Common during healthy operations with balanced inflow/outflow and proper vault liquidity management.

**Loops**:
- Immediate finalization by bot
  - **Detection**: `getLastRequestId() > getLastFinalizedRequestId()` AND vault balance check shows sufficient ETH; finalizer bot monitoring detects finalizeable requests
  - **Actors and incentives**: Finalizer bot (immediate processing for `gasCostCoverage` compensation per request); users (fast withdrawal experience)
  - **Preconditions**: Oracle report fresh; `FINALIZE_ROLE` holder active; finalization not paused; gas costs covered by `gasCostCoverage` setting; bot calls `finalize()` to process requests in FIFO order

### Withdrawal Queue has unfinalized requests beyond available atm Vault liquidity

Constrained operational state where withdrawal requests exceed vault's immediately available liquid ETH. Requests must wait for validator exits or organic inflows. Stocks involved: `wq_locked_stv` value (in ETH terms) exceeds current `vault_assets`.

**Conditions**: High withdrawal demand combined with most vault ETH locked in active CL validators; `vault_staged_balance` may also be committed to future validator activations; insufficient organic inflows (rewards, new deposits) to cover queue.

**Expected probability**: Low during normal operations; increases during withdrawal spikes, market stress, or when vault maintains high validator participation rate.

**Loops**:
- Liquidity restoration via validator exits
  - **Detection**: Finalization attempts fail or estimate shows insufficient vault balance; `vault_assets < sum(pending_withdrawal_requests_in_eth)`; NO monitoring CLI shows liquidity shortage; operations may partially process then pause
  - **Actors and incentives**: Node operator (manage validator exits to restore liquidity, maintain user experience); Finalizer bot (processes requests as liquidity becomes available); Users (wait for validator exit processing)
  - **Preconditions**: NO must trigger validator exits on CL; CL must process exit queue (~27 hours under normal conditions, longer during congestion); exited validator ETH must return to vault execution layer balance; finalizer processes incrementally as ETH becomes available; organic inflows (CL/EL rewards, new deposits) may partially cover demand

### Withdrawal queue is not finalized for long

Similar to "Stuck withdrawal queue" - requests remain pending for extended period. Users experience long wait times between `requestWithdrawal()` and `claimWithdrawal()`. Related to liquidity and validator exit speed.

**Conditions**: Combination of high withdrawal demand, low vault liquidity, slow validator exits, and/or CL exit queue congestion.

**Expected probability**: Low during normal operations; increases during stress periods (market downturns, loss of confidence, validator issues).

**Loops**:
- Liquidity restoration
  - **Detection**: Time since oldest unfinalized request creation; monitoring alerts on queue age
  - **Actors and incentives**: NO (manage validator exits); Finalizer bot (processes as liquidity becomes available); users (wait for processing)
  - **Preconditions**: Vault needs sufficient liquid ETH; may require validator exits and CL processing time

### Vault has bad debt

Vault-level insolvency where `assets_pool_total < total_pool_minted_steth_shares` (in asset terms). Deposits, transfers, and minting are blocked. Withdrawal claims remain protected but new operations restricted to prevent further losses.

**Conditions**: Severe validator slashing, prolonged downtime causing undercollateralization, or catastrophic loss event; `vault_total_value` drops below vault liabilities.

**Expected probability**: Very low; requires significant validator failures or slashing events beyond normal risk parameters.

**Loops**:
- Bad debt recovery
  - **Detection**: `totalAssets()` check on deposits/transfers/minting operations; vault monitoring dashboards show negative equity
  - **Actors and incentives**: Protocol governance (Lido DAO) to restore protocol health; NO to exit validators and restore assets; may require loss socialization or protocol intervention
  - **Preconditions**: Oracle report must be fresh; validator exits must complete; governance must decide on bad debt handling (socialize vs internalize via `VaultHub.internalizeBadDebt` or `socializeBadDebt`)

### Vault breaches force rebalance threshold

Entire vault forcibly rebalanced by VaultHub during oracle report processing. Creates `liability_pool_exceeding` (exceeding minted stETH) available for subsequent user force rebalancing operations. Vault-level health restored but individual user positions may still need rebalancing.

**Conditions**: Vault performance degradation causes breach of force rebalance threshold at vault level; triggered during `VaultHub.applyVaultReport`.

**Expected probability**: Low; designed as safety mechanism for severe vault underperformance.

**Loops**:
- Vault rebalance creates exceeding for user rebalancing
  - **Detection**: Automatic detection during oracle report application; vault health check in `VaultHub.applyVaultReport`; `liability_pool_exceeding` becomes available
  - **Actors and incentives**: Oracle (automated trigger); anyone for subsequent user force rebalancing (permissionless); unhealthy users benefit from available exceeding for cheaper liquidation
  - **Preconditions**: Oracle report must arrive; vault rebalance executed automatically; exceeding minted stETH created for wrapper; fresh oracle required for user force rebalances

### Vault shortfall

Insufficient vault liquidity for required operations. Vault has pending force rebalances or withdrawal finalizations but lacks liquid ETH. `vault_assets` insufficient relative to `vault_staged_balance` and operational needs. Related to "Insufficient vault liquidity for rebalancing" below.

**Conditions**: Most vault ETH locked in active validators; high liquidation or withdrawal demand; insufficient organic inflows; validator exits not processed yet.

**Expected probability**: Low during normal operations; increases during mass liquidation events or withdrawal spikes combined with high validator participation rate.

**Loops**:
- Force validator exits
  - **Detection**: Force rebalance attempts fail or estimate shows insufficient vault balance; NO monitoring shows liquidity shortage; operations revert with insufficient balance errors
  - **Actors and incentives**: Protocol governance (system stability, can trigger forced validator exits); NO (manage validator lifecycle if governance escalates)
  - **Preconditions**: Governance must hold `VAULT_MASTER_ROLE` or similar; `VaultHub.forceValidatorExit` must be called; validators must exit on CL; ETH must return to vault execution layer balance

### Liability is transferred to the pooled vault from another vault

External event where `vault_liability_shares` increases due to liability transfer from another vault in the Lido system. This can create `liability_pool_exceeding` if the wrapper's `total_pool_minted_steth_shares` doesn't account for the increase.

**Conditions**: Lido governance or VaultHub operations move liability between vaults; vault consolidation or rebalancing at protocol level.

**Expected probability**: Very rare; requires explicit governance action or protocol-level vault management.

**Loops**: TODO

### CL exit queue congestion

Consensus layer validator exit queue is congested, bottlenecking the speed at which validators can exit regardless of NO actions. Exit processing time extends significantly beyond normal ~27 hours. Network-level constraint independent of individual vault operations.

**Conditions**: High network-wide validator exit demand; CL exit queue at capacity; many validators across the network attempting to exit simultaneously.

**Expected probability**: Low during normal conditions; increases during network stress, market downturns, or protocol-wide events affecting multiple operators.

**Loops**:
- Wait for CL processing
  - **Detection**: CL monitoring shows long exit queue; expected exit time estimates exceed liquidity needs timeline; beacon chain explorer shows queue depth
  - **Actors and incentives**: No specific actor can accelerate (network-level constraint defined by CL protocol)
  - **Preconditions**: CL must process queue at protocol-defined rate; NO can only queue exits, not accelerate; organic inflow (CL/EL rewards, new deposits) may partially compensate during wait

### Vault validators underperformance relative to stETH validators

Vault validators consistently earn lower returns than stETH core validators, causing gradual deterioration of vault value relative to liability growth. Affects LTV ratios and health over time.

**Conditions**: Poor validator performance, infrastructure issues, attestation misses, or sync committee non-participation; prolonged downtime or network issues specific to vault validators.

**Expected probability**: Low with professional NO operations; increases with infrastructure problems or operator inexperience.

**Loops**: TODO

### NO / NO manager keys lost

Node operator or node operator manager loses access to their private keys, preventing operational management of the vault, validator lifecycle, and fee collection.

**Conditions**: Key backup failure, hardware failure, operational security incident.

**Expected probability**: Very low with proper key management practices.

**Loops**: TODO

### NO / NO manager keys compromised

Unauthorized access to node operator or manager keys, potentially allowing malicious actions like unauthorized validator exits, parameter changes, or fund movements.

**Conditions**: Security breach, phishing attack, insider threat, or compromised infrastructure.

**Expected probability**: Very low with proper security practices.

**Loops**: TODO

### Mass position undercollateralization

Widespread breach of user health thresholds across many positions simultaneously. Often triggered by stETH price spike or vault performance deterioration affecting all users proportionally.

**Conditions**: Sudden stETH price increase, vault-wide slashing event, or significant performance gap between vault and stETH; likely triggers vault-level force rebalance.

**Expected probability**: Low; requires systemic event affecting many positions.

**Loops**:
- Vault-level then user-level rebalancing
  - **Detection**: Individual `isHealthyOf()` checks fail for many users; aggregate vault health monitoring shows threshold breach
  - **Actors and incentives**: Anyone (permissionless force rebalance after vault rebalances); protocol (automatic vault rebalance via oracle)
  - **Preconditions**: Oracle report must reflect new prices/values; vault threshold breach triggers automatic rebalance; `liability_pool_exceeding` must be created; individual force rebalances require fresh oracle report

### Prolonged validator downtime

Extended period (4-6 months) of validators being offline or severely underperforming. Eventually users become undercollateralized (`assets_of[user] < liability_user[user]`). Accelerated by slashing.

**Conditions**: Unresolved infrastructure issues, NO abandonment, or severe operational problems persisting over months.

**Expected probability**: Very low; requires extreme operational failure and lack of intervention.

**Loops**:
- Escalation to governance intervention
  - **Detection**: Long-term performance monitoring; position health checks showing deterioration; vault approaching undercollateralization
  - **Actors and incentives**: NO (emergency response required); protocol governance (can trigger `forceValidatorExit` if NO unresponsive)
  - **Preconditions**: Escalation path from NO to protocol governance; `VaultHub.forceValidatorExit` requires governance role; validator exits must complete on CL

### Mass vault validator slashing

Significant slashing event affecting vault validators, causing rapid decrease in `vault_total_value` and corresponding drop in `assets_pool_total`. Accelerates path to undercollateralization and may trigger vault-level force rebalance.

**Conditions**: Validator misbehavior (double signing, surround votes), infrastructure compromise, or correlated failures across validators.

**Expected probability**: Very low with proper validator operations; slightly higher with shared infrastructure.

**Loops**:
- Oracle-driven rebalancing and loss handling
  - **Detection**: Oracle report reflects slashing penalties; `vault_total_value` drops suddenly; position health checks fail; automatic vault health checks during report application
  - **Actors and incentives**: Oracle (automated reporting); protocol governance (loss socialization decisions); anyone (permissionless force rebalance after exceeding created)
  - **Preconditions**: Oracle report must arrive post-slashing; vault rebalance may trigger automatically during report; loss socialization requires `LOSS_SOCIALIZER_ROLE`; may require governance bad debt handling

### Large unassigned liability accumulation

System debt from rounding errors or socialized losses accumulates in `liability_pool_unassigned`. Must be cleared before certain operations like voluntary disconnect can proceed. **Crucially, ANY amount of unassigned liability (>0) blocks all STV token transfers between users**, effectively freezing the token until rebalanced.

**Conditions**: Accumulation of rounding errors from many operations; loss socialization events; vault rebalancing that creates unassigned liability.

**Expected probability**: Medium for small amounts; low for large amounts requiring intervention.

**Loops**:
- Admin clears unassigned liability
  - **Detection**: `unassignedLiability()` view function shows non-zero value; checks during voluntary disconnect attempts fail; monitoring dashboards alert
  - **Actors and incentives**: Admin/Timelock (required for disconnect operations); NO (operational cleanup before major changes)
  - **Preconditions**: Must have vault ETH available for `rebalanceUnassignedLiabilityWithEther` or stETH for `rebalanceUnassignedLiability`; operations blocked until cleared; voluntary disconnect impossible until zero

### Rounding errors accumulation

Accumulation of 1-2 wei precision losses in `StvStETHPool` due to stETH/ETH conversions. Can prevent minting or burning the absolute full capacity of a user's position, leaving dust amounts.

**Conditions**: Repeated minting/burning operations where `Math.mulDiv` rounding leaves dust; specifically when `remainingMintingCapacityShares != totalMintingCapacityShares` due to liability mismatches.

**Expected probability**: High (almost guaranteed to happen eventually); but usually negligible in value.

**Loops**:
- Dust cleanup (difficult)
  - **Detection**: `remainingMintingCapacitySharesOf` returns non-zero but very small value; users cannot close position fully without leaving dust.
  - **Actors and incentives**: Users (annoyance); Protocol (precision loss).

### Post-rebalance exceeding minted stETH

Vault rebalanced directly via VaultHub bypassing wrapper, creating `liability_pool_exceeding` where `vault_liability_shares > total_pool_minted_steth_shares`. This exceeding can be used for cheaper user force rebalancing.

**Conditions**: VaultHub performs vault-level rebalance (automatic during oracle report if threshold breached); liability reduced at vault level but not assigned to users.

**Expected probability**: Low; occurs during vault-level force rebalancing events.

**Loops**:
- Utilize exceeding for user rebalancing
  - **Detection**: `exceedingMintedStethShares()` view function returns non-zero; vault liability < wrapper total liability
  - **Actors and incentives**: Anyone (permissionless force rebalance using exceeding); unhealthy users benefit from cheaper rebalancing without burning as much STV
  - **Preconditions**: Vault must have been rebalanced directly (not through wrapper); exceeding amount must cover user liability being rebalanced; fresh oracle report required

### A dangerous or suspicious action is proposed on TimelockController

A potentially malicious or erroneous action is queued in the timelock, such as minting stETH shares on the vault bypassing wrapper, unauthorized vault disconnection, or malicious contract upgrades. Creates time window for detection and response before execution.

**Conditions**: Compromised admin keys, malicious proposer, or governance capture; proposal submitted and queued with timelock delay.

**Expected probability**: Very low; depends on key management security and governance integrity.

**Loops**:
- Emergency response to dangerous proposal
  - **Detection**: Monitoring of timelock events; off-chain alerting systems; community governance review
  - **Actors and incentives**: Emergency committee (has pause powers for specific features); Lido governance (can cancel proposals); timelock executor committee (validates actions before execution)
  - **Preconditions**: Detection must occur before timelock delay expires; emergency committee has appropriate pause roles; governance has cancellation rights

### Critical yet solvable vulnarability found in Wrapper contracts

Security vulnerability discovered in StvPool, StvStETHPool, WithdrawalQueue, or related wrapper contracts that requires immediate response but has a known fix. Emergency pause may be needed while upgrade is prepared.

**Conditions**: Security audit finding, white-hat disclosure, or internal discovery of exploitable vulnerability; immunefi report; Lido security monitoring.

**Expected probability**: Low; depends on code quality, audit thoroughness, and security practices.

**Loops**:
- Emergency response and upgrade
  - **Detection**: Occasional self-review, immunefi security report, Lido monitoring, audit findings
  - **Actors and incentives**: Lido contributors (prepare fix); Emergency committee (pause affected features); Timelock (execute upgrade after delay)
  - **Actions**:
    - Emergency committee: pauses required features using `DEPOSITS_PAUSE_ROLE` or `MINTING_PAUSE_ROLE`
    - Developers: prepare upgrade implementation and verify fix
    - Governance: approve upgrade through timelock process
    - TODO: complete upgrade flow details

### Critical yet solvable vulnerability found in Vault contracts

Security vulnerability discovered in StakingVault, Dashboard, or related Lido V3 vault contracts. Requires coordination with Lido core team for fix.

**Conditions**: Security audit finding, disclosure, or monitoring detection of vault contract vulnerability.

**Expected probability**: Very low; depends on Lido core code quality and audit coverage.

**Loops**: TODO

### Critical yet solvable vulnerability found in Lido Core

Security vulnerability in core Lido contracts (VaultHub, Lido, stETH, etc.) that affects the wrapper system. Requires Lido DAO governance response.

**Conditions**: Core protocol vulnerability discovered through audits, white-hat disclosure, or monitoring.

**Expected probability**: Very low; Lido core is heavily audited and battle-tested.

**Loops**: TODO
- How is the executor committee incentivized to handle proper and improper proposed timelocked actions?

### Lido oracle reports missed for a few days

TODO

**Conditions**: TODO

**Expected probability**: TODO

**Loops**: TODO

### Force rebalance of users done by MEV bots

Multiple users breach force rebalance threshold (`is_healthy_user` = false) but no one calls permissionless `forceRebalance()`. System has liquidity via `vault_assets` but liquidation mechanism fails due to bot infrastructure issues.

**Conditions**: Liquidation bot infrastructure failure, network issues preventing bot operations, economic non-viability (gas costs exceed profit), or deliberate DOS of bot operators.

**Expected probability**: Low with professional bot operators; increases during network congestion or if liquidation incentives insufficient.

**Loops**:
- Manual liquidation or bot recovery
  - **Detection**: Multiple `isHealthyOf(user)` return false; no `ForceRebalance` events emitted; monitoring alerts on unhealthy position accumulation
  - **Actors and incentives**: Any address (permissionless profit from liquidation); bot operators (restore infrastructure for ongoing fees); NO (prevent systemic risk escalation)
  - **Preconditions**: Fresh oracle report; sufficient `liability_pool_exceeding` or vault liquidity; someone manually calls `forceRebalance()` or bots restored

### Vault balance is zero when STV total supply is non-zero

### Unassigned liability cannot be cleared

`liability_pool_unassigned` stuck at non-zero value, blocking critical operations like voluntary disconnect. Vault lacks both liquid ETH for `rebalanceUnassignedLiabilityWithEther()` and available stETH for `rebalanceUnassignedLiability()`.

**Conditions**: Unassigned liability accumulated but vault has no liquid ETH and cannot mint more stETH; all vault ETH locked in validators; withdrawal demand prevents accumulation.

**Expected probability**: Low; requires combination of unassigned liability and complete vault illiquidity.

**Loops**:
- Forced validator exits or donation
  - **Detection**: `unassignedLiability()` non-zero; `rebalanceUnassignedLiabilityWithEther` reverts with insufficient balance; voluntary disconnect blocked
  - **Actors and incentives**: NO (exit validators to free liquidity for operational needs); Timelock/Admin (may need to donate stETH or ETH to clear liability)
  - **Preconditions**: NO must exit sufficient validators; ETH must return to vault; alternative: external donation of stETH or ETH to pool

### Rounding dust accumulates faster than expected

Systematic precision loss across many operations causes `liability_pool_unassigned` or stock discrepancies to grow beyond 1-wei-per-operation assumptions. Accumulates to economically significant amounts.

**Conditions**: High transaction volume with consistent rounding direction; precision errors in stETH/ETH conversions; multiple loss socialization events compounding rounding.

**Expected probability**: Low under normal volumes; increases with very high transaction counts or frequent loss events.

**Loops**:
- Periodic liability rebalancing
  - **Detection**: `unassignedLiability()` growing faster than expected; monitoring shows systematic increase; deviation from theoretical bounds
  - **Actors and incentives**: NO or Admin (periodic cleanup via `rebalanceUnassignedLiability()`); Governance (may need to adjust precision or add compensation mechanism)
  - **Preconditions**: Must monitor accumulation rate; periodic rebalancing required; may need to investigate systematic rounding bias


### Finalizer is potentially benefitial due to control of finalization timings

### Withdrawal queue exceeds remaining vault value

Total `wq_locked_stv` (in asset terms) exceeds `vault_total_value` plus pending withdrawals, creating over-subscribed queue. Not all requests can be finalized even with full vault liquidation.

**Conditions**: Mass withdrawal event combined with significant vault losses; users rush to exit creating bank-run scenario; vault value drops during queue processing.

**Expected probability**: Very low; requires extreme combination of mass withdrawals and vault value collapse.

**Loops**:
- Proportional finalization or governance intervention
  - **Detection**: Sum of pending request assets > `vault_total_value`; finalization impossible for late requests; monitoring shows queue insolvency
  - **Actors and incentives**: Governance (decide on proportional distribution or loss allocation); Users (first-in-first-out creates race incentive)
  - **Preconditions**: Requires governance decision on fair distribution; may need emergency mechanism for proportional claims; early requests may finalize fully while late requests take losses

### STV supply near zero

`stv_supply` approaches `VAULT_HUB.CONNECT_DEPOSIT()` minimum (only initial pool STV remains). Affects precision, rounding, and per-user calculations become unstable.

**Conditions**: Mass withdrawals drain pool to near-empty state; only dust positions or connect deposit remains; no new deposits.

**Expected probability**: Low; requires near-complete pool exodus without new entrants.

**Loops**:
- Pool restart or wind-down
  - **Detection**: `totalSupply()` near minimum; `totalAssets()` near connect deposit value; operations fail due to precision issues
  - **Actors and incentives**: NO (decide whether to attract new deposits or wind down); New depositors (opportunity to enter at favorable rates if others exited)
  - **Preconditions**: Pool still operational but minimal utility; may need minimum deposit requirements; governance decision on pool continuation

### Single user minting maximum capacity

One user's `liability_user[user]` captures entire pool minting capacity. `total_pool_minted_steth_shares` approaches maximum allowed by reserve ratios. No capacity remains for other users.

**Conditions**: Large sophisticated user mints to full capacity; other users small or absent; pool concentration risk.

**Expected probability**: Low in public pools; higher in allowlisted or strategy pools with limited participants.

**Loops**:
- Capacity becomes available through deposits or burning
  - **Detection**: `remainingMintingCapacitySharesOf(otherUsers)` returns zero; single user holds majority of `total_pool_minted_steth_shares`
  - **Actors and incentives**: Large user (reduce liability by burning to free capacity); New depositors (increase pool assets to expand total capacity); Other users (wait for capacity)
  - **Preconditions**: Large user must burn stETH or new deposits must occur; no enforced capacity limits per user

### MEV sandwich attack within vault / Lido oracle period

Attacker sandwiches user operations (deposit, withdrawal request) within same oracle reporting period, exploiting STV rate staleness before oracle updates. Front-runs victim then back-runs after their transaction affects pool state.

**Conditions**: MEV bot monitors mempool; identifies profitable sandwich opportunities; oracle report frequency creates exploitable windows; sufficient liquidity for attack.

**Expected probability**: Low if oracle reports frequent; increases with longer reporting periods or high pool volatility.

**Loops**:
- Oracle frequency or slippage protection
  - **Detection**: Suspicious transaction patterns (deposit → user operation → withdrawal in short sequence); monitoring shows correlated operations; users report unexpected rates
  - **Actors and incentives**: MEV searchers (profit from rate arbitrage); Protocol developers (may add slippage checks or rate limits); Users (cannot directly mitigate)
  - **Preconditions**: Requires user-level slippage parameters or more frequent oracle updates; monitoring can detect but not prevent

### Donation attack on STV rate

Attacker sends ETH directly to vault via `receive()` or `fund()` to manipulate STV rate (`assets_pool_total / stv_supply`). First user after donation gains at expense of attacker, but can cause accounting confusion.

**Conditions**: Attacker directly transfers ETH to vault outside normal deposit flow; attempts to manipulate exchange rate for follow-on attack or create MEV opportunity.

**Expected probability**: Low; economically inefficient as attacker loses donated value. More likely as grief attack than profit mechanism.

**Loops**:
- Donation benefits existing holders
  - **Detection**: Vault balance increase without `Deposited` events; `totalAssets()` jumps without corresponding STV mint
  - **Actors and incentives**: Existing STV holders (benefit proportionally from donation); Next depositor (receives favorable rate); Attacker (loses donation amount)
  - **Preconditions**: Donations redistribute value to existing holders; economically self-defeating for attacker; no recovery mechanism needed

### Spike in stETH share to ETH rate (large stETH rebase)

System assumes relatively stable stETH rate changes, but catastrophic rebase (>10% negative) from consensus layer failures violates assumptions. May break reserve ratio calculations and force widespread liquidations.

**Conditions**: Major consensus layer event causing massive stETH slashing; Lido core pool suffers catastrophic losses; correlated validator failures across network.

**Expected probability**: Very low; would require unprecedented Ethereum consensus layer failure or Lido core compromise.

**Loops**:
- Emergency pause and governance response
  - **Detection**: stETH rate drops >10%; mass position undercollateralization; system-wide health check failures
  - **Actors and incentives**: Emergency committee (pause operations immediately); Governance (coordinate with Lido DAO on loss allocation); Users (cannot mitigate)
  - **Preconditions**: Requires emergency governance coordination; may need loss socialization beyond normal limits; potential system migration or compensation mechanism

### Vault external rebalance cascades

Repeated VaultHub rebalances (bypassing wrapper) cause `liability_pool_exceeding` to grow continuously. Multiple rebalancing events create spiral where exceeding keeps accumulating faster than being consumed.

**Conditions**: Vault repeatedly hits force rebalance threshold due to performance issues; each oracle report triggers automatic rebalance; exceeding minted stETH not consumed quickly enough.

**Expected probability**: Low; requires persistent vault underperformance triggering multiple consecutive rebalances.

**Loops**:
- User force rebalances consume exceeding
  - **Detection**: `exceedingMintedStethShares()` growing across multiple oracle periods; repeated `VaultRebalanced` events; `liability_pool_exceeding` trending upward
  - **Actors and incentives**: Any address (permissionlessly call `forceRebalance()` to consume exceeding and liquidate unhealthy users); NO (improve validator performance to stop rebalance triggers)
  - **Preconditions**: Unhealthy users must exist to consume exceeding; fresh oracle reports; NO must address root cause of underperformance

### Disconnect blocked permanently

Voluntary disconnect via `Dashboard.voluntaryDisconnect()` permanently blocked because `liability_pool_unassigned` cannot be cleared to zero. Vault cannot exit Lido system cleanly.

**Conditions**: Unassigned liability accumulated and vault lacks resources to clear it; no liquid ETH for `rebalanceUnassignedLiabilityWithEther`; no available stETH capacity for `rebalanceUnassignedLiability`.

**Expected probability**: Low; requires specific combination of unassigned liability and resource constraints.

**Loops**:
- Force clearing or governance override
  - **Detection**: `voluntaryDisconnect()` reverts; `unassignedLiability() > 0`; vault needs to exit but blocked
  - **Actors and incentives**: NO (must clear liability before exit); Governance (may need emergency disconnect mechanism); Timelock (coordinate orderly exit)
  - **Preconditions**: Must exit validators to free liquidity; may require governance to donate funds or implement forced disconnect; alternative: write off unassigned liability via governance action

### Withdrawal Queue blocked by excessive loss

A single withdrawal request in the queue requires rebalancing a loss that exceeds the configured `maxLossSocializationBP`. This causes the `finalize()` function to revert for the entire batch, potentially blocking the queue if the problematic request is at the head or included in all attempted batches.

**Conditions**:
- Pool supports rebalancing (`IS_REBALANCING_SUPPORTED` is true).
- A withdrawal request becomes significantly undercollateralized (e.g., due to sharp asset devaluation or share rate changes) while waiting in the queue.
- The calculated loss portion exceeds `maxLossSocializationBP` (default 0).

**Expected probability**: Low; requires high variance events and a restrictive `maxLossSocializationBP`.

**Loops**:
- Governance intervention
  - **Detection**: `finalize()` calls revert with `ExcessiveLossSocialization`; queue processing halts.
  - **Actors and incentives**: Node Operator (restore operations); Governance (allow loss socialization).
  - **Preconditions**: Governance must call `setMaxLossSocializationBP` to a higher value to allow the loss to be socialized, or manually fund the pool to cover the loss.

### GGV Strategy Exit Stuck

Users request to exit their position from the GGV strategy, but the exit is never finalized on the GGV side (Boring Queue) or the strategy cannot verify it. The Wrapper lacks a `finalizeRequestExit` implementation for GGV, relying on the GGV system to process exits or the user to handle the unwound assets if they are just returned.

**Conditions**:
- User calls `requestExitByWsteth`.
- GGV "Boring Queue" fails to process the request, or the solver doesn't pick it up.
- Code shows `finalizeRequestExit` reverts with `NotImplemented`.

**Expected probability**: Low (depends on GGV reliability).

**Loops**:
- Manual intervention / Waiting
  - **Detection**: User assets remain in GGV strategy/queue; `finalizeRequestExit` cannot be called.
  - **Actors and incentives**: User ( wants funds); GGV Governance/Solver (operational responsibility).
  - **Preconditions**: GGV system must process the exit. If GGV is permanently stuck, there is no direct recovery path in the Wrapper strategy contract for that specific request ID without GGV cooperation.
