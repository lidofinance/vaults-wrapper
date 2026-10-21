# Integration Test Plan

## Maintenance Guide
This document tracks the coverage of integration tests against the planned scenarios.

1. **Status Updates**: Mark items as `[x]` when a test is implemented.
2. **Test Mapping**: Explicitly list the test function(s) that verify the scenario.
   - Indent the test name under the checklist item.
   - Use the format: `  - ContractName.test_function_name`
3. **Coverage**: Metrics are derived from the number of `[x]` items and unique mapped test functions.

## Coverage Metrics
- **Plan Coverage:** 43.1% (132/306 scenarios implemented)
- **Test Utilization:** 100% (70/70 active integration tests mapped to plan)

## 1. User Scenarios - Depositor

### 1.1 Deposits
- [x] Deposit ETH via `depositETH()`
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_no_rewards`
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [ ] Deposit ETH via `receive()` fallback
- [ ] Deposit with referral tracking
- [x] Deposit to different recipient
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [x] Multiple deposits same user
  - `StvStETHPoolTest.test_depositETH_with_max_mintable_amount`
- [x] Multiple users deposit simultaneously
  - `StvStETHPoolTest.test_two_users_mint_full_in_two_steps`
- [x] First deposit to empty pool
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [ ] Deposit at max vault capacity
- [x] Deposit when allowlist enabled (allowed/not allowed)
  - `GGVTest.test_revert_if_user_is_not_allowlisted`
- [x] Deposit with stale oracle report → revert
  - `ReportFreshnessTest.test_deposit_requires_fresh_report`
- [x] Deposit when paused → revert
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [ ] Deposit zero ETH → revert

### 1.2 Deposit + Mint (StvStETHPool)
- [x] `depositETHAndMintStethShares()` - full mint
  - `StvStETHPoolTest.test_depositETH_with_max_mintable_amount`
- [ ] `depositETHAndMintStethShares()` - partial mint
- [ ] `depositETHAndMintWsteth()` - full mint
- [ ] Deposit + mint exceeds capacity → revert
- [x] Deposit + mint when minting paused → revert
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`

### 1.3 Standalone Minting
- [x] `mintStethShares()` after previous deposit
  - `StvStETHPoolTest.test_single_user_mints_full_in_two_steps`
- [ ] `mintWsteth()` after previous deposit
- [x] Mint to full capacity
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [ ] Mint exceeds remaining capacity → revert
- [ ] Mint when no STV balance → revert
- [ ] Mint zero → revert

### 1.4 Burning
- [x] `burnStethShares()` - partial
  - `StvStETHPoolTest.test_user_withdraws_without_burning`
- [ ] `burnStethShares()` - full liability
- [x] `burnWsteth()` - partial
  - `GGVTest.test_positive_wsteth_rebase_flow`
- [ ] `burnWsteth()` - full liability
- [ ] Burn more than minted → revert
- [ ] Burn zero → revert
- [x] Burn to unlock transfer ability
  - `StvStETHPoolTest.test_burning_shares_after_vault_loss_allows_transfer`

### 1.5 Withdrawals
- [x] Request withdrawal - full balance
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_no_rewards`
- [x] Request withdrawal - partial balance
  - `StvPoolTest.test_partial_withdrawal_pro_rata_claim`
- [x] Request with stETH liability (StvStETHPool)
  - `StvStETHPoolTest.test_user_withdraws_without_burning`
- [x] Request minimum amount (0.001 ETH)
  - `StvStETHPoolTest.test_user_withdraws_without_burning`
- [ ] Request maximum amount (10,000 ETH)
- [x] Batch withdrawal requests
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [x] Request when paused → revert
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Request below minimum → revert
  - `StvStETHPoolTest.test_user_withdraws_without_burning`
- [ ] Request above maximum → revert
- [x] Request with stale report → revert
  - `ReportFreshnessTest.test_withdrawals_requires_fresh_report`
- [x] Request exceeds STV balance → revert
  - `StvStETHPoolTest.test_user_withdraws_without_burning`

### 1.6 Claims
- [x] Claim single finalized request
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_no_rewards`
- [x] Claim batch requests
  - `StvPoolTest.test_partial_withdrawal_pro_rata_claim`
- [ ] Claim with checkpoint hint
- [ ] Claim without hint (search)
- [ ] Claim to different recipient
- [x] Claim unfinalized → revert
  - `StvPoolTest.test_claim_before_finalization_reverts_then_succeeds_after_finalize`
