# Security and Accounting Invariants

## Executive Summary

This document catalogs **32 fundamental invariants** that must be maintained across the Lido V3 Staking Vault Wrapper system. The system allows users to deposit ETH, receive STV tokens, and mint (borrow) stETH/wstETH against their collateral. These invariants span accounting integrity, solvency, security boundaries, and economic safety.

### Severity Distribution
- **Critical**: 11 invariants - System failure if violated
- **High**: 15 invariants - Significant security or economic risk
- **Medium**: 4 invariants - Acceptable within bounds
- **Low**: 2 invariants - Risk management, not security critical

### Categories
1. [Critical Accounting Invariants](#1-critical-accounting-invariants) - Core token and liability tracking
2. [Cross-Contract Invariants](#2-cross-contract-invariants) - Inter-contract state consistency
3. [Security Properties](#3-security-properties) - Protection mechanisms
4. [Economic Invariants](#4-economic-invariants) - Market manipulation resistance
5. [Solvency Properties](#5-solvency-properties) - System and user-level solvency
6. [Additional Fundamental Invariants](#6-additional-fundamental-invariants) - Edge cases and assumptions
7. [Attack Vectors & Mitigations](#7-attack-vectors--mitigations) - Known attack patterns

---

## 1. CRITICAL ACCOUNTING INVARIANTS

### 1.1 Total Supply Conservation

**Invariant**: STV total supply accurately represents proportional ownership of underlying assets.

**Mathematical Expression**:
```
∀ account: assetsOf(account) = balanceOf(account) * totalAssets() / totalSupply()

Σ(assetsOf(account)) = totalAssets()

STV_totalSupply * (totalAssets() / totalSupply()) = totalAssets()
```

**Code References**:
- `src/StvPool.sol:132` - `totalAssets()` calculation
- `src/StvPool.sol:149-154` - `_convertToStv()` with rounding
- `src/StvPool.sol:156-165` - `_convertToAssets()` and `_getAssetsShare()`

**Violation Scenarios**:
1. Rounding errors accumulate during deposit/withdrawal cycles exceeding 1 wei per operation
2. stETH rebase causes mismatch in asset calculations due to timing
3. Unassigned liability not properly tracked, inflating or deflating apparent assets

**Severity**: **CRITICAL**

**Impact**: Breaks fundamental proportional ownership model; some users receive more/less than fair share.

---

### 1.2 Liability Reconciliation

**Invariant**: Total vault liability equals sum of user liabilities plus unassigned liability.

**Mathematical Expression**:
```
vault_liability_shares = Σ(mintedStethShares[user]) + unassigned_liability_shares

vault_liability_shares ≥ 0

totalUnassignedLiabilityShares() = max(0, vault_liability_shares - totalMintedStethShares())
```

**Code References**:
- `src/StvPool.sol:240-252` - `totalLiabilityShares()` and `totalUnassignedLiabilityShares()`
- `src/StvStETHPool.sol:532-534` - Unassigned liability override
- `src/StvStETHPool.sol:266-277` - `totalMintedStethShares()` tracking
- `src/StvStETHPool.sol:50-54` - Storage struct with `mintedStethShares` mapping

**Violation Scenarios**:
1. External rebalancing on Dashboard bypassing wrapper, creating untracked liability changes
2. Lido governance operations directly on VaultHub altering vault liability
3. Bad debt socialization without proper accounting adjustments
4. Rounding errors in liability transfer operations

**Severity**: **CRITICAL**

**Impact**: System insolvency if unassigned liability grows unbounded; incorrect asset calculations.

---

### 1.3 Exceeding Minted stETH Exclusivity

**Invariant**: Only one of (exceeding minted stETH, unassigned liability) can be positive at any time.

**Mathematical Expression**:
```
exceedingMintedStethShares = max(0, totalMintedStethShares - vault_liability_shares)

unassignedLiabilityShares = max(0, vault_liability_shares - totalMintedStethShares)

exceedingMintedStethShares * unassignedLiabilityShares = 0  // Mutual exclusion

(exceedingMintedStethShares > 0) XOR (unassignedLiabilityShares > 0) OR (both = 0)
```

**Code References**:
- `src/StvStETHPool.sol:223-236` - `totalAssets()` accounting with conditional logic
- `src/StvStETHPool.sol:509-520` - `totalExceedingMintedStethShares()` calculation
- `src/StvStETHPool.sol:532-534` - `totalUnassignedLiabilityShares()` override

**Violation Scenarios**:
1. Race condition between wrapper operations and external rebalancing in same block
2. Integer overflow/underflow in liability calculations (prevented by SafeMath)
3. Logic error in conditional branches of `totalAssets()` calculation

**Severity**: **HIGH**

**Impact**: Double-counting of assets or liabilities; incorrect STV pricing.

---

### 1.4 Reserve Ratio Enforcement

**Invariant**: Every user with liability must maintain collateral above reserve ratio threshold.

**Mathematical Expression**:
```
∀ user with mintedStethShares[user] > 0:
  assetsOf(user) ≥ calcAssetsToLockForStethShares(mintedStethShares[user])

Where:
  calcAssetsToLockForStethShares(shares) =
    getPooledEthBySharesRoundUp(shares) * 10000 / (10000 - reserveRatioBP)

reserveRatioBP ∈ [vault_RR + RESERVE_RATIO_GAP_BP, 9999]

Minimum collateralization ratio = 10000 / (10000 - reserveRatioBP)
```

**Code References**:
- `src/StvStETHPool.sol:426-435` - `calcAssetsToLockForStethShares()`
- `src/StvStETHPool.sol:787-796` - `_update()` override with reserve check
- `src/StvStETHPool.sol:404-409` - `calcStethSharesToMintForAssets()` minting capacity
- `src/StvStETHPool.sol:454-456` - `reserveRatioBP()` getter

**Violation Scenarios**:
1. Negative stETH rebase reduces user assets below reserve requirement
2. Price oracle manipulation during volatile market conditions
3. User attempts transfer that would drop collateral below minimum
4. Large liability increase without corresponding collateral increase

**Severity**: **CRITICAL**

**Impact**: Systemic undercollateralization; risk of cascading liquidations and insolvency.

---

### 1.5 Withdrawal Queue Cumulative Accounting

**Invariant**: Cumulative fields in withdrawal requests are strictly monotonic increasing.

**Mathematical Expression**:
```
∀ requestId > 0:
  request[requestId].cumulativeStv ≥ request[requestId-1].cumulativeStv
  request[requestId].cumulativeStethShares ≥ request[requestId-1].cumulativeStethShares
  request[requestId].cumulativeAssets ≥ request[requestId-1].cumulativeAssets

lastRequestId ≥ lastFinalizedRequestId ≥ 0
```

**Code References**:
- `src/WithdrawalQueue.sol:80-93` - `WithdrawalRequest` struct definition
- `src/WithdrawalQueue.sol:381-392` - `_requestWithdrawal()` cumulative calculation
- `src/WithdrawalQueue.sol:993-996` - `_getDeltaFromLastFinalized()` delta calculation
- `src/WithdrawalQueue.sol:138-140` - `lastRequestId` and `lastFinalizedRequestId` storage

**Violation Scenarios**:
1. Integer overflow in cumulative sum (extremely unlikely with uint256/uint128)
2. Corrupted storage from reentrancy attack during request creation
3. Storage corruption from proxy upgrade bug
4. Out-of-order finalization bypassing monotonicity check

**Severity**: **HIGH**

**Impact**: Breaks withdrawal queue integrity; incorrect claim calculations; potential loss of funds.

---

## 2. CROSS-CONTRACT INVARIANTS

### 2.1 STV Balance Synchronization

**Invariant**: WithdrawalQueue's STV balance equals sum of unfinalized withdrawal request STVs.

**Mathematical Expression**:
```
balanceOf(WITHDRAWAL_QUEUE) = Σ(pending_request[i].stv)

Where pending = requestId ∈ [lastFinalizedRequestId + 1, lastRequestId]

Σ(pending_request.stv) = unfinalizedStv()
```

**Code References**:
- `src/StvPool.sol:365-368` - `transferFromForWithdrawalQueue()`
- `src/WithdrawalQueue.sol:1037-1040` - `unfinalizedStv()` view function
- `src/StvPool.sol:375-380` - `burnStvForWithdrawalQueue()`
- `src/WithdrawalQueue.sol:584-589` - STV burning during finalization

**Violation Scenarios**:
1. STV burned without proper withdrawal queue finalization update
2. Direct transfer to withdrawal queue bypassing `requestWithdrawal()` mechanism
3. Partial finalization leaves stale STV balance
4. Rounding errors accumulate across multiple finalization cycles

**Severity**: **HIGH**

**Impact**: Withdrawal queue insolvency; users unable to claim full amounts; protocol reputation damage.

---

### 2.2 Liability Transfer Atomicity

**Invariant**: When transferring STV with liability, transferred STV must cover minimum collateral requirement.

**Mathematical Expression**:
```
∀ transferWithLiability(from, to, stv, liability):
  stv_transferred ≥ calcStvToLockForStethShares(liability_transferred)

After transfer:
  mintedStethShares[from] -= liability_transferred
  mintedStethShares[to] += liability_transferred
  balanceOf[from] -= stv_transferred
  balanceOf[to] += stv_transferred

Both from and to must maintain:
  assetsOf(user) ≥ calcAssetsToLockForStethShares(mintedStethShares[user])
```

**Code References**:
- `src/StvStETHPool.sol:767-777` - `transferWithLiability()` public function
- `src/StvStETHPool.sol:772-776` - `_transferWithLiability()` internal implementation
- `src/StvStETHPool.sol:204-212` - `transferFromWithLiabilityForWithdrawalQueue()`
- `src/StvStETHPool.sol:386-397` - `_transferStethSharesLiability()`
- `src/StvStETHPool.sol:209-212` - `_checkMinStvToLock()` validation

**Violation Scenarios**:
1. Sender transfers liability without sufficient STV collateral (blocked by check)
2. Recipient ends up undercollateralized after receiving transfer
3. Race condition allows multiple simultaneous transfers violating atomicity
4. Reentrancy during liability transfer corrupts accounting

**Severity**: **CRITICAL**

**Impact**: Breaks collateralization guarantees; enables undercollateralized positions; systemic risk.

---

### 2.3 Dashboard Permission Boundary

**Invariant**: Only authorized contracts can call Dashboard's sensitive vault management functions.

**Mathematical Expression**:
```
Roles on Dashboard:
  FUND_ROLE → StvPool only
  MINT_ROLE → StvStETHPool only
  BURN_ROLE → StvStETHPool only
  WITHDRAW_ROLE → WithdrawalQueue only
  REBALANCE_ROLE → StvPool/StvStETHPool only

∀ sensitive_function on Dashboard:
  require(hasRole(REQUIRED_ROLE, msg.sender))
```

**Code References**:
- `src/StvPool.sol:227` - `DASHBOARD.fund{value: msg.value}()` call (requires FUND_ROLE)
- `src/StvStETHPool.sol:317` - `DASHBOARD.mintWstETH()` call (requires MINT_ROLE)
- `src/StvStETHPool.sol:329` - `DASHBOARD.mintShares()` call (requires MINT_ROLE)
- `src/StvStETHPool.sol:346` - `DASHBOARD.burnWstETH()` call (requires BURN_ROLE)
- `src/StvStETHPool.sol:356` - `DASHBOARD.burnShares()` call (requires BURN_ROLE)
- `src/WithdrawalQueue.sol:570` - `DASHBOARD.withdraw()` call (requires WITHDRAW_ROLE)
- `src/StvStETHPool.sol:673` - `DASHBOARD.rebalanceVaultWithShares()` call (requires REBALANCE_ROLE)

**Violation Scenarios**:
1. Compromised admin grants roles to malicious contracts
2. Factory deployment grants wrong permissions during `createPoolFinish()`
3. Proxy upgrade changes permission logic, breaking access control
4. Role renouncement or revocation not properly handled

**Severity**: **CRITICAL**

**Impact**: Complete system compromise; attacker can mint unlimited stETH, drain vault, manipulate balances.

---

### 2.4 Vault-Pool Asset Consistency

**Invariant**: Pool's view of total nominal assets matches Dashboard's reported lockable value.

**Mathematical Expression**:
```
totalNominalAssets() = DASHBOARD.maxLockableValue()

Where maxLockableValue represents:
  vault.totalValue + vault.inOutDelta - locked_obligations

totalValue = beacon_chain_validators + vault_balance + staged_balance
```

**Code References**:
- `src/StvPool.sol:112-114` - `totalNominalAssets()` calling Dashboard
- Dashboard interface (referenced): `maxLockableValue()` definition
- VaultHub interface (referenced): vault value calculations

**Violation Scenarios**:
1. Oracle report not yet applied to VaultHub, causing temporary mismatch
2. Stale vault report cached in Dashboard
3. Async state update between Dashboard and VaultHub during same transaction
4. Dashboard's view calculation logic diverges from VaultHub

**Severity**: **HIGH**

**Impact**: Incorrect asset pricing; mispriced STV tokens; user losses during deposits/withdrawals.

---

## 3. SECURITY PROPERTIES

### 3.1 Oracle Freshness Requirements

**Invariant**: Critical price-sensitive operations require fresh vault oracle report.

**Operations Requiring Fresh Report**:
```
depositETH()                            // src/StvPool.sol:223
receive()                               // src/StvPool.sol:202-205 (calls depositETH)
depositETHAndMintStethShares()          // src/StvStETHPool.sol:112 (calls depositETH)
depositETHAndMintWsteth()               // src/StvStETHPool.sol:128 (calls depositETH)
requestWithdrawal()                     // src/WithdrawalQueue.sol:351
requestWithdrawalBatch()                // src/WithdrawalQueue.sol:322
finalize()                              // src/WithdrawalQueue.sol:465
forceRebalance()                        // src/StvStETHPool.sol:565
forceRebalanceAndSocializeLoss()        // src/StvStETHPool.sol:582
```

**Operations NOT Requiring Fresh Report**:
```
Liability Management:
  mintStethShares()                     // src/StvStETHPool.sol:324 (capacity check only)
  mintWsteth()                          // src/StvStETHPool.sol:312 (capacity check only)
  burnStethShares()                     // src/StvStETHPool.sol:353 (reduces risk)
  burnWsteth()                          // src/StvStETHPool.sol:338 (reduces risk)

Transfers:
  transfer()                            // ERC20 standard (bad debt check only)
  transferFrom()                        // ERC20 standard (bad debt check only)
  transferWithLiability()               // src/StvStETHPool.sol:767 (collateral check only)

Withdrawals:
  claimWithdrawal()                     // src/WithdrawalQueue.sol:694 (uses checkpoint rates)
  claimWithdrawalBatch()                // src/WithdrawalQueue.sol:673 (uses checkpoint rates)

Rebalancing:
  rebalanceUnassignedLiability()        // src/StvPool.sol:268 (check in VaultHub)
  rebalanceUnassignedLiabilityWithEther() // src/StvPool.sol:282 (check in VaultHub)

Administrative:
  syncVaultParameters()                 // src/StvStETHPool.sol:471 (parameter sync)
  approve(), increaseAllowance(), etc.  // ERC20 allowance management
  pauseDeposits(), resumeDeposits()     // Circuit breakers
  pauseMinting(), resumeMinting()       // Circuit breakers
  All role management functions         // Access control
  All view/pure functions               // Read-only queries
```

**Key Insight**: `mintStethShares()` and `mintWsteth()` do NOT check for fresh reports, only minting capacity. This allows users to increase leverage with stale prices, potentially exploiting oracle delays. However, risk is mitigated by:
- Capacity checks based on current assets (still requires good collateralization)
- Force rebalance mechanism for undercollateralized positions
- Transfer restrictions prevent moving undercollateralized positions

**Mathematical Expression**:
```
∀ price_sensitive_operation:
  require(VAULT_HUB.isReportFresh(VAULT) = true)

isReportFresh typically means:
  block.timestamp - last_report_timestamp < MAX_STALENESS (e.g., 24 hours)
```

**Code References**:
- `src/StvPool.sol:417-419` - `_checkFreshReport()` internal check
- `src/StvPool.sol:223` - Fresh report check in `_deposit()`
- `src/WithdrawalQueue.sol:1092-1094` - `_checkFreshReport()` implementation in WithdrawalQueue
- `src/WithdrawalQueue.sol:351` - Fresh report check in `requestWithdrawal()`
- `src/WithdrawalQueue.sol:465` - Fresh report check in finalization (via internal call)
- `src/StvStETHPool.sol:565` - Fresh report check in `forceRebalance()`
- `src/StvStETHPool.sol:582` - Fresh report check in `forceRebalanceAndSocializeLoss()`
- `src/StvStETHPool.sol:324-330` - `mintStethShares()` does NOT check fresh report
- `src/StvStETHPool.sol:312-318` - `mintWsteth()` does NOT check fresh report

**Violation Scenarios**:
1. Oracle fails to report for extended period (> 24 hours), freezing deposit/withdrawal/rebalance operations
2. Malicious oracle report withheld to enable price manipulation by attacker
3. MEV bot front-runs oracle update transaction to exploit stale prices
4. Network congestion delays oracle report, causing legitimate operations to fail
5. **User mints stETH with stale oracle**: User can call `mintStethShares()`/`mintWsteth()` when oracle is stale, potentially increasing leverage at outdated prices (mitigated by capacity checks and force rebalance)

**Severity**: **CRITICAL**

**Impact**: Price oracle attack vector; MEV extraction; system freeze if oracle stops.

---

### 3.2 Reentrancy Protection - stETH Transfers

**Invariant**: State changes must follow Checks-Effects-Interactions pattern, completing before external calls.

**Attack Vector**: stETH's `transferShares()` makes callback to recipient contract.

**Mathematical Expression**:
```
∀ function with stETH transfer:
  1. Checks (validation)
  2. Effects (state updates)
  3. Interactions (external calls)

No state-modifying calls after external call returns.
```

**Code References**:
- `src/StvStETHPool.sol:353-357` - `burnStethShares()` sequence
  - Line 354: `_decreaseMintedStethShares()` (Effects)
  - Line 355: `STETH.transferSharesFrom()` (Interactions)
  - Line 356: `DASHBOARD.burnShares()` (Interactions)

**Violation Scenarios**:
1. Malicious recipient contract reenters during `transferSharesFrom()`
2. State update occurs after external call, allowing double-spending
3. Reentrancy guard not applied to critical functions
4. Cross-function reentrancy exploiting shared state

**Severity**: **CRITICAL**

**Impact**: Reentrancy exploit; double-spending; accounting corruption; loss of funds.

---

### 3.3 Rounding Direction Consistency

**Invariant**: Rounding must always favor the protocol, never the user.

**Rounding Rules**:
```
Assets → STV (deposit):           Math.Rounding.Floor    // User gets less STV
STV → Assets (withdrawal):        Math.Rounding.Ceil     // User pays more STV
stETH shares to lock:             Math.Rounding.Ceil     // More collateral required
stETH liability calculation:      RoundUp                // Higher liability recorded
stETH to assets conversion:       RoundUp                // Conservative asset valuation
```

**Mathematical Expression**:
```
depositPreview(assets) = floor(assets * totalSupply / totalAssets)
withdrawPreview(assets) = ceil(assets * totalSupply / totalAssets)
calcAssetsToLock(shares) = ceil(roundUp(shares * rate) * 10000 / (10000 - RR))
```

**Code References**:
- `src/StvPool.sol:149-154` - `_convertToStv()` with `Math.Rounding.Floor` for deposits
- `src/StvPool.sol:186-187` - `previewWithdraw()` with `Math.Rounding.Ceil`
- `src/StvStETHPool.sol:429-434` - `calcAssetsToLockForStethShares()` with `Math.Rounding.Ceil`
- `src/StvStETHPool.sol:325-326` - `getPooledEthBySharesRoundUp()` usage in liability calculation

**Violation Scenarios**:
1. Incorrect rounding direction allows value extraction via deposit/withdraw cycling
2. Accumulated rounding errors exceed expected bounds (> 1 wei per operation)
3. Inconsistent rounding between related calculations creates arbitrage
4. Edge case with totalSupply = 0 (prevented by initial mint)

**Severity**: **HIGH**

**Impact**: Economic exploit via rounding; slow value drain from protocol to attackers.

---

### 3.4 Integer Precision Boundaries

**Invariant**: All token amounts respect decimal precision boundaries; no overflow/underflow.

**Precision Constants**:
```
STV:                 27 decimals (E27_PRECISION_BASE = 1e27)
ETH/stETH:          18 decimals
Rate calculations:   36 decimals (E36_PRECISION_BASE = 1e36)
Basis points:        4 decimals (10000 = 100%)
```

**Mathematical Expression**:
```
∀ stv_amount: 0 ≤ stv_amount < 2^256 (enforced by uint256)
∀ eth_amount: 0 ≤ eth_amount < 2^256
∀ rate: 0 ≤ rate < 2^256

Precision loss per operation ≤ 1 wei (acceptable)
```

**Code References**:
- `src/StvPool.sol:37-38` - `DECIMALS = 27`, `ASSET_DECIMALS = 18`
- `src/WithdrawalQueue.sol:43-44` - `E27_PRECISION_BASE`, `E36_PRECISION_BASE`
- `src/WithdrawalQueue.sol:646-652` - STV rate calculation with 36-decimal precision
- OpenZeppelin `Math.mulDiv()` - Used throughout for overflow-safe multiplication

**Violation Scenarios**:
1. Overflow in `mulDiv` operations (prevented by OpenZeppelin SafeMath)
2. Loss of precision in rate calculations > 1 basis point (0.01%)
3. Decimal mismatch in cross-contract calls causing 10^9 or 10^-9 errors
4. Cumulative rounding errors in long operation chains

**Severity**: **MEDIUM**

**Impact**: Acceptable precision loss within bounds; no overflow risk with SafeMath.

---

### 3.5 Transfer Blocking Under Bad Debt

**Invariant**: All STV transfers and operations blocked when vault is in bad debt state.

**Mathematical Expression**:
```
vault_in_bad_debt = (vault_total_value < vault_liability_shares * steth_share_rate)

If vault_in_bad_debt:
  ∀ transfer_operation: revert VaultInBadDebt()
  ∀ deposit: revert VaultInBadDebt()

Withdrawals allowed (protected by checkpoint rates)
```

**Code References**:
- `src/StvPool.sol:344-352` - `_update()` override with bad debt check
- `src/StvPool.sol:308-311` - `_checkNoBadDebt()` implementation
- `src/StvPool.sol:346` - Called before any transfer in ERC20 `_update()`
- `src/StvPool.sol:377` - Bad debt check before burning STV

**Violation Scenarios**:
1. Large validator slashing event (> reserve ratio coverage)
2. Prolonged negative stETH rebases exceeding collateral buffers
3. Bad debt not yet detected by oracle (timing delay)
4. Oracle manipulation reporting false bad debt to DoS system

**Severity**: **CRITICAL**

**Impact**: Prevents bank run during insolvency; protects remaining users from losses.

---

### 3.6 Withdrawal Delay Enforcement

**Invariant**: Minimum time delay required between request creation and finalization.

**Mathematical Expression**:
```
∀ request to finalize:
  block.timestamp ≥ request.timestamp + MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS

  MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS ≥ 1 hour (enforced in constructor)
```

**Code References**:
- `src/WithdrawalQueue.sol:30` - `MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS` immutable
- `src/WithdrawalQueue.sol:211` - Constructor validation `>= 1 hour`
- `src/WithdrawalQueue.sol:546` - Delay check in `_finalize()`

**Violation Scenarios**:
1. Flash loan attack attempting instant deposit → borrow → withdraw cycle
2. Frontrunning oracle update by creating and finalizing request in same transaction
3. Admin sets delay to 0 during deployment (prevented by constructor check)
4. Time manipulation via miner timestamp control (limited to ~15 seconds)

**Severity**: **HIGH**

**Impact**: Flash loan attack prevention; oracle frontrunning mitigation; critical for economic security.

---

## 4. ECONOMIC INVARIANTS

### 4.1 Sandwich Attack Resistance

**Invariant**: Price manipulation within single block bounded by oracle freshness requirement.

**Attack Pattern**:
```
1. Attacker observes pending oracle update transaction
2. Front-runs with deposit at stale (favorable) rate
3. Oracle updates vault value
4. Attacker immediately withdraws at new (better) rate
5. Profit = value_extracted_from_other_users
```

**Mitigation**: Fresh oracle report required for ALL price-sensitive operations.

**Mathematical Expression**:
```
∀ price_sensitive_op at block N:
  require(last_oracle_update_block ≥ N)

Max extractable value per block ≤ price_volatility_per_oracle_period
```

**Code References**:
- `src/StvPool.sol:417-419` - `_checkFreshReport()` on all major operations
- `src/StvPool.sol:223` - Deposit requires fresh report
- `src/WithdrawalQueue.sol:351` - Withdrawal request requires fresh report

**Violation Scenarios**:
1. Oracle update frequency > 1 block allows intra-block manipulation
2. Flash loan manipulates stETH rebase calculation (unlikely given Lido's design)
3. MEV bot bundles oracle update with exploit in same block
4. Large deposit/withdrawal between oracle updates extracts value

**Severity**: **HIGH**

**Impact**: MEV extraction opportunity; unfair value transfer between users; economic attack.

---

### 4.2 Loss Socialization Cap

**Invariant**: Amount of loss socialized to all users capped by governance-set maximum.

**Mathematical Expression**:
```
∀ rebalance with loss:
  socialized_portion = (stvRequired - stvAvailable) / stvRequired

  require(socialized_portion ≤ maxLossSocializationBP / 10000)

Default configuration:
  maxLossSocializationBP = 0  (no socialization without explicit admin approval)

Maximum possible:
  maxLossSocializationBP = 10000  (100% loss socialization allowed)
```

**Code References**:
- `src/StvStETHPool.sol:675-684` - Loss socialization check and event emission
- `src/StvStETHPool.sol:705-713` - `_checkAllowedLossSocializationPortion()` validation
- `src/StvStETHPool.sol:733-735` - `maxLossSocializationBP()` getter
- `src/StvStETHPool.sol:743-753` - `setMaxLossSocializationBP()` admin setter
- `src/StvStETHPool.sol:54` - Storage: `uint16 maxLossSocializationBP`

**Violation Scenarios**:
1. Large undercollateralized position liquidated when `maxLossSocializationBP = 0` (tx reverts)
2. Admin maliciously sets `maxLossSocializationBP = 10000` allowing unlimited loss socialization
3. Multiple small losses accumulate, each under cap but totaling significant amount
4. Attacker creates undercollateralized position knowing losses will be socialized

**Severity**: **HIGH**

**Impact**: User funds at risk from socialized losses; fairness concern; requires trust in admin.

---

### 4.3 Force Rebalance Threshold

**Invariant**: Permissionless liquidation triggered when user's collateral ratio drops below threshold.

**Mathematical Expression**:
```
∀ user with mintedStethShares[user] > 0:

  health_factor = assetsOf(user) / getPooledEthBySharesRoundUp(mintedStethShares[user])

  liquidatable = health_factor < (10000 / (10000 - forcedRebalanceThresholdBP))

Typical configuration:
  reserveRatioBP = 8000 (80% collateral ratio = 125% overcollateralization)
  forcedRebalanceThresholdBP = 8500 (85% = 117.6% overcollateralization)

Liquidation occurs at ~117.6% collateralization ratio.
```

**Code References**:
- `src/StvStETHPool.sol:692-703` - `_isThresholdBreached()` calculation
- `src/StvStETHPool.sol:564-572` - `forceRebalance()` permissionless liquidation
- `src/StvStETHPool.sol:599-644` - `previewForceRebalance()` calculation
- `src/StvStETHPool.sol:462-464` - `forcedRebalanceThresholdBP()` getter
- `src/StvStETHPool.sol:651-653` - `isHealthyOf()` health check

**Violation Scenarios**:
1. User front-runs liquidation bot by depositing more collateral
2. Large price drop causes mass undercollateralization, liquidation bots overloaded
3. Network congestion prevents liquidation bots from calling `forceRebalance()` in time
4. Liquidation bot fails to monitor positions, allowing undercollateralization to worsen

**Severity**: **HIGH**

**Impact**: Systemic undercollateralization if not enforced; cascading liquidations; insolvency risk.

---

### 4.4 Minting Capacity Constraint

**Invariant**: Total user-minted stETH shares cannot exceed capacity calculated from collateral.

**Mathematical Expression**:
```
∀ user:
  max_mintable_shares[user] =
    calcStethSharesToMintForAssets(assetsOf(user))

  mintedStethShares[user] ≤ max_mintable_shares[user]

Global constraint:
  Σ(mintedStethShares[user]) ≤ Σ(max_mintable_shares[user])

Where:
  calcStethSharesToMintForAssets(assets) =
    getSharesByPooledEth(assets * (10000 - reserveRatioBP) / 10000)
```

**Code References**:
- `src/StvStETHPool.sol:284-286` - `totalMintingCapacitySharesOf()` calculation
- `src/StvStETHPool.sol:293-304` - `remainingMintingCapacitySharesOf()` with funding parameter
- `src/StvStETHPool.sol:359-361` - `_checkRemainingMintingCapacityOf()` validation
- `src/StvStETHPool.sol:404-409` - `calcStethSharesToMintForAssets()` implementation

**Violation Scenarios**:
1. stETH negative rebase reduces max capacity below current minted amount
2. Race condition between multiple users minting simultaneously from same pool
3. Integer overflow in capacity calculation (prevented by SafeMath)
4. User finds rounding exploit to mint slightly more than intended capacity

**Severity**: **HIGH**

**Impact**: Over-leveraging risk; potential systemic undercollateralization; insolvency.

---

### 4.5 Withdrawal Discount Mechanism

**Invariant**: Users receive discounted assets if STV rate decreased between request and finalization.

**Mathematical Expression**:
```
request_rate = assets_at_request / stv_locked
finalization_rate = totalAssets / totalSupply  (at finalization time)

If request_rate > finalization_rate:
  // STV rate decreased (assets per STV dropped)
  claimable_assets = stv_locked * finalization_rate
  discount = assets_at_request - claimable_assets
Else:
  // STV rate same or increased
  claimable_assets = assets_at_request
  discount = 0

Invariant: claimable_assets ≤ assets_at_request  (discount only, never bonus)
```

**Code References**:
- `src/WithdrawalQueue.sol:978-1018` - `_calcRequestAmounts()` with discount logic
- `src/WithdrawalQueue.sol:997-1003` - STV rate comparison and discount calculation
- `src/WithdrawalQueue.sol:646-652` - `_stvRate()` calculation for checkpoint

**Violation Scenarios**:
1. Oracle manipulation inflates finalization rate above request rate (prevented by freshness check)
2. Large negative rebase between request and finalization causes significant discount
3. Rounding errors accumulate to favor users, giving small bonuses instead of discounts
4. Attacker times withdrawals to exploit predictable rate movements

**Severity**: **MEDIUM**

**Impact**: Unfair value extraction during volatility; user losses from timing; acceptable economic trade-off.

---

## 5. SOLVENCY PROPERTIES

### 5.1 Vault-Level Solvency

**Invariant**: System must detect vault insolvency and enter protective mode.

**Mathematical Expression**:
```
vault_solvent = totalValue(vault) ≥ totalLiabilityShares * steth_share_rate

Where:
  totalValue(vault) = beacon_validators_value + vault_balance + staged_balance + inOutDelta

If !vault_solvent:
  - Block all deposits (revert VaultInBadDebt)
  - Block all transfers (revert VaultInBadDebt)
  - Block minting new liability (revert VaultInBadDebt)
  - Allow withdrawals to proceed (protected by checkpoint rates)
  - Allow liability burning (improves solvency)
```

**Code References**:
- `src/StvPool.sol:308-311` - `_checkNoBadDebt()` implementation
- `src/StvPool.sol:344-352` - `_update()` override blocking transfers under bad debt
- `src/StvPool.sol:223` - Deposit check includes bad debt validation
- `src/StvPool.sol:377` - Withdrawal finalization checks bad debt

**Violation Scenarios**:
1. Mass validator slashing event exceeding reserve ratio coverage (>20% of vault value)
2. Prolonged negative stETH rebases exceeding collateral buffers
3. Oracle fails to report slashing event, bad debt undetected for extended period
4. Combination of slashing + negative rebase + mass withdrawals

**Severity**: **CRITICAL**

**Impact**: Systemic insolvency; loss of user funds; protocol failure.

---

### 5.2 User-Level Collateralization

**Invariant**: Every user with liability must maintain minimum collateral ratio.

**Mathematical Expression**:
```
∀ user with mintedStethShares[user] > 0:

  current_ratio = assetsOf(user) / liability_value(user)

Required to maintain:
  current_ratio ≥ 10000 / (10000 - reserveRatioBP)

Example with reserveRatioBP = 8000:
  current_ratio ≥ 10000 / 2000 = 5.0 = 500% = 125% collateralization

Liquidated (force rebalanced) if:
  current_ratio < 10000 / (10000 - forcedRebalanceThresholdBP)

Example with forcedRebalanceThresholdBP = 8500:
  liquidatable if current_ratio < 10000 / 1500 ≈ 6.67 ≈ 117.6% collateralization
```

**Code References**:
- `src/StvStETHPool.sol:426-435` - `calcAssetsToLockForStethShares()` minimum collateral
- `src/StvStETHPool.sol:651-653` - `isHealthyOf()` health check function
- `src/StvStETHPool.sol:787-796` - `_update()` override blocking transfers below minimum
- `src/StvStETHPool.sol:564-572` - `forceRebalance()` permissionless liquidation

**Violation Scenarios**:
1. User transfers STV, dropping below minimum collateral requirement (blocked)
2. Negative rebase reduces collateral below threshold without user action
3. Large price movement causes rapid undercollateralization
4. Liquidation bot offline during critical period, positions worsen

**Severity**: **CRITICAL**

**Impact**: Individual user insolvency contributes to systemic risk; potential loss socialization.

---

### 5.3 Withdrawal Queue Locked Assets

**Invariant**: ETH locked in withdrawal queue must cover all finalized but unclaimed requests.

**Mathematical Expression**:
```
totalLockedAssets = Σ(claimable_eth[finalized_unclaimed_request])

totalLockedAssets ≥ 0

address(WithdrawalQueue).balance ≥ totalLockedAssets

∀ finalized unclaimed request:
  claimable_eth[request] ≤ totalLockedAssets (sufficient to claim)
```

**Code References**:
- `src/WithdrawalQueue.sol:145-146` - `totalLockedAssets` storage (uint96)
- `src/WithdrawalQueue.sol:607` - Increment on finalization
- `src/WithdrawalQueue.sol:719` - Decrement on claim
- `src/WithdrawalQueue.sol:1074-1076` - `totalLockedAssets()` getter

**Violation Scenarios**:
1. Rounding errors cause dust accumulation over many operations
2. ETH sent directly to contract via `receive()` not tracked in `totalLockedAssets`
3. Claim calculation error sends more ETH than tracked amount
4. Storage corruption from upgrade or reentrancy

**Severity**: **HIGH**

**Impact**: Withdrawal queue insolvency; some users unable to claim; last users lose funds.

---

### 5.4 Unassigned Liability Rebalancing Constraint

**Invariant**: Voluntary vault disconnect requires complete rebalancing of unassigned liability.

**Mathematical Expression**:
```
Before voluntaryDisconnect():
  totalUnassignedLiabilityShares() = 0
  totalMintedStethShares() = 0  (all users must deleverage first)

Unassigned liability must be rebalanced via:
  - rebalanceUnassignedLiability(stethShares) using vault assets
  - rebalanceUnassignedLiabilityWithEther() using external ETH
```

**Code References**:
- `src/StvPool.sol:301-303` - `_checkNoUnassignedLiability()` validation
- `src/StvPool.sol:268-273` - `rebalanceUnassignedLiability()` function
- `src/StvPool.sol:282-288` - `rebalanceUnassignedLiabilityWithEther()` alternative
- `src/StvPool.sol:350` - Check in `_update()` blocks transfers with unassigned liability

**Violation Scenarios**:
1. External rebalancing on vault creates unassigned liability without pool awareness
2. Admin attempts voluntary disconnect without completing rebalancing
3. Rounding dust (< 1 wei) prevents complete rebalancing to exactly 0
4. Race condition between rebalancing and disconnect transactions

**Severity**: **HIGH**

**Impact**: Prevents clean vault exit; orphaned liability; potential funds locked in vault.

---

### 5.5 Gas Cost Coverage Limits

**Invariant**: Gas cost coverage per withdrawal request capped to prevent abuse.

**Mathematical Expression**:
```
∀ checkpoint:
  checkpoint.gasCostCoverage ≤ MAX_GAS_COST_COVERAGE = 0.0005 ether

Total gas coverage per finalization batch:
  total_gas_coverage = num_finalized_requests * gasCostCoverage

Gas coverage deducted from user's claimable amount:
  claimable_eth[request] = calculated_eth - gasCostCoverage
```

**Code References**:
- `src/WithdrawalQueue.sol:55` - `MAX_GAS_COST_COVERAGE = 0.0005 ether` constant
- `src/WithdrawalQueue.sol:428-433` - `setFinalizationGasCostCoverage()` setter with validation
- `src/WithdrawalQueue.sol:609-616` - Gas payment to finalizer during finalization
- `src/WithdrawalQueue.sol:104` - Checkpoint struct includes `gasCostCoverage` field

**Violation Scenarios**:
1. Admin sets excessive gas coverage to drain user funds (prevented by MAX cap)
2. Gas coverage not properly deducted from user claims (logic error)
3. Malicious user creates many small requests to extract gas fees (mitigated by MIN_WITHDRAWAL_VALUE)
4. Finalizer collusion with admin to increase gas coverage

**Severity**: **MEDIUM**

**Impact**: Economic attack via gas cost manipulation; user funds drained slowly; requires governance trust.

---

## 6. ADDITIONAL FUNDAMENTAL INVARIANTS

### 6.1 Checkpoint Monotonicity

**Invariant**: Checkpoint indices and request ID ranges strictly increase.

**Mathematical Expression**:
```
∀ i > 0:
  checkpoint[i].fromRequestId > checkpoint[i-1].fromRequestId

lastCheckpointIndex monotonically increases (never decreases)

lastFinalizedRequestId ≤ lastRequestId (always)

Binary search invariant:
  checkpoint array sorted by fromRequestId for O(log n) lookup
```

**Code References**:
- `src/WithdrawalQueue.sol:98-105` - `Checkpoint` struct with `fromRequestId`
- `src/WithdrawalQueue.sol:602-604` - Checkpoint creation during finalization
- `src/WithdrawalQueue.sol:765-801` - `_findCheckpointHint()` binary search relies on monotonicity
- `src/WithdrawalQueue.sol:143` - `lastCheckpointIndex` storage

**Violation Scenarios**:
1. Storage corruption from proxy upgrade bug
2. Integer underflow in checkpoint index calculation (prevented by SafeCast)
3. Out-of-order finalization creating non-monotonic checkpoints
4. Concurrent finalization calls (prevented by single-threaded execution)

**Severity**: **HIGH**

**Impact**: Breaks checkpoint lookup and claiming; users unable to find correct checkpoint; loss of funds.

---

### 6.2 Oracle Report Age Constraint

**Invariant**: Withdrawal requests can only be finalized if created before latest oracle report.

**Mathematical Expression**:
```
∀ request to finalize:
  request.timestamp < latestOracleReportTimestamp

Ensures at least one oracle update occurred after request creation,
preventing exploitation of stale prices.

Additionally:
  block.timestamp ≥ request.timestamp + MIN_WITHDRAWAL_DELAY_TIME_IN_SECONDS
```

**Code References**:
- `src/WithdrawalQueue.sol:547` - Oracle timestamp check in `_finalize()`
- `src/WithdrawalQueue.sol:481` - Fetch `latestReportTimestamp` from LazyOracle
- `src/WithdrawalQueue.sol:546` - Delay check in conjunction with oracle age

**Violation Scenarios**:
1. Request created in same block as oracle report (edge case, timestamp equality)
2. Oracle stops reporting, all pending requests become un-finalizable
3. Attacker tries to finalize immediately after creating request (blocked)
4. Oracle timestamp manipulation (requires compromising Lido oracle)

**Severity**: **HIGH**

**Impact**: Prevents stale price exploitation; flash loan attack mitigation; critical security boundary.

---

### 6.3 Strategy Call Forwarder Isolation

**Invariant**: Each user gets isolated StrategyCallForwarder proxy, preventing cross-user attacks.

**Mathematical Expression**:
```
∀ user1, user2 where user1 ≠ user2:
  userCallForwarder[user1] ≠ userCallForwarder[user2]

After first strategy interaction:
  userCallForwarder[user] ≠ address(0)

Forwarder address deterministic:
  address = CREATE2(factory, salt=user_address, bytecode)
```

**Code References**:
- Strategy implementation (referenced): `_getOrCreateCallForwarder()` function
- Strategy storage (referenced): Per-user call forwarder mapping
- Factory pattern uses CREATE2 with user address as salt for deterministic addresses

**Violation Scenarios**:
1. Deterministic address collision via CREATE2 (cryptographically impossible)
2. Registry corruption allowing attacker to use another user's forwarder
3. Proxy upgrade changes forwarder logic, breaking isolation
4. Forwarder implementation bug allows cross-user calls

**Severity**: **CRITICAL**

**Impact**: Cross-user attack vector; attacker can manipulate other users' strategy positions; total loss.

---

### 6.4 Reserve Ratio Gap Constraint

**Invariant**: Pool reserve ratio must exceed vault reserve ratio by configured gap.

**Mathematical Expression**:
```
pool_reserveRatioBP = min(vault_reserveRatioBP + RESERVE_RATIO_GAP_BP, 9999)

pool_forcedRebalanceThresholdBP =
  min(vault_forcedRebalanceThresholdBP + RESERVE_RATIO_GAP_BP, 9998)

Constraints:
  pool_forcedRebalanceThresholdBP < pool_reserveRatioBP < 10000
  vault_reserveRatioBP + RESERVE_RATIO_GAP_BP < 10000 (checked in constructor)
```

**Code References**:
- `src/StvStETHPool.sol:44` - `RESERVE_RATIO_GAP_BP` immutable variable
- `src/StvStETHPool.sol:75-76` - Constructor validation preventing overflow
- `src/StvStETHPool.sol:471-497` - `syncVaultParameters()` sync logic with gap application
- `src/StvStETHPool.sol:483-486` - Min capping to prevent ratio exceeding limits

**Violation Scenarios**:
1. Vault RR increases via governance, pool doesn't sync before next operation
2. Gap too small, pool liquidation threshold becomes too close to vault RR
3. Gap + vault RR > 10000, causing arithmetic error (prevented by constructor)
4. Sync function not called after VaultHub parameter update

**Severity**: **MEDIUM**

**Impact**: Safety margin between vault and pool liquidation eroded; increased systemic risk.

---

### 6.5 STV Total Supply Never Zero

**Invariant**: STV total supply must remain positive after pool initialization.

**Mathematical Expression**:
```
After initialize():
  totalSupply() ≥ initial_vault_balance * 10^9

Typically:
  initial_vault_balance = CONNECT_DEPOSIT = 1 ETH = 10^18 wei
  initial_STV_minted = 10^18 * 10^9 = 10^27 (1 STV with 27 decimals)

∀ t after initialization:
  totalSupply(t) > 0
```

**Code References**:
- `src/StvPool.sol:95-101` - `initialize()` initial minting logic
- `src/StvPool.sol:96-98` - Assertions: `initialVaultBalance >= connectDeposit`, `totalSupply() == 0`
- `src/StvPool.sol:100-101` - Initial mint to contract itself (locked forever)

**Violation Scenarios**:
1. All STV burned including initial mint (should be impossible as initial mint locked on contract)
2. Total supply underflow bug (prevented by OpenZeppelin SafeMath in ERC20)
3. Burn operation allows draining total supply to zero (blocked by locking initial mint)

**Severity**: **CRITICAL**

**Impact**: Division by zero in `totalAssets() / totalSupply()` calculations; complete system failure.

---

### 6.6 Exceeding Minted stETH Priority in Rebalancing

**Invariant**: During rebalancing, exceeding minted stETH consumed before withdrawing from vault.

**Mathematical Expression**:
```
If exceedingMintedStethShares > 0 AND stethToRebalance > 0:

  steth_from_excess = min(exceedingMintedStethShares, stethToRebalance)
  steth_to_withdraw_from_vault = stethToRebalance - steth_from_excess

This optimizes gas and avoids unnecessary vault withdrawals.
```

**Code References**:
- `src/WithdrawalQueue.sol:529-536` - Exceeding stETH consumption during finalization
- `src/WithdrawalQueue.sol:630-636` - `_getExceedingMintedSteth()` helper function
- `src/StvStETHPool.sol:668-673` - Exceeding shares checked in `_rebalanceMintedStethShares()`

**Violation Scenarios**:
1. Logic error preferring vault withdrawal over using excess stETH (inefficient, not unsafe)
2. Exceeding stETH not properly tracked due to accounting bug
3. Race condition between exceeding stETH calculation and usage

**Severity**: **MEDIUM**

**Impact**: Inefficient rebalancing; higher gas costs; not a security vulnerability but operational issue.

---

### 6.7 stETH Rebase Monotonicity Assumption

**Invariant**: System assumes stETH share rate generally increases or remains flat (small negative rebases acceptable).

**Mathematical Expression**:
```
steth_share_rate(t) = totalPooledEther / totalShares at time t

Expected (normal operation):
  steth_share_rate(t+1) ≥ steth_share_rate(t) * 0.99

Tolerable: Up to ~1% negative rebase
Catastrophic: > 10% negative rebase (system may become insolvent)

This is an ASSUMPTION about external Lido protocol behavior.
```

**Code References**:
- External dependency: Lido stETH token
- Impact throughout: All stETH liability calculations assume relatively stable rates
- `src/StvStETHPool.sol:325-327` - `getPooledEthBySharesRoundUp()` usage

**Violation Scenarios**:
1. Large validator slashing event affecting > 1% of Lido TVL
2. Multiple simultaneous slashings across many validators
3. Oracle attack reporting false massive negative rebase
4. Consensus layer issue causing widespread slashing

**Severity**: **CRITICAL** (if assumption violated)

**Impact**: System designed around assumption of positive/neutral rebases; large negative rebase could cause mass undercollateralization and insolvency.

---

## 7. ATTACK VECTORS & MITIGATIONS

### 7.1 Oracle Manipulation

**Attack Description**:
Attacker compromises or manipulates Lido's oracle to report false vault values, enabling:
- Deposit at artificially low STV price (oracle reports low vault value)
- Withdraw at artificially high STV price (oracle reports high vault value)
- Extract value from honest users

**Mitigation Strategy**:
1. **Fresh Report Requirement**: All price-sensitive operations require `isReportFresh(VAULT) = true`
2. **Multiple Operations Blocked**: Single stale report blocks deposits, withdrawals, minting, burning, rebalancing
3. **Oracle Decentralization**: Reliance on Lido's decentralized oracle network
4. **Time Delay**: Withdrawal delay ensures at least one oracle update between request and finalization

**Residual Risk**:
- Oracle compromise is external dependency risk
- If Lido oracle fails, entire system freezes
- No fallback oracle or escape hatch
- Trust assumption: Lido oracle operates correctly

**Severity**: **CRITICAL** (if oracle compromised)

---

### 7.2 Validator Mass Slashing

**Attack Description**:
Multiple validators slashed simultaneously, causing vault value to drop below liability:
- Reserve ratio insufficient to cover losses (designed for < 20% loss typically)
- Users with leveraged positions become undercollateralized
- System enters bad debt state
- Potential bank run as users rush to exit

**Mitigation Strategy**:
1. **Reserve Ratio Buffer**: 80% reserve ratio provides 25% cushion (125% collateralization)
2. **Forced Rebalancing**: Permissionless liquidation at 85% threshold (117.6% collateralization)
3. **Loss Socialization Cap**: `maxLossSocializationBP` limits single-event loss distribution
4. **Bad Debt Detection**: Automatic system freeze (transfers blocked) when `totalValue < totalLiability`
5. **Multiple Layers**: Reserve ratio (vault + pool), force rebalance threshold, loss cap

**Residual Risk**:
- Catastrophic slashing (> 20-30% of vault) could cause insolvency
- Liquidation bots must be online and functional
- Network congestion could prevent timely liquidations
- Loss socialization distributes remaining losses to all users

**Severity**: **HIGH** (catastrophic scenario)

---

### 7.3 MEV Sandwich Attack on Deposits/Withdrawals

**Attack Description**:
MEV bot sandwich attacks deposits or withdrawals:
1. Observe pending deposit transaction in mempool
2. Front-run with large deposit, diluting price
3. Victim's deposit executes at worse rate
4. Back-run with withdrawal, extracting value

Or reverse for withdrawals.

**Mitigation Strategy**:
1. **Oracle Freshness Check**: Cannot execute deposit/withdrawal with stale oracle
2. **Atomic Oracle Updates**: Operations in same block as oracle update have consistent pricing
3. **Price Impact Minimized**: Single transaction cannot manipulate oracle-sourced vault value
4. **No AMM-Style Pricing**: Price determined by oracle, not by pool reserves

**Residual Risk**:
- Intra-block manipulation if oracle updates in same block as user operation
- Large legitimate transactions can shift value between users
- MEV extraction bounded by oracle update frequency
- No slippage protection in protocol (users should use external tools)

**Severity**: **HIGH** (MEV opportunity)

---

### 7.4 Withdrawal Queue DoS via Dust Requests

**Attack Description**:
Attacker creates many minimum-value withdrawal requests to clog queue:
- Each request costs gas to finalize
- Finalizer bot must process many requests
- Queue becomes expensive to clear
- Legitimate large withdrawals delayed behind dust

**Mitigation Strategy**:
1. **Minimum Withdrawal Value**: `MIN_WITHDRAWAL_VALUE = 0.001 ether` prevents tiny requests
2. **Gas Cost Coverage**: Users pay gas costs via `gasCostCoverage`, disincentivizing spam
3. **Maximum Asset Cap**: `MAX_WITHDRAWAL_ASSETS = 10,000 ether` encourages batching large withdrawals
4. **Batch Finalization**: Finalizer can process multiple requests in single transaction

**Residual Risk**:
- Still economically viable during high ETH prices (0.001 ETH @ $10,000 = $10/request)
- Determined attacker could still spam queue at cost
- No rate limiting or per-user queue restrictions
- Finalization bot centralized point of failure

**Severity**: **MEDIUM** (DoS risk)

---

### 7.5 Loss Socialization Griefing

**Attack Description**:
Attacker intentionally creates large undercollateralized position to socialize losses:
1. Deposit collateral and mint maximum stETH liability
2. Wait for negative rebase or transfer out collateral
3. Trigger `forceRebalanceAndSocializeLoss()` via accomplice
4. Losses socialized to all innocent users
5. Attacker extracts value at others' expense

**Mitigation Strategy**:
1. **Loss Socialization Cap**: `maxLossSocializationBP` limits per-operation loss (default 0%)
2. **Role Requirement**: Only `LOSS_SOCIALIZER_ROLE` can call `forceRebalanceAndSocializeLoss()`
3. **Normal Force Rebalance First**: Permissionless `forceRebalance()` tries to liquidate without socialization
4. **Health Monitoring**: Users can monitor positions and trigger liquidations early
5. **Reserve Ratio Enforcement**: Transfer blocking prevents intentional undercollateralization

**Residual Risk**:
- Admin can set `maxLossSocializationBP = 10000` (100%) allowing unlimited socialization
- Requires trust in `LOSS_SOCIALIZER_ROLE` holder
- Multiple small losses can accumulate even with cap
- No per-user loss socialization limit

**Severity**: **HIGH** (requires admin trust)

---

### 7.6 Reentrancy Attacks

**Attack Description**:
Malicious contract exploits external calls to reenter and manipulate state:
- stETH `transferSharesFrom()` makes callback to recipient
- Attacker reenters during callback to call state-changing functions
- Could double-spend, manipulate balances, or corrupt accounting

**Mitigation Strategy**:
1. **Checks-Effects-Interactions Pattern**: State updates before external calls
2. **Example** (`burnStethShares`):
   - Line 354: `_decreaseMintedStethShares()` - Effects first
   - Line 355: `STETH.transferSharesFrom()` - Interactions last
3. **ERC20 Reentrancy Guard**: OpenZeppelin ERC20 prevents reentrancy on transfers
4. **Access Control**: Critical Dashboard functions require specific roles

**Residual Risk**:
- Complex interaction patterns across multiple contracts
- Cross-function reentrancy if shared state not properly guarded
- New functions must maintain pattern discipline
- Proxy upgrades could introduce vulnerabilities

**Severity**: **CRITICAL** (if pattern violated)

---

### 7.7 Front-Running Oracle Updates

**Attack Description**:
Attacker monitors for pending oracle update transactions and front-runs:
1. Observe oracle update showing vault value increase in mempool
2. Front-run with large deposit at old (low) rate
3. Oracle updates, vault value increases
4. Immediately withdraw at new (high) rate
5. Profit extracted from existing users

**Mitigation Strategy**:
1. **Fresh Report Requirement**: Operations blocked until oracle report is on-chain
2. **Withdrawal Delay**: Minimum time delay prevents instant deposit → withdraw
3. **Oracle Report Age Check**: Requests must be created after latest oracle report
4. **Atomic Pricing**: All operations in same block use same oracle price

**Residual Risk**:
- Attacker could deposit just before oracle update, then withdraw after delay
- No commitment scheme or TWAP pricing to smooth oracle updates
- Large oracle updates (rare) create larger MEV opportunities
- Requires monitoring mempool or having private oracle data

**Severity**: **HIGH** (front-running opportunity)
