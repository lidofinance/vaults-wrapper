from dataclasses import dataclass
from typing import override
from wake.testing import *
from wake.testing.fuzzing import *

from pytypes.src.Factory import Factory
from pytypes.wake_fuzz.mocks.MockVaultHub import MockVaultHub
from pytypes.src.StvStETHPool import StvStETHPool
from pytypes.src.WithdrawalQueue import WithdrawalQueue

from pytypes.lib.openzeppelincontracts.contracts.governance.TimelockController import (
    TimelockController,
)

from collections import defaultdict
from typing import cast


from wake_fuzz.test_stvpool_fuzz import FuzzPool, WQData


import logging

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


# Print failing tx call trace
def revert_handler(e: RevertError):
    if e.tx is not None:
        print(e.tx.call_trace)


TOTAL_BASIS_POINTS = 100_00


class FuzzStEthPoool(FuzzPool):

    @property
    def stv_steth_pool(self) -> StvStETHPool:
        return cast(StvStETHPool, self.pool)

    bp_ratio: int  # define in pool, that steth share minging ratio
    reserve_ratio_bp: int  # derive from vault hub
    forced_rebalance_threshold_bp: int  # derive from vault hub

    steth_shares: dict[Account, int]
    wsteth_balance: dict[Account, int]

    # steth_shares + wsteth_balance however rounding makes difference,
    # but rounding is only happen each 1 and never multiplied,
    # and done in LIDO during unwrap() from wsteth to steth.
    user_minted_shares: dict[Account, int]

    total_liability_in_share: int

    user_bad_debt_socializer_user: Account

    timelock_controller: TimelockController  # admin of pool

    vault_reserve_ratio_gap_bp: int

    @override
    def pool_build_configs(
        self,
    ) -> tuple[
        Factory.VaultConfig, Factory.CommonPoolConfig, Factory.AuxiliaryPoolConfig
    ]:
        return self.build_configs(
            allowlist_enabled=False,
            minting_enabled=True,
            reserve_ratio_gap_bp=self.vault_reserve_ratio_gap_bp,
            name="Factory STV Pool",
            symbol="FSTV",
        )

    @override
    def past_pool_specific_config(
        self, deployment: Factory.PoolDeployment, deploy_tx: TransactionAbc
    ):
        self.pool = StvStETHPool(deployment.pool)
        assert isinstance(self.pool, StvStETHPool)

        self.timelock_controller = TimelockController(deployment.timelock)

        assert (
            self.withdrawal_queue.IS_REBALANCING_SUPPORTED() == True
        )  # only for stvstEthPool

        # pool # syncvault Parameters

        event = next(
            e
            for e in deploy_tx.events
            if isinstance(e, StvStETHPool.VaultParametersUpdated)
        )
        self.reserve_ratio_bp = event.newReserveRatioBP
        self.forced_rebalance_threshold_bp = event.newForcedRebalanceThresholdBP

        self.user_bad_debt_socializer_user = chain.accounts[4]

        self.pool.grantRole(
            self.pool.LOSS_SOCIALIZER_ROLE(),
            self.user_bad_debt_socializer_user,
            from_=self.timelock_controller,  # open-zappelin timelock, not testing it.
        )

        # once during setup, by DEFAULT_ADMIN_ROLE holder
        self.pool.setMaxLossSocializationBP(10_000, from_=self.timelock_controller)

    @override
    def pre_sequence(self):
        self.total_liability_in_share = 0
        self.steth_shares = defaultdict(int)
        self.wsteth_balance = defaultdict(int)
        self.user_minted_shares = defaultdict(int)

        self.bp_ratio = 20_00
        self.vault_reserve_ratio_gap_bp = 1000

        super().pre_sequence()

    @override
    @flow()
    def flow_withdraw_req(self) -> str | None:
        numerator = 10**15 * self.pool_total_supply

        # Round up to make min amount_stv higher than actual revert condition.
        stv_estimated_amount = -(-numerator // self.pool_total_asset)

        eligible_users = [
            acc
            for acc in chain.accounts
            if self.pool_balance[acc] > stv_estimated_amount
        ]
        if not eligible_users:
            return "no eligible users for withdrawal"

        user = random.choice(eligible_users)

        amount_stv = random_int(
            stv_estimated_amount, self.pool_balance[user]
        )  # 10**15 is min value

        # previewRedeem
        asset_amount = amount_stv * self.pool_total_asset // self.pool_total_supply
        # round down -> asset reamin in staking pool
        #  -> everyone can withdraw
        # -> token value is increase, this is not problem

        # check minted stEthShare for this
        # stored as common summed value since value takes same things
        if self.steth_shares[user] + self.wsteth_balance[user] > 0:
            #     stv_value = self.pool.convertStethSharesToStv(self.minted_steth_shares[user], request_type="call")
            #     if stv_value >= amount_stv:
            #         return "user can withdraw from minted stEthShare, skip withdrawal request"

            # assetsToLock in the code
            in_asset = self.steth.getPooledEthBySharesRoundUp(
                self.steth_shares[user] + self.wsteth_balance[user]
            )

            # asset to lock vlaue is calculated with ceil. round
            asset_tobe_locked = -(
                (-in_asset * TOTAL_BASIS_POINTS) // (TOTAL_BASIS_POINTS - self.bp_ratio)
            )

            stv_value = -(
                -asset_tobe_locked * self.pool_total_supply // self.pool_total_asset
            )

            if stv_value > self.pool_balance[user] - amount_stv:
                return (
                    "user can withdraw from minted stEthShare, skip withdrawal request"
                )

        tx = self.withdrawal_queue.requestWithdrawal(
            _owner=user.address,
            _stvToWithdraw=amount_stv,
            _stethSharesToRebalance=0,
            from_=user.address,
        )

        event = next(
            e for e in tx.events if isinstance(e, WithdrawalQueue.WithdrawalRequested)
        )

        assert event.amountOfStv == amount_stv
        assert event.amountOfStethShares == 0

        self.pool_balance[user] -= amount_stv
        self.pool_balance[self.withdrawal_queue] += amount_stv
        request_id = event.requestId  # Trakc id
        request = WQData(
            request_id=request_id,
            owner=user.address,
            stv_amount=amount_stv,
            steth_shares_amount=0,
            asset_amount=asset_amount,
            start_timestamp=tx.block.timestamp,  # timestamp when queued
            fulfilled=False,
            claimed=False,
        )
        self.withdrawal_queue_requests[request_id] = request

        logger.info(
            f"Requested withdrawal of {amount_stv} STV for request id {request_id} by {user.address}"
        )

    @flow()
    def flow_mint_steth_shares(self):

        user = random_account()

        stv_amount = self.pool_balance[user]
        eth_amount = stv_amount * self.pool_total_asset // self.pool_total_supply

        max_steth_to_mint = (
            eth_amount * (TOTAL_BASIS_POINTS - self.bp_ratio) // TOTAL_BASIS_POINTS
        )

        max_steth_shares_to_mint = self.steth.getSharesByPooledEth(max_steth_to_mint)

        # Mint alot to simulate rebalance more
        max_mintable_now = max_steth_shares_to_mint - (self.user_minted_shares[user])
        if max_mintable_now <= 0:
            return "no mintable steth"

        is_steth_share = random_bool()
        if is_steth_share:
            tx = self.stv_steth_pool.mintStethShares(max_mintable_now, from_=user)
        else:
            tx = self.stv_steth_pool.mintWsteth(max_mintable_now, from_=user)

        # Also for WSTETH but make sense
        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesMinted)
        )
        assert event.account == user.address
        assert event.stethShares == max_mintable_now

        if is_steth_share:
            self.steth_shares[user] += max_mintable_now
        else:
            self.wsteth_balance[user] += max_mintable_now

        self.user_minted_shares[user] += max_mintable_now

        logger.info(f"User {user} minted {max_mintable_now} stETH shares")

    @flow(weight=10)
    def flow_burn_steth_shares(self):

        user = random_account()

        is_steth_share = random_bool()

        steth_shares_owned = self.user_minted_shares[user]

        if is_steth_share:
            steth_shares_owned = min(self.steth_shares[user], steth_shares_owned)

        else:
            steth_shares_owned = min(self.wsteth_balance[user], steth_shares_owned)
        if steth_shares_owned <= 0:
            return "no steth shares to withdraw"

        steth_shares_to_withdraw = random_int(1, steth_shares_owned)

        steth_amount = self.steth.getPooledEthByShares(steth_shares_to_withdraw)
        unwrapped_steth_share_from_wsteth = self.steth.getSharesByPooledEth(
            steth_amount
        )

        # Diff is always 0 or 1 due to rounding
        assert 0 <= steth_shares_to_withdraw - unwrapped_steth_share_from_wsteth <= 1

        if is_steth_share:

            # function round down. approve more than required
            approve_steth_amount = (
                self.steth.getPooledEthByShares(steth_shares_to_withdraw) * 110 // 100
            )
            tx = self.steth.approve(self.pool.address, approve_steth_amount, from_=user)
        else:
            tx = self.wsteth.approve(
                self.pool.address, steth_shares_to_withdraw, from_=user
            )

        if is_steth_share:
            tx = self.stv_steth_pool.burnStethShares(
                steth_shares_to_withdraw, from_=user
            )
        else:
            tx = self.stv_steth_pool.burnWsteth(steth_shares_to_withdraw, from_=user)

        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesBurned)
        )  # same event for both
        assert event.account == user.address

        if is_steth_share:
            assert event.stethShares == steth_shares_to_withdraw
        else:
            assert event.stethShares == unwrapped_steth_share_from_wsteth
            logger.info(
                f"User {user} withdrew {unwrapped_steth_share_from_wsteth} stETH shares via WSTETH burn"
            )

        if is_steth_share:
            self.steth_shares[user] -= steth_shares_to_withdraw
            self.user_minted_shares[user] -= steth_shares_to_withdraw
        else:
            self.wsteth_balance[user] -= steth_shares_to_withdraw
            self.user_minted_shares[user] -= unwrapped_steth_share_from_wsteth  # FOCUS,

        logger.info(f"User {user} withdrew {steth_shares_to_withdraw} stETH shares")

    @flow()
    def flow_force_rebalance(self):

        # not using eligible user list to make bad debt to run flow_force_rebalance_socialize_loss.
        user = random_account()

        (steth_share, stv, is_undercollateralized) = (
            self.stv_steth_pool.previewForceRebalance(user.address)
        )
        # undewrcollateralized when user holding share value is less than

        # save steth, steth get more value so correct.
        steth_value = self.steth.getPooledEthBySharesRoundUp(steth_share)
        # this amount of steth is rebalance for user.
        # user have this value of steth, and by burning users stv. rebalance is done.
        # just vurn stv, which is share, and

        if (stv == 0 and steth_share == 0) and not is_undercollateralized:
            return "no need to rebalance"

        if is_undercollateralized:
            return "undercollateralized"

        total_value = self.vault_hub.totalValue(self.staking_vault.address)
        total_share = self.steth.getSharesByPooledEth(total_value)
        total_liability_shares = self.pool.totalLiabilityShares()
        if total_share < total_liability_shares:
            return "Vault in bad debt"

        tx = self.stv_steth_pool.forceRebalance(
            user,
            from_=random_account(),  # anyone
        )

        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesRebalanced)
        )
        assert event.account == user.address
        assert event.stethShares == steth_share
        assert event.stvBurned == stv

        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesBurned)
        )
        assert event.account == user.address
        assert event.stethShares == steth_share

        event = next(e for e in tx.events if isinstance(e, StvStETHPool.Transfer))
        assert event.from_ == user.address
        assert event.to == Address.ZERO
        assert event.value == stv

        assert False == any(
            e for e in tx.events if isinstance(e, StvStETHPool.SocializedLoss)
        )

        self.user_minted_shares[user] -= steth_share
        self.pool_balance[user] -= stv
        self.native_balance[self.staking_vault] -= steth_value  # 1:1 with eth
        self.native_balance[
            self.vault_hub
        ] += steth_value  # actual implementation is different

        # so it state is like by buring stv, token change to Eth,
        # and by giving eth to lido,
        # steth that user owened is like user bought the steth.
        # This is done in Dashboard and VaultHub and LIDO.

        # Therefore, for pool point of view,
        # Pool total asset and stv decrease!

        event = next(
            e for e in tx.events if isinstance(e, MockVaultHub.VaultRebalanced)
        )
        assert event.vault == self.staking_vault.address
        assert event.sharesBurned == steth_share
        assert event.etherWithdrawn == steth_value

        self.pool_total_asset -= steth_value
        self.pool_total_supply -= stv

        logger.info(f"Force rebalance called for {user}")

    @flow()
    def flow_force_rebalance_socialize_loss(self):

        eligible_users: list[Account] = []

        for user in chain.accounts:
            (_, _, loop_is_undercollateralized) = (
                self.stv_steth_pool.previewForceRebalance(user)
            )
            if loop_is_undercollateralized:
                eligible_users.append(user)

        if len(eligible_users) == 0:
            return "no user is undercollateralized"

        user = random.choice(eligible_users)
        (steth_share, stv_can_be_burn_for_user, is_undercollateralized) = (
            self.stv_steth_pool.previewForceRebalance(user)
        )

        if steth_share == 0:
            assert stv_can_be_burn_for_user == 0
            assert self.staking_vault.balance == 0
            return "StakingVault lack of liquidity"

        steth_value = self.steth.getPooledEthBySharesRoundUp(
            steth_share
        )  # save steth, steth get more value so correct.

        stv_to_burn = self.pool.previewWithdraw(
            steth_value
        )  # just convert to stv with ceil

        # POC shoud be this value..
        stv_can_be_burn_for_user_value = (
            stv_can_be_burn_for_user * self.pool_total_asset
        ) // self.pool_total_supply

        user_stv = self.pool_balance[user]

        assert user_stv >= stv_can_be_burn_for_user

        # round up to minimize socialzea share
        # user_value = (self.pool_balance[user] * self.pool_total_asset // self.pool_total_supply)

        total_value = self.vault_hub.totalValue(self.staking_vault.address)
        total_share = self.steth.getSharesByPooledEth(total_value)
        total_liability_shares = self.pool.totalLiabilityShares()
        if total_share < total_liability_shares:
            logger.info("Vault in bad debt, deposit reverted")
            return

        tx = self.stv_steth_pool.forceRebalanceAndSocializeLoss(
            user,
            from_=self.user_bad_debt_socializer_user,  # not anyone!!! if he can not cover it? what happen!!
        )

        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesRebalanced)
        )
        assert event.account == user.address
        assert event.stethShares == steth_share
        assert event.stvBurned == stv_can_be_burn_for_user

        event = next(
            e for e in tx.events if isinstance(e, StvStETHPool.StethSharesBurned)
        )
        assert event.account == user.address
        assert event.stethShares == steth_share

        event = next(e for e in tx.events if isinstance(e, StvStETHPool.Transfer))
        assert event.from_ == user.address
        assert event.to == Address.ZERO
        assert event.value == stv_can_be_burn_for_user

        if stv_to_burn > stv_can_be_burn_for_user:
            event = next(
                e for e in tx.events if isinstance(e, StvStETHPool.SocializedLoss)
            )
            assert event.maxLossSocializationBP == 10000  # constant for this test.
            assert event.stv == stv_to_burn - stv_can_be_burn_for_user

        else:
            assert False == any(
                e for e in tx.events if isinstance(e, StvStETHPool.SocializedLoss)
            )

        self.pool_balance[user] -= stv_can_be_burn_for_user
        self.user_minted_shares[user] -= steth_share

        self.native_balance[self.staking_vault] -= steth_value  # 1:1 with eth
        self.native_balance[self.vault_hub] += steth_value

        self.pool_total_asset -= steth_value
        self.pool_total_supply -= stv_can_be_burn_for_user
        # only user holding stv burns makes remaining to be burn socialize to everyone

        logger.info(f"Force rebalance called for {user}")

    @flow()
    def flow_rebalance_unassigned_liability(self):
        unassigned_liability_share = self.pool.totalUnassignedLiabilityShares()
        if unassigned_liability_share <= 0:
            return "no unassigned liability"

        self.pool.rebalanceUnassignedLiability(
            _stethShares=unassigned_liability_share, from_=random_account()
        )

        logger.info(
            f"Rebalanced unassigned liability of {unassigned_liability_share} stETH shares"
        )

        breakpoint()

    @flow()
    def flow_sync_vault_parameters(self):

        tx = self.stv_steth_pool.syncVaultParameters()

        # the vault hub is mock, and it does not change any value for now.

    def stv_to_value(self, stv: int) -> int:
        return stv * self.pool_total_asset // self.pool_total_supply

    @invariant()
    def inv_preview_rebalance(self):
        for user in self.pool_balance:
            if self.pool_balance[user] == 0:
                continue

            tx = self.stv_steth_pool.previewForceRebalance(user, request_type="tx")

            steth_share, stv, is_undercollateralized = tx.return_value

            user_stv = self.pool_balance[user]
            user_stv_value = self.stv_to_value(user_stv)
            user_steth_share = self.user_minted_shares[user]
            user_rounded_up_steth_value = self.steth.getPooledEthBySharesRoundUp(
                user_steth_share
            )

            assets_threshold = -(
                -user_rounded_up_steth_value
                * 10000
                // (10000 - self.forced_rebalance_threshold_bp)
            )  # 1000 is threshold, round up

            is_breached = user_stv_value < assets_threshold
            if not is_breached:
                assert steth_share == 0
                assert stv == 0
                assert is_undercollateralized == False
                continue

            reserve_ratio_bp = self.reserve_ratio_bp
            stethliability = user_rounded_up_steth_value

            target_steth_value_to_rebalance = (
                stethliability * 10000 - (10000 - reserve_ratio_bp) * user_stv_value
            ) // reserve_ratio_bp

            # giving user this value of steth, and buring this value of stv.

            if target_steth_value_to_rebalance > stethliability:
                target_steth_value_to_rebalance = stethliability
                assert is_undercollateralized == True

            steth_to_rebalance_limit_in_value = (
                self.stv_steth_pool.totalExceedingMintedSteth()
                + self.staking_vault.availableBalance()
            )
            steth_to_rebalance_in_value = min(
                target_steth_value_to_rebalance, steth_to_rebalance_limit_in_value
            )

            if self.pool_total_asset == 0:
                return
            # rounding up
            stv_required = -(
                -steth_to_rebalance_in_value
                * self.pool_total_supply
                // self.pool_total_asset
            )

            assert steth_share == self.steth.getSharesByPooledEth(
                steth_to_rebalance_in_value
            )
            assert stv == min(stv_required, user_stv)

            # if steth_share == 0 and stv == 0 and is_undercollateralized == True:
            #     breakpoint() # THIs happen when vault does not have liqudity. carefully watch the vault state.

    @invariant()
    def inv_steht_never_be_negative(self):
        for user in self.steth_shares:
            assert self.steth_shares[user] >= 0

    @invariant()
    def inv_steth_balance(self):
        for account in self.steth_shares:
            assert self.steth_shares[account] == self.steth.sharesOf(account)

        for account in self.wsteth_balance:
            assert self.wsteth_balance[account] == self.wsteth.balanceOf(account)

    @invariant()
    def inv_steth_shares(self):
        for account in self.steth_shares:
            assert self.user_minted_shares[
                account
            ] == self.stv_steth_pool.mintedStethSharesOf(account)

    @flow()
    def flow_steth_value_changes(self):

        self.steth.mock_accrueYield(random_int(0, 10**14))  # up to 1 ETH yield
        logger.info("mock value up for stETH")

    @invariant()
    def inv_user_minting_steth_capablity(self):

        assets = random_int(10**18, 32 * 10**18)  # 1 to 32 ETH

        # 1 ETH and ho much stETH shares can be mint?
        # print(tx.call_trace)
        tx = self.stv_steth_pool.calcStethSharesToMintForAssets(
            assets, request_type="tx"
        )
        oc_steth_share = tx.return_value
        mintable_steth_with_eth_value = (
            assets * (TOTAL_BASIS_POINTS - self.bp_ratio) // TOTAL_BASIS_POINTS
        )
        # print(mintable_steth_with_eth_value)
        # print(self.bp_ratio)
        tx = self.steth.getSharesByPooledEth(
            mintable_steth_with_eth_value, request_type="tx"
        )  # Out of scope for now.
        # print(tx.call_trace)
        steth_shares = tx.return_value
        assert oc_steth_share == steth_shares

    @invariant()
    def inv_calc_assets_to_lock_for_steth_shares(self):

        lock_share = self.stv_steth_pool.calcAssetsToLockForStethShares(10**18)

        in_asset = self.steth.getPooledEthBySharesRoundUp(
            10**18
        )  # assetsToLock in the code
        # asset to lock vlaue is calculated with ceil. round

        asset_tobe_locked = -(
            (-in_asset * TOTAL_BASIS_POINTS) // (TOTAL_BASIS_POINTS - self.bp_ratio)
        )

        assert lock_share == asset_tobe_locked

        pass

    @invariant()
    def inv_reserve_ratio_bp(self):
        assert self.reserve_ratio_bp == self.stv_steth_pool.reserveRatioBP()

    @invariant()
    def inv_forced_rebalance_threshold_bp(self):
        assert (
            self.forced_rebalance_threshold_bp
            == self.stv_steth_pool.forcedRebalanceThresholdBP()
        )

    @invariant()
    def print_user_acocunt_status(self):
        for user in chain.accounts:
            (stv, steth_share, is_undercollateralized) = (
                self.stv_steth_pool.previewForceRebalance(user.address)
            )

            logger.info(
                f"""user {user.address} stv: {stv} steth_share:
            {steth_share} is_undercollateralized: {is_undercollateralized}"""
            )

    @invariant()
    def inv_total_minted_steth_share(self):
        assert (
            sum(self.user_minted_shares.values())
            == self.stv_steth_pool.totalMintedStethShares()
        )

    @invariant()
    def inv_total_exceeding_minted_steth_shares(self):
        assert (
            sum(self.user_minted_shares.values())
            - sum(self.user_minted_shares.values())
            == self.stv_steth_pool.totalExceedingMintedStethShares()
        )

    @override
    @invariant()
    def inv_pool_info(self):
        total_liablity = 0
        for acc in chain.accounts:
            total_liablity += self.user_minted_shares[acc]

        assert total_liablity == self.pool.totalLiabilityShares()

    # @override
    @invariant()
    def inv_total_unassigned_liability_steth(self):
        total_liability_shares = self.pool.totalLiabilityShares()
        assert (
            total_liability_shares == self.dashboard.liabilityShares()
        )  # In actual implemntation


@chain.connect()
@on_revert(revert_handler)
def test_fuzz_stethpool():
    FuzzStEthPoool().run(10, 100000)