- [ ] Claim already claimed → revert
- [ ] Claim non-existent request → revert
- [ ] Claim other user's request → revert

### 1.7 Transfers
- [x] Transfer STV - standard ERC20
  - `StvStETHPoolTest.test_user_with_no_minted_shares_can_transfer_freely`
- [x] Transfer STV when has minted shares → revert (insufficient collateral)
  - `StvStETHPoolTest.test_transfer_reverts_when_insufficient_collateral_for_minted_shares`
- [x] `transferWithLiability()` - exact minimum STV
  - `StvStETHPoolTest.test_transferWithLiability_maintains_sender_reserve_ratio`
- [x] `transferWithLiability()` - overpay STV
  - `StvStETHPoolTest.test_transferWithLiability_can_overpay_stv`
- [x] `transferWithLiability()` - full STV + full liability
  - `StvStETHPoolTest.test_transferWithLiability_all_stv_and_liability`
- [x] Transfer when bad debt exists → revert
  - `StvStETHPoolTest.test_after_vault_loss_user_below_reserve_ratio`
- [ ] Transfer when unassigned liability exists → revert
- [ ] Transfer zero STV (ERC20 compliant)
- [x] Transfer exceeds balance → revert
  - `StvStETHPoolTest.test_transferWithLiability_reverts_when_stv_insufficient_for_liability`
- [x] Transfer excess STV without liability
  - `StvStETHPoolTest.test_after_vault_gains_can_transfer_excess_without_liability`

### 1.8 Rebalance (Permissionless)
- [ ] `rebalanceUnassignedLiability()` - partial
- [ ] `rebalanceUnassignedLiability()` - full
- [ ] `rebalanceUnassignedLiabilityWithEther()` - exact amount
- [ ] `rebalanceUnassignedLiabilityWithEther()` - overpay (refund)
- [ ] Rebalance when no unassigned liability → revert

### 1.9 Force Rebalance
- [x] `forceRebalance()` unhealthy account
  - `ReportFreshnessTest.test_force_rebalance_requires_fresh_report`
- [ ] Force rebalance healthy account → revert
- [ ] Force rebalance reduces user to zero STV
- [ ] Force rebalance with insufficient collateral → partial

---

## 2. User Scenarios - Strategy User (GGV)

### 2.1 Supply
- [x] `supply()` - deposit + mint + supply to GGV
  - `GGVTest.test_rebase_scenario`
- [ ] Supply with referral
- [ ] Supply when paused → revert
- [x] Supply non-allowlisted user → revert
  - `GGVTest.test_revert_if_user_is_not_allowlisted`

### 2.2 Exit
- [x] `requestExitByWsteth()` - partial GGV position
  - `GGVTest.test_rebase_scenario`
- [ ] `requestExitByWsteth()` - full GGV position
- [ ] Exit more than GGV balance → revert

### 2.3 GGV Queue Management
- [ ] Cancel on-chain withdrawal
- [ ] Replace on-chain withdrawal
- [ ] Cancel/replace other user's request → revert

### 2.4 Recovery
- [x] `recoverERC20()` - recover tokens from forwarder
  - `GGVTest.test_positive_wsteth_rebase_flow`
- [ ] `recoverERC20()` - recover wstETH dust
- [ ] Recover other user's tokens → revert
- [x] Recover ERC20/ETH from Dashboard
  - `DashboardTest.test_Dashboard_CanRecoverERC20`
- [x] Collect ERC20 from Vault
  - `DashboardTest.test_Dashboard_CanCollectERC20FromVault`

### 2.5 Burn via Strategy
- [x] `burnWsteth()` through strategy
  - `GGVTest.test_rebase_scenario`

---

## 3. User Scenarios - Admin/Governance

### 3.1 Pause/Resume
- [x] Pause/resume deposits
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Pause/resume withdrawals
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [ ] Pause/resume finalization
- [x] Pause/resume minting
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [ ] Pause/resume strategy supply
- [x] Wrong role → revert
  - `DashboardRolesTest.test_DashboardRoles_BurnRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_FeeExemptRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_FundRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_MintRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_NodeOperatorManagerIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_ProveUnknownValidatorRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_RebalanceRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_TimelockIsAdmin`
  - `DashboardRolesTest.test_DashboardRoles_UnguaranteedRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_VoluntaryDisconnectRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_WithdrawalRoleIsAssigned`

