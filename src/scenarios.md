
# Cases

## Case 0. Connection of wrapper to already created vault
- q: what's about connect deposit?

## Case 1. Two users can mint up to the full vault capacity
- user1 and user2 deposit
- user1 mints stETH for all stvETH it has. user2 does the same
- remaining minting capacity of the vault is zero or 1-2 wei due to stETH rounding errors

## Case 2. User3 deposits and fully mints after user1 and user2
- two users mint up to the full vault capacity
- remaining minting capacity of the vault is zero or 1-2 wei due to stETH rounding errors
- user3 deposits more ETH
- user3 mints for all stvETH it has
- remaining minting capacity of the vault is zero or 1-2 wei due to stETH rounding errors
- assets value corresponding to the stvETH locked on Escrow is 1-2-wei-equal to the all three users total stETH value

## Case 3. When remainingMintingCapacityShares != totalMintingCapacityShares
- condition: Vault's remainingMintingCapacityShares(0) != totalMintingCapacityShares due to liabilities
- do "case 1"

## Case 4. Withdrawal simplest happy path (not stETH minted, no boost)
- user deposits
- user requests withdrawal waits till it is available and withdraws getting the same amount of ETH it had

## Case 5. Strategy (loop) deposits the last without stShares minting

## Case 6. Strategy mints stShares for the eth it earned beyond the vault

## Case 7. Strategy mints stShares for the vault rewards accumulated

## Case 8. Strategy fails to return enough stShares for the vault to withdraw

## Case 9. Withdraw eth without burning stShares due to rewards

## Case 10. Scenario for WrapperA with manual calculation

## Case 11. User gets less stShares due to vault underperformance

What are the consequences?
1. Need to deposit enough to overcome collateral provided by connect deposit. E.g. 1000 ETH and 0.1% decrease (compared to stETH?)

## Case 12. User deposits little after vault with lots of eth performed poorly

user1 deposits
vault gets rewards
user2 deposits



## building bricks for test scenarios

- rounding issues

### wrapper side

- multiple users
- user mints full and not full capacity
- user withdraws all
- user withdraws partially

### core
- when there is non-zero NO fee rate and not
- user cannot withdraw fully due to the vault shrunk: huge lido fees, obligations, ...

### strategy side

- strategy borrowed eth but the position got liquidated

## Test grouping

- deposit
- mint
- loop strategy
- withdraw by stvETH
- withdraw by stETH
- withdraw with strategy

## Tech Design

### Wrapper configurations variety and factory

There are multiple possible Wrapper configurations to be chosen from upon deployment:
- (A) no minting, no strategy
- (B) minting, no strategy
- (C) minting and strategy

Each configuration is represented by its own contract which inherits WrapperBase contract implementing features that are common between all configurations.
The common features include:
- non-transferrable ERC-20
- access control
- assets(ETH) and shares(stvETH) calculations borrowed from ERC4626 Tokenized Vault standard
- allowlisting
- vault disconnection and connect deposit claiming

Upon Wrapper construction (in ctor) the Vault must have balance of at least Dashboard.CONNECT_DEPOSIT ETH.

### Deposits

In all Wrapper configurations upon deposit Wrapper mints stvETH shares corresponding to the share of the user in the Vault. The stvETH shares are not transferrable.
In (B) user gets maximum stETH amount mintable on the Vault.
In (C) user gets record in Wrapper which represents the position. The record consists of id, stvETH shares, stETH provided for strategy.

### Withdrawals

There are different withdraw functions for (A), (B) and (C). For calling each of them user must have "enough" stvShares.

In (A) and (B) user may withdraw part of his Vault share by specifying stvShares amount (must own at least that shares).
In (C) user may with withdraw only his Vault share corresponding to an entire strategy position

- (A) withdraw(stvETHShares)
  - burns stvETH shares
- (B) withdraw(stvETHShares, stETHShares)
  - burns stvETH shares and provided stETHShares
- (C) withdraw(positionId)

Withdrawals for (A) and (B) are three steps:
- user -> WQ.requestWithdrawal(stvETHShares, stETHShares)
  - here need to Dashboard.burnShares or Dashboard.burnStETH
- (... wait till NO withdraws the validators if required ...)
- NO -> WQ.finalize(latestRequestId)
- user -> WQ.claimWithdrawal(requestId)

Withdrawals for (C) have additional steps comparing to (A) and (B):
- Wrapper.requestClosePosition(positionId)
- Wrapper.finalizeClosePositions(positionId) -> stETH is returned to user by strategy
- the same steps as for (A) and (B)

### Multiple deposits and partial withdrawals

If user deposits multiple times: in (A) and (B) his stvETH balance is accumulated; in (C) multiple separate strategy positions are created.


### Vault disconnection

### Emergency withdrawals

TODO

### What if strategy returns not enough stETH
