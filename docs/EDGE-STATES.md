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