### 3.2 Finalization
- [x] Finalize single request
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_no_rewards`
- [x] Finalize batch (partial queue)
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [x] Finalize batch (full queue)
  - `StvPoolTest.test_partial_withdrawal_pro_rata_claim`
- [x] Finalize stops at insufficient liquidity
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [x] Finalize resumes after funding
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [ ] Finalize with gas cost coverage
- [ ] Set gas cost coverage
- [ ] Set coverage > max → revert
- [x] Finalize when paused → revert
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Finalize with stale report → revert
  - `ReportFreshnessTest.test_withdrawals_finalization_requires_fresh_report`
- [ ] Finalize no pending requests → revert

### 3.3 Loss Socialization
- [x] `forceRebalanceAndSocializeLoss()` - within limit
  - `ReportFreshnessTest.test_force_rebalance_with_socialization_requires_fresh_report`
- [ ] Socialize loss exceeds max → revert
- [x] `setMaxLossSocializationBP()`
  - `ReportFreshnessTest.setUp`
- [ ] Wrong role → revert

### 3.4 Allowlist Management
- [x] Add to allowlist
  - `FactoryIntegrationTest.test_createPool_with_strategy_deploys_strategy_and_allowlists_it`
  - `FactoryIntegrationTest.test_custom_deployment_with_allowlist`
- [ ] Remove from allowlist
- [x] Query allowlist
  - `FactoryIntegrationTest.test_createPool_with_strategy_deploys_strategy_and_allowlists_it`
- [ ] Wrong role → revert

### 3.5 Distributor Management
- [ ] Add token
- [ ] Set merkle root
- [ ] Update merkle root
- [ ] Wrong role → revert

### 3.6 Parameter Updates
- [x] `syncVaultParameters()` after tier change
  - `DashboardTest.test_Dashboard_CanSyncTier`
- [ ] `syncVaultParameters()` no change
- [x] Set confirm expiry
  - `DashboardTest.test_Dashboard_CanSetConfirmExpiry`
- [x] Correct settled growth
  - `DashboardTest.test_Dashboard_CanCorrectSettledGrowth`
- [x] Change tier
  - `DashboardTest.test_Dashboard_CanChangeTier`
- [x] Update share limit
  - `DashboardTest.test_Dashboard_CanUpdateShareLimit`

### 3.7 Fee Management
- [x] Set fee rate
  - `DashboardTest.test_Dashboard_CanSetFeeRate`
- [x] Set fee recipient
  - `DashboardTest.test_Dashboard_CanSetFeeRecipient`
- [x] Add fee exemption
  - `DashboardTest.test_Dashboard_CanAddFeeExemption`
- [x] Disburse fees
  - `DashboardTest.test_Dashboard_CanDisburseAbnormallyHighFee`

### 3.8 Timelock Operations
- [ ] Schedule operation
- [ ] Execute operation
- [ ] Cancel operation
- [ ] Update delay
- [ ] Upgrade contracts

---

## 4. User Scenarios - Reward Claimant

### 4.1 Merkle Claims
- [ ] Claim with valid proof
- [ ] Claim partial (incremental)
- [ ] Claim multiple tokens
- [ ] Claim invalid proof → revert
- [ ] Claim exceeds cumulative → revert
- [ ] Claim zero → revert

---

## 5. System Events - Oracle Reports

### 5.1 Fresh Report Effects
- [x] Deposit allowed after fresh report
  - `ReportFreshnessTest.test_deposit_requires_fresh_report`
- [x] Withdrawal request allowed after fresh report
  - `ReportFreshnessTest.test_withdrawals_requires_fresh_report`
- [x] Finalization allowed after fresh report
  - `ReportFreshnessTest.test_withdrawals_finalization_requires_fresh_report`
- [x] Minting allowed after fresh report
  - `ReportFreshnessTest.test_minting_requires_fresh_report`

### 5.2 Stale Report Effects
- [x] Operations blocked with stale report
  - `ReportFreshnessTest.test_deposit_requires_fresh_report`
- [ ] Requests created after report not finalizable

---

## 6. System Events - stETH Rebases

### 6.1 Positive Rebase
- [x] Assets increase, minting capacity increases
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [x] User can mint additional shares
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [x] Withdrawal gets more ETH
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report_before_request`

### 6.2 Negative Rebase
- [x] Assets decrease, minting capacity decreases
  - `StvStETHPoolTest.test_vault_underperforms`
- [x] Positions become undercollateralized
  - `StvStETHPoolTest.test_vault_underperforms`
- [x] Force rebalance threshold breached
  - `ReportFreshnessTest.test_force_rebalance_requires_fresh_report`
- [x] Transfers blocked for undercollateralized users
  - `StvStETHPoolTest.test_after_vault_loss_user_below_reserve_ratio`
- [x] Burning restores transfer ability
  - `StvStETHPoolTest.test_burning_shares_after_vault_loss_allows_transfer`

### 6.3 Rebase During Operations
#### 6.3.1 Positive Rebase
- [ ] Rebase between deposit and mint
- [ ] Rebase between request and finalization
- [ ] Rebase between finalization and claim
#### 6.3.2 Negative Rebase
- [ ] Rebase between deposit and mint
- [ ] Rebase between request and finalization
- [ ] Rebase between finalization and claim

---

## 7. System Events - Vault Value Changes

### 7.1 Vault Gains (Rewards)
- [x] `totalAssets()` increases
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [x] STV value increases
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [x] Withdrawal gets more ETH
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [ ] Exceeding minted stETH may occur

### 7.2 Vault Losses
- [ ] Validator slashing
- [x] `totalAssets()` decreases
  - `StvStETHPoolTest.test_vault_underperforms`
- [x] Bad debt scenario (value < liability)
  - `StvStETHPoolTest.test_after_vault_loss_user_below_reserve_ratio`
- [x] Transfers blocked during bad debt
  - `StvStETHPoolTest.test_after_vault_loss_user_below_reserve_ratio`
- [x] Unassigned liability created
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Rebalance needed
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`

### 7.3 Available Balance Changes
- [ ] Validator exits increase available balance
- [ ] Finalization possible after validator exit
- [ ] Insufficient available balance blocks finalization

---

## 8. System Events - External Vault Operations

### 8.1 External Rebalance
- [ ] Dashboard rebalanced outside wrapper
- [ ] `totalExceedingMintedStethShares()` > 0
- [ ] Exceeding shares used during finalization

### 8.2 VaultHub Parameter Changes
- [ ] Tier upgrade → sync needed
- [ ] Reserve ratio change → affects minting
- [ ] Force rebalance threshold change

### 8.3 Forced Rebalance by VaultHub
- [ ] Vault becomes unhealthy
- [ ] External force rebalance creates exceeding

---

## 9. System Events - Disconnect Flow

### 9.1 Voluntary Disconnect Initiation
- [x] Disconnect initiated → pending state
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
  - `DisconnectTest.test_Disconnect_InitialState`
  - `DashboardTest.test_Dashboard_CanVoluntaryDisconnect`
- [x] Minting blocked during pending
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Deposits continue during pending
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`

### 9.2 Liability Repayment
- [x] Repay all minted shares
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Repay unassigned liability
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Zero liability required for completion
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`

### 9.3 Disconnect Completion
- [x] Oracle report finalizes disconnect
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [x] Vault ownership transferred
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
- [ ] Reconnection possible

---

## 10. Multi-Actor Scenarios

### 10.1 Concurrent Deposits
- [ ] Multiple users deposit same block
- [ ] Large deposit + small deposit ordering

### 10.2 Concurrent Withdrawals
- [ ] Multiple requests same block
- [ ] First-in-first-out finalization order
- [ ] Partial finalization (some funded, some not)

### 10.3 Deposit/Withdrawal Race
- [ ] Deposit during finalization
- [ ] Withdrawal request during deposit

### 10.4 Rebase Impact on Multiple Users
- [ ] Positive rebase benefits all proportionally
- [ ] Negative rebase affects all proportionally
- [ ] User minting after rebase

### 10.5 Force Rebalance Interactions
- [ ] Force rebalance during pending withdrawal
- [ ] Multiple users force rebalanced
- [ ] Force rebalance + transfer attempt

---

## 11. Edge Cases - Amounts

### 11.1 Zero Handling
- [ ] Deposit 0 → revert
- [ ] Mint 0 → revert
- [ ] Burn 0 → revert
- [ ] Transfer 0 → success
- [ ] Request 0 → revert
- [ ] Finalize 0 → revert

### 11.2 Minimum Values
- [x] Minimum withdrawal (0.001 ETH)
  - `StvStETHPoolTest.test_user_withdraws_without_burning`
- [ ] Minimum delay time (1 hour)
- [ ] Single wei operations

### 11.3 Maximum Values
- [ ] Maximum withdrawal (10,000 ETH)
- [ ] Maximum gas coverage (0.0005 ETH)
- [ ] Large deposits near vault capacity
- [ ] uint256 overflow scenarios

### 11.4 Dust Handling
- [ ] Rounding dust in stETH conversions
- [ ] wstETH wrap/unwrap dust
- [ ] Remaining wei after full withdrawal

---

## 12. Edge Cases - Timing

### 12.1 Request Timing
- [ ] Request at exact MIN_WITHDRAWAL_DELAY boundary
- [ ] Request just before oracle report
- [ ] Request just after oracle report

### 12.2 Finalization Timing
- [ ] Finalize at exact delay boundary
- [ ] Finalize request created after report → skip
- [ ] Batch with mixed eligibility

### 12.3 Factory Timing
- [ ] `createPoolFinish()` at deadline boundary
- [ ] `createPoolFinish()` after deadline → revert

---

## 13. Edge Cases - State Boundaries

### 13.1 Empty Pool
- [x] First deposit
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [ ] All users withdraw (except connect deposit)
- [ ] Operations on near-empty pool

### 13.2 Full Minting
- [x] Mint to exact capacity
  - `StvStETHPoolTest.test_single_user_mints_full_in_one_step`
- [ ] One wei over capacity → revert
- [ ] Reserve ratio at boundary

### 13.3 Reserve Ratio Boundaries
- [ ] Exactly at forced rebalance threshold
- [ ] One wei below threshold
- [ ] After sync changes threshold

---

## 14. Edge Cases - Rounding

### 14.1 STV Conversions
- [ ] Assets to STV (floor)
- [ ] STV to assets (floor)
- [ ] Preview functions accuracy

### 14.2 stETH Conversions
- [ ] Shares to ETH
- [ ] ETH to shares
- [ ] Round up vs round down scenarios

### 14.3 Rate Calculations
- [ ] Cumulative rate accuracy
- [ ] Checkpoint rate precision
- [ ] E27/E36 precision handling

---

## 15. Edge Cases - Finalization

### 15.1 Partial Finalization
- [x] Stops at insufficient balance
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [ ] Stops at insufficient withdrawable value
- [x] Resumes after funding
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [ ] Rate consistency across batches

### 15.2 Rate Changes
- [x] Positive rate change (rewards)
  - `StvPoolTest.test_happy_path_deposit_request_finalize_claim_with_rewards_report`
- [x] Negative rate change (loss) → revert without socialization
  - `StvPoolTest.test_withdrawal_request_finalized_after_reward_and_loss_reports`
  - `StvPoolTest.test_finalize_reverts_after_loss_more_than_deposit`
- [x] Loss within socialization limit
  - `ReportFreshnessTest.test_force_rebalance_with_socialization_requires_fresh_report`

### 15.3 Checkpoint Hints
- [ ] Correct hint → fast lookup
- [ ] Incorrect hint → search succeeds
- [ ] Hint out of range → search

---

## 16. Invariant Tests

### 16.1 Pool Invariants
- [ ] `totalSupply()` denominated in 1e27
- [ ] `totalAssets() = totalNominalAssets() - unassignedLiability + exceedingMinted`
- [ ] Exactly one of unassigned/exceeding can be > 0
- [ ] No transfers when unassigned > 0 or bad debt

### 16.2 Minting Invariants
- [ ] User: `mintedShares <= calcSharesForAssets(assets)`
- [ ] Pool: `totalMinted <= totalLiability + exceeding`
- [ ] Reserve ratio maintained

### 16.3 Withdrawal Queue Invariants
- [ ] `lastRequestId >= lastFinalizedRequestId`
- [ ] Request IDs monotonic
- [ ] Cumulative values monotonic
- [ ] `totalLockedAssets <= balance`

### 16.4 Economic Invariants
- [ ] STV rate never decreases (without loss socialization)
- [ ] Gas coverage <= maximum
- [ ] Loss socialization <= configured maximum

---

## 17. Security Scenarios

### 17.1 Access Control
- [x] All role-gated functions tested
  - `DashboardRolesTest.test_DashboardRoles_BurnRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_FeeExemptRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_FundRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_MintRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_NodeOperatorManagerIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_ProveUnknownValidatorRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_RebalanceRoleIsAssigned`
  - `DashboardRolesTest.test_DashboardRoles_TimelockIsAdmin`
  - `DashboardRolesTest.test_DashboardRoles_UnguaranteedRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_VoluntaryDisconnectRoleIsNotAssigned`
  - `DashboardRolesTest.test_DashboardRoles_WithdrawalRoleIsAssigned`
  - `DashboardTest.test_Dashboard_RolesAreSetCorrectly`
- [x] Role inheritance correct
  - `DashboardRolesTest.test_DashboardRoles_TimelockIsAdmin`
- [x] Admin cannot bypass roles
  - `DashboardRolesTest.test_DashboardRoles_TimelockIsAdmin`

### 17.2 Reentrancy
- [ ] Claim withdrawal reentrancy
- [ ] Strategy call reentrancy
- [ ] Distributor claim reentrancy

### 17.3 Front-running
- [ ] Deposit front-running (affects STV rate?)
- [ ] Withdrawal request ordering
- [ ] Force rebalance MEV

### 17.4 Manipulation
- [ ] Donation attacks on rates
- [ ] Price oracle manipulation via rebase
- [ ] Checkpoint manipulation

---

## 18. Factory Deployment

### 18.1 StvPool Deployment
- [x] Two-phase deployment success
  - `FactoryIntegrationTest.test_createPool_without_minting_configures_roles`
  - `FactoryIntegrationTest.test_emits_pool_creation_started_event`
  - `FactoryIntegrationTest.test_initial_state`
- [x] Role configuration correct
  - `FactoryIntegrationTest.test_initial_acl_configuration`
- [x] Proxy ownership correct
  - `FactoryIntegrationTest.test_initial_acl_configuration`

### 18.2 StvStETHPool Deployment
- [x] Mint/burn roles granted
  - `FactoryIntegrationTest.test_createPool_with_minting_grants_mint_and_burn_roles`
- [x] Reserve ratio initialized
  - `FactoryIntegrationTest.test_initial_acl_configuration`
- [x] Minting parameters correct
  - `FactoryIntegrationTest.test_initial_acl_configuration`

### 18.3 Strategy Pool Deployment
- [x] Strategy deployed
  - `FactoryIntegrationTest.test_createPool_with_strategy_deploys_strategy_and_allowlists_it`
- [x] Strategy allowlisted
  - `FactoryIntegrationTest.test_createPool_with_strategy_deploys_strategy_and_allowlists_it`
  - `FactoryIntegrationTest.test_custom_deployment_with_allowlist`
- [x] Strategy roles correct
  - `FactoryIntegrationTest.test_initial_acl_configuration`

### 18.4 Security Validations
- [x] Modified intermediate → revert
  - `FactoryIntegrationTest.test_createPoolFinish_reverts_with_modified_intermediate`
- [x] Modified config → revert
  - `FactoryIntegrationTest.test_createPoolFinish_reverts_with_modified_config`
- [x] Different sender → revert
  - `FactoryIntegrationTest.test_createPoolFinish_reverts_with_different_sender`
- [x] Double finish → revert
  - `FactoryIntegrationTest.test_createPoolFinish_reverts_when_called_twice`
- [x] Insufficient connect deposit → revert
  - `FactoryIntegrationTest.test_createPoolFinish_reverts_without_exact_connect_deposit`

---

## 19. GGV Strategy Specifics

### 19.1 Forwarder Management
- [ ] Forwarder created on first supply
- [ ] Forwarder reused on subsequent supplies
- [ ] Forwarder isolation between users

### 19.2 GGV Integration
- [x] Deposit to GGV vault
  - `GGVTest.test_rebase_scenario`
- [x] Withdrawal queue interaction
  - `GGVTest.test_rebase_scenario`
- [x] On-chain solver processingj
  - `GGVTest.test_rebase_scenario`
- [ ] Cancel GGV withdrawal request

### 19.3 Rebase Scenarios
- [x] Positive GGV yield
  - `GGVTest.test_rebase_scenario`
- [ ] wstETH surplus after claim

---

## 20. Cross-System Scenarios

### 20.1 Lido Core Events
- [x] stETH rebase handling
  - `GGVTest.test_rebase_scenario`
- [ ] wstETH exchange rate changes

### 20.2 VaultHub Events
- [x] Oracle report propagation
  - `ReportFreshnessTest.test_deposit_requires_fresh_report`
- [x] Tier parameter changes
  - `DashboardTest.test_Dashboard_CanChangeTier`
- [x] Force rebalance triggers
  - `ReportFreshnessTest.test_force_rebalance_requires_fresh_report`

### 20.3 Combined Events
- [x] Rebase + vault loss
  - `StvStETHPoolTest.test_vault_underperforms`
- [x] Oracle report + finalization batch
  - `StvPoolTest.test_finalize_batch_stops_then_completes_when_funded`
- [x] Disconnect + pending withdrawals
  - `DisconnectTest.test_Disconnect_VoluntaryDisconnect`
