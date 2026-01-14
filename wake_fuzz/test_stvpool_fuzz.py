from dataclasses import dataclass
from wake.testing import *
from wake.testing.fuzzing import *

from pytypes.src.Factory import Factory
from pytypes.src.factories.DistributorFactory import DistributorFactory
from pytypes.src.factories.GGVStrategyFactory import GGVStrategyFactory
from pytypes.src.factories.StvPoolFactory import StvPoolFactory
from pytypes.src.factories.StvStETHPoolFactory import StvStETHPoolFactory
from pytypes.src.factories.TimelockFactory import TimelockFactory
from pytypes.src.factories.WithdrawalQueueFactory import WithdrawalQueueFactory
from pytypes.src.proxy.DummyImplementation import DummyImplementation
from pytypes.wake_fuzz.mocks.MockStETH import MockStETH
from pytypes.wake_fuzz.mocks.MockLazyOracle import MockLazyOracle
from pytypes.wake_fuzz.mocks.MockLidoLocator import MockLidoLocator
from pytypes.wake_fuzz.mocks.MockVaultFactory import MockVaultFactory
from pytypes.wake_fuzz.mocks.MockVaultHub import MockVaultHub
from pytypes.src.StvPool import StvPool
from pytypes.src.StvStETHPool import StvStETHPool
from pytypes.src.WithdrawalQueue import WithdrawalQueue
from pytypes.src.interfaces.core.IDashboard import IDashboard
from pytypes.wake_fuzz.mocks.MockStakingVault import MockStakingVault
from pytypes.wake_fuzz.mocks.MockDashboard import MockDashboard
from pytypes.wake_fuzz.mocks.MockWstETH import MockWstETH

from collections import defaultdict
from collections.abc import Callable


import logging

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


# Print failing tx call trace
def revert_handler(e: RevertError):
    if e.tx is not None:
        print(e.tx.call_trace)


@dataclass
class NodeOperatorInfo:
    amount: int
    reward_slash: int


@dataclass
class WQData:
    request_id: uint256
    owner: Address
    stv_amount: uint256
    steth_shares_amount: uint256
    asset_amount: uint256
    start_timestamp: uint256  # timestamp when queued
    fulfilled: bool
    claimed: bool


class FuzzPool(FuzzTest):
    deployer: Account
    admin: Account
    node_operator: Account
    node_operator_manager: Account

    connect_deposit: int

    vault_hub: MockVaultHub
    vault_factory: MockVaultFactory
    steth: MockStETH
    wsteth: MockWstETH
    lazy_oracle: MockLazyOracle
    locator: MockLidoLocator
    staking_vault: MockStakingVault

    stv_pool_factory: StvPoolFactory
    stv_steth_pool_factory: StvStETHPoolFactory
    withdrawal_queue_factory: WithdrawalQueueFactory
    distributor_factory: DistributorFactory
    ggv_strategy_factory: GGVStrategyFactory
    timelock_factory: TimelockFactory

    wrapper_factory: Factory
    pool: StvPool
    withdrawal_queue: WithdrawalQueue

    pool_balance: dict[Account, int]

    withdrawal_queue_requests: dict[uint256, WQData]
    finalized_request: int

    last_checkpoint_index: int
    gas_cost_for_each_withdrawal_request: int

    pool_total_supply: int
    pool_total_asset: int

    node_operators: list[NodeOperatorInfo]

    ## TO BE OVERRIDEN
    def pool_build_configs(
        self,
    ) -> tuple[
        Factory.VaultConfig, Factory.CommonPoolConfig, Factory.AuxiliaryPoolConfig
    ]:
        return self.build_configs(False, False, 0, "Factory STV Pool", "FSTV")

    ## TO BE OBERRRIDEN
    def past_pool_specific_config(
        self, deployment: Factory.PoolDeployment, deploy_tx: TransactionAbc
    ):
        self.pool = StvPool(deployment.pool)
        assert self.withdrawal_queue.IS_REBALANCING_SUPPORTED() == False

    def pre_sequence(self) -> None:
        """Deploy mock environment and create a pool before fuzz sequence runs."""

        self.deployer = chain.accounts[0]
        self.admin = chain.accounts[1]
        self.node_operator = chain.accounts[2]
        self.node_operator_manager = chain.accounts[3]

        self.connect_deposit = 10**18
        self.gas_cost_for_each_withdrawal_request = 0
        self.node_operators = []

        self.pool_balance = defaultdict(int)
        self.native_balance = defaultdict(int)
        for acc in chain.accounts:
            self.native_balance[acc] = acc.balance

        self.pool_total_supply = 0
        self.pool_total_asset = 0

        self.vault_hub = MockVaultHub.deploy(from_=self.deployer)

        self.steth = MockStETH(self.vault_hub.LIDO())
        self.wsteth = MockWstETH.deploy(_stETH=self.steth.address, from_=self.deployer)
        self.vault_factory = MockVaultFactory.deploy(
            self.vault_hub.address, self.wsteth.address, from_=self.deployer
        )

        self.lazy_oracle = MockLazyOracle.deploy(from_=self.deployer)

        self.locator = MockLidoLocator.deploy(
            self.steth.address,
            self.wsteth.address,
            self.lazy_oracle.address,
            self.vault_hub.address,
            self.vault_factory.address,
            from_=self.deployer,
        )

        self.stv_pool_factory = StvPoolFactory.deploy(from_=self.deployer)
        self.stv_steth_pool_factory = StvStETHPoolFactory.deploy(from_=self.deployer)
        self.withdrawal_queue_factory = WithdrawalQueueFactory.deploy(
            from_=self.deployer
        )
        self.distributor_factory = DistributorFactory.deploy(from_=self.deployer)
        dummy_teller = DummyImplementation.deploy(from_=self.deployer)
        dummy_queue = DummyImplementation.deploy(from_=self.deployer)
        self.ggv_strategy_factory = GGVStrategyFactory.deploy(
            dummy_teller.address, dummy_queue.address, from_=self.deployer
        )
        self.timelock_factory = TimelockFactory.deploy(from_=self.deployer)

        sub_factories = Factory.SubFactories(
            stvPoolFactory=self.stv_pool_factory.address,
            stvStETHPoolFactory=self.stv_steth_pool_factory.address,
            withdrawalQueueFactory=self.withdrawal_queue_factory.address,
            distributorFactory=self.distributor_factory.address,
            ggvStrategyFactory=self.ggv_strategy_factory.address,
            timelockFactory=self.timelock_factory.address,
        )

        self.wrapper_factory = Factory.deploy(
            self.locator.address, sub_factories, from_=self.deployer
        )

        (
            vault_config,
            common_pool_config,
            auxiliary_config,
        ) = self.pool_build_configs()  # to be overriden
        timelock_config = self.default_timelock_config()
        strategy_factory = Address.ZERO

        self.admin.balance += self.connect_deposit

        self.native_balance[self.admin] += self.connect_deposit

        tx = self.wrapper_factory.createPoolStart(
            _vaultConfig=vault_config,
            _timelockConfig=timelock_config,
            _commonPoolConfig=common_pool_config,
            _auxiliaryConfig=auxiliary_config,
            _strategyFactory=strategy_factory,
            _strategyDeployBytes=b"",
            from_=self.admin,
        )
        print(tx.call_trace)
        intermediate = tx.return_value
        event = next(
            e for e in tx.events if isinstance(e, MockVaultFactory.VaultCreated)
        )
        self.staking_vault = MockStakingVault(event.vault)

        event = next(
            e for e in tx.events if isinstance(e, MockVaultFactory.DashboardCreated)
        )
        self.dashboard = MockDashboard(event.dashboard)

        self.dashboard.initialize()

        assert self.dashboard.WSTETH().address == self.wsteth.address

        tx = self.wrapper_factory.createPoolFinish(
            _vaultConfig=vault_config,
            _timelockConfig=timelock_config,
            _commonPoolConfig=common_pool_config,
            _auxiliaryConfig=auxiliary_config,
            _strategyFactory=strategy_factory,
            _strategyDeployBytes=b"",
            _intermediate=intermediate,
            value=self.connect_deposit,
            from_=self.admin,
        )
        print(tx.call_trace)

        self.pool_total_supply = self.connect_deposit * 10 ** (27 - 18)
        self.native_balance[self.admin] -= self.connect_deposit
        self.native_balance[self.staking_vault] += self.connect_deposit
        self.pool_total_asset += self.connect_deposit

        deployment = tx.return_value

        self.withdrawal_queue = WithdrawalQueue(deployment.withdrawalQueue)
        self.withdrawal_queue_requests = dict()
        self.finalized_request = 0  # not id but count

        self.last_checkpoint_index = 0

        self.past_pool_specific_config(deployment, tx)

    def build_configs(
        self,
        allowlist_enabled: bool,
        minting_enabled: bool,
        reserve_ratio_gap_bp: uint256,
        name: str,
        symbol: str,
    ) -> tuple[
        Factory.VaultConfig, Factory.CommonPoolConfig, Factory.AuxiliaryPoolConfig
    ]:
        vault_config = Factory.VaultConfig(
            nodeOperator=self.node_operator.address,
            nodeOperatorManager=self.node_operator_manager.address,
            nodeOperatorFeeBP=100,
            confirmExpiry=3600,
        )

        common_pool_config = Factory.CommonPoolConfig(
            minWithdrawalDelayTime=24 * 60 * 60,
            name=name,
            symbol=symbol,
            emergencyCommittee=Address.ZERO,
        )

        auxiliary_config = Factory.AuxiliaryPoolConfig(
            allowlistEnabled=allowlist_enabled,
            mintingEnabled=minting_enabled,
            reserveRatioGapBP=reserve_ratio_gap_bp,
        )

        return vault_config, common_pool_config, auxiliary_config

    def default_timelock_config(self) -> Factory.TimelockConfig:
        return Factory.TimelockConfig(
            minDelaySeconds=0,
            proposer=self.deployer.address,
            executor=self.admin.address,
        )

    @flow(weight=90)
    def deposit_eth(self):

        # if self.flow_num > 1000:
        #     return

        user = random_account()
        referral = random_account()
        recipient = random_account()

        amount = random_int(10**15, 10**20)
        user.balance += amount
        self.native_balance[user] += amount

        # previewDeposit
        expected = amount * self.pool_total_supply // self.pool_total_asset

        # uint256 totalValueInStethShares = _getSharesByPooledEth(VAULT_HUB.totalValue(address(VAULT)));
        # if (totalValueInStethShares < totalLiabilityShares()) revert VaultInBadDebt();

        total_value = self.vault_hub.totalValue(self.staking_vault.address)
        total_share = self.steth.getSharesByPooledEth(total_value)
        total_liability_shares = self.pool.totalLiabilityShares()
        if total_share < total_liability_shares:
            return "Vault in bad debt"

        if random_bool():
            tx = self.pool.depositETH(
                _recipient=recipient, _referral=referral, from_=user, value=amount
            )
        else:
            recipient = user
            referral = Account(Address.ZERO)
            tx = self.pool.transact(from_=user, value=amount)

        event = next(e for e in tx.events if isinstance(e, StvPool.Deposit))
        assert event.sender == user.address
        assert event.recipient == recipient.address
        assert event.referral == referral.address
        assert event.assets == amount
        assert event.stv == expected

        self.pool_total_supply += expected
        self.native_balance[user] -= amount
        self.pool_balance[recipient] += expected
        self.native_balance[self.staking_vault] += amount
        self.pool_total_asset += amount

        logger.info(
            f"Deposited {amount} ETH for {expected} pool tokens to {user.address}"
        )

    @flow()
    def flow_withdraw_req(self) -> str | None:

        # previewWithdraw
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

        amount_stv = random_int(stv_estimated_amount, self.pool_balance[user])

        # previewRedeem
        asset_amount = amount_stv * self.pool_total_asset // self.pool_total_supply
        # round down -> asset reamin in staking pool
        #  -> everyone can withdraw
        # -> token value is increase, this is not problem

        # # check minted stEthShare for this
        # self.minted_steth_shares

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

    def calc_request_amounts(
        self,
        current_request: WQData,
        current_checkpoint_stv_rate: int,
        current_checkpoint_steth_share_rate: int,
        current_checkpoint_gas_cost_coverage: int,
    ) -> tuple[int, int, int, int, int]:
        """
        Python port of WithdrawalQueue._calcRequestAmounts.

        Returns (stv, assets_to_claim, steth_shares_to_rebalance, assets_to_rebalance, gas_cost_coverage).
        """
        # Constants defined in WithdrawalQueue.sol
        E27_PRECISION_BASE = 10**27
        E36_PRECISION_BASE = 10**36

        stv = int(current_request.stv_amount)
        steth_shares_to_rebalance = int(current_request.steth_shares_amount)
        assets_to_claim = int(current_request.asset_amount)

        # Calculate stv rate at the time of request creation
        request_stv_rate = (assets_to_claim * E36_PRECISION_BASE) // stv

        # Apply discount if the request stv rate is above the finalization stv rate
        if request_stv_rate > current_checkpoint_stv_rate:
            assets_to_claim = stv * current_checkpoint_stv_rate // E36_PRECISION_BASE

        assets_to_rebalance = 0
        if steth_shares_to_rebalance > 0:
            # Ceil
            assets_to_rebalance = (
                -(-steth_shares_to_rebalance * current_checkpoint_steth_share_rate)
                // E27_PRECISION_BASE
            )

            assets_to_claim = max(0, assets_to_claim - assets_to_rebalance)

        gas_cost_coverage = 0
        if current_checkpoint_gas_cost_coverage > 0:
            gas_cost_coverage = min(
                assets_to_claim, current_checkpoint_gas_cost_coverage
            )
            assets_to_claim -= gas_cost_coverage

        return (
            stv,
            assets_to_claim,
            steth_shares_to_rebalance,
            assets_to_rebalance,
            gas_cost_coverage,
        )

    @flow()
    def flow_finalize(self):
        max_request = random_int(1, 100)

        currnent_checkpoint_stv_rate = self.withdrawal_queue.calculateCurrentStvRate()
        current_checkpoint_steth_share_rate = (
            self.withdrawal_queue.calculateCurrentStethShareRate()
        )
        current_checkpoint_gas_cost_coverage = self.gas_cost_for_each_withdrawal_request

        withdrawal_value = self.dashboard.withdrawableValue()
        available_balance = self.staking_vault.availableBalance()
        latest_report_timestamp = self.lazy_oracle.latestReportTimestamp()

        ########################################

        finalized_requests_count = 0
        eth_to_rebalance = 0
        withdrawable_value = 0
        total_eth_to_claim = 0
        total_gas_coverage = 0
        total_stv_to_burn = 0
        total_steth_share = 0
        max_stv_to_rebalance = 0

        for request in self.withdrawal_queue_requests.values():
            if request.claimed:
                continue

            if request.fulfilled:
                continue

            if finalized_requests_count >= max_request:
                break

            curr_request = request

            (
                stv,
                eth_to_claim,
                steth_shares_to_rebalance,
                steth_to_rebalance,
                gas_cost_coverage,
            ) = self.calc_request_amounts(
                curr_request,
                currnent_checkpoint_stv_rate,
                current_checkpoint_steth_share_rate,
                current_checkpoint_gas_cost_coverage,
            )
            # reimplement _calcRequestAmounts function.
            # checkpoint variable is exist as indivisual variables
            # as currnent_checkpoint_* fucntions.

            stv_to_rebalance = 0

            if steth_to_rebalance > 0:
                stv_to_rebalance = (
                    steth_to_rebalance * 10**36 // currnent_checkpoint_stv_rate
                )
                if stv_to_rebalance > stv:
                    stv_to_rebalance = stv

                exceedingSteth = 0

                eth_to_rebalance = steth_to_rebalance - exceedingSteth

            if (
                (eth_to_claim + gas_cost_coverage) > withdrawal_value
                or eth_to_claim + eth_to_rebalance + gas_cost_coverage
                > available_balance
                or curr_request.start_timestamp + 24 * 60 * 60
                > chain.blocks["pending"].timestamp
                or curr_request.start_timestamp > latest_report_timestamp
            ):
                break

            withdrawable_value -= eth_to_claim + gas_cost_coverage
            available_balance -= eth_to_claim + gas_cost_coverage + eth_to_rebalance
            total_eth_to_claim += eth_to_claim
            total_gas_coverage += gas_cost_coverage
            total_stv_to_burn += stv - stv_to_rebalance
            total_steth_share += steth_shares_to_rebalance
            max_stv_to_rebalance += stv_to_rebalance
            finalized_requests_count += 1

            ## Especially handle native token handing in here. after here,
            # check the price of stvStETHPool tokne. and replace with mock function as much as possible to real.
            ## ALso other functionality can be randomized related to mock contracts.

        total_eth_to_withdraw = total_eth_to_claim + total_gas_coverage

        gas_coverage_recipient = random_account()

        with may_revert() as err:
            tx = self.withdrawal_queue.finalize(
                _maxRequests=max_request,
                _gasCostCoverageRecipient=gas_coverage_recipient,
                from_=self.node_operator,
            )

        if finalized_requests_count == 0:
            assert err.value == WithdrawalQueue.NoRequestsToFinalize()
            return "no finalizable requests"

        assert err.value is None

        logger.info(f"total-eth-to-withdraw: {total_eth_to_withdraw}")

        finalized_events = [
            e for e in tx.events if isinstance(e, WithdrawalQueue.WithdrawalsFinalized)
        ]
        assert len(finalized_events) == 1
        finalized_event = finalized_events[0]

        assert finalized_event.ethLocked == total_eth_to_claim  # why named ethLocked
        assert finalized_event.ethForGasCoverage == total_gas_coverage
        assert finalized_event.stvBurned == total_stv_to_burn
        assert finalized_event.stvRebalanced == 0
        assert finalized_event.stethSharesRebalanced == 0

        self.pool_balance[self.withdrawal_queue] -= total_stv_to_burn  # burn
        self.pool_total_supply -= total_stv_to_burn  # burn stv

        self.native_balance[self.staking_vault] -= total_eth_to_withdraw
        self.native_balance[self.withdrawal_queue] += total_eth_to_withdraw
        self.pool_total_asset -= total_eth_to_withdraw
        self.native_balance[self.withdrawal_queue] -= total_gas_coverage
        self.native_balance[gas_coverage_recipient] += total_gas_coverage

        assert (
            finalized_requests_count == finalized_event.to - finalized_event.from_ + 1
        )

        for i in range(finalized_event.from_, finalized_event.to + 1):
            request = self.withdrawal_queue_requests[uint256(i)]
            request.fulfilled = True
            self.withdrawal_queue_requests[uint256(i)] = request

        self.last_checkpoint_index += 1

        logger.info(
            f"Finalized requests from {finalized_event.from_} to {finalized_event.to}"
        )

    @flow()
    def update_latest_report_timestamp(self):

        self.lazy_oracle.mock__updateLatestReportTimestamp(
            _timestamp=chain.blocks["pending"].timestamp, from_=self.deployer
        )

    @flow()
    def flow_deposit_to_beacon_mock(self):
        amount = 32 * 10**18

        if self.native_balance[self.staking_vault] <= amount:
            return "lack of native balance"

        self.staking_vault.withdraw(Address.ZERO, amount)  # any # just transfer to user

        self.native_balance[self.staking_vault] -= amount

        self.node_operators.append(
            NodeOperatorInfo(
                amount=amount,
                reward_slash=0,
            )
        )

        logger.info(f"mock beacon deposit {amount}")

    @flow()
    def flow_simulate_reward(self):

        if self.flow_num < 200:
            return "skip"

        if len(self.node_operators) == 0:
            return "no node operator"

        reward_slash = random_int(-(10**20), 10**16, min_prob=0.8)
        # reward_slash = - 10**20

        # self.native_balance[self.staking_vault]

        node_operator = random.choice(self.node_operators)

        if node_operator.amount + node_operator.reward_slash + reward_slash < 0:
            reward_slash = -(
                node_operator.amount + node_operator.reward_slash
            )  # avoid negative total

        self.dashboard.mock_simulateRewards(reward_slash)
        self.pool_total_asset += reward_slash

        node_operator.reward_slash += reward_slash
        logger.info(f"mock beacon chain reward/slash {reward_slash}")

    @flow()
    def flow_withdraw_from_beacon(self):

        if len(self.node_operators) == 0:
            return "no node operator"

        low_node = [
            node
            for node in self.node_operators
            if node.amount + node.reward_slash <= 16 * 10**18
        ]
        target_list = []
        if low_node:
            target_list = low_node
        else:
            target_list = self.node_operators

        withdrawing_node = random.choice(target_list)
        amount = withdrawing_node.amount + withdrawing_node.reward_slash
        self.staking_vault.balance += amount
        self.native_balance[self.staking_vault] += amount

        self.node_operators.remove(withdrawing_node)

        logger.info(f"mock beacon withdraw amount with {amount}")

    @flow()
    def flow_set_finalization_gas_cost_coverage(self):

        gas_cost_for_each_withdrawal_request = random_int(0, 5 * 10**14)

        tx = self.withdrawal_queue.setFinalizationGasCostCoverage(
            _coverage=gas_cost_for_each_withdrawal_request, from_=self.node_operator
        )

        event = next(
            e for e in tx.events if isinstance(e, WithdrawalQueue.GasCostCoverageSet)
        )
        assert event.newCoverage == gas_cost_for_each_withdrawal_request

        self.gas_cost_for_each_withdrawal_request = gas_cost_for_each_withdrawal_request

        logger.info(
            f"Set finalization gas cost coverage {gas_cost_for_each_withdrawal_request}"
        )

    @flow()
    def flow_claim_withdrawal(self):

        claimable_requests: list[WQData] = []

        for r in self.withdrawal_queue_requests.values():
            if not r.fulfilled:
                continue
            if r.claimed:
                continue

            claimable_requests.append(r)

        if len(claimable_requests) == 0:
            return "no claimable requests"

        request = random.choice(claimable_requests)
        recipient = random_account()

        tx = self.withdrawal_queue.claimWithdrawal(
            _recipient=recipient,
            _requestId=request.request_id,
            from_=request.owner,
        )

        event = next(
            e for e in tx.events if isinstance(e, WithdrawalQueue.WithdrawalClaimed)
        )

        request.claimed = True

        self.native_balance[recipient] += event.amountOfETH
        self.native_balance[self.withdrawal_queue] -= event.amountOfETH
        self.withdrawal_queue_requests[request.request_id] = request

        logger.info(
            f"Claimed withdrawal request {request.request_id} to {recipient.address} amount {event.amountOfETH} ETH"
        )

    def pre_flow(self, flow: Callable):
        # logger.info(f"🚧 Flow: {flow.__name__}")
        return

    def post_invariants(self) -> None:
        if random_bool():
            chain.mine(lambda x: x + random_int(0, 1 * 60 * 60))

    @invariant()
    def invariant_balances(self):
        for acc in list(chain.accounts) + [
            self.staking_vault,
            self.withdrawal_queue,
            self.dashboard,
            self.vault_hub,
        ]:
            assert acc.balance == self.native_balance[acc]
            assert self.pool.balanceOf(acc) == self.pool_balance[acc]

            total_nomial_assets = self.pool.totalNominalAssets()

            assert (
                self.pool.assetsOf(acc)
                == self.pool.balanceOf(acc)
                * total_nomial_assets
                // self.pool_total_supply
            )

    @invariant()
    def inv_request_counts(self):
        last_finalized_request_id = self.withdrawal_queue.getLastFinalizedRequestId()
        last_request_id = self.withdrawal_queue.getLastRequestId()

        assert (
            last_request_id - last_finalized_request_id
            == self.withdrawal_queue.unfinalizedRequestsNumber()
        )

        assert len(self.withdrawal_queue_requests) == last_request_id

        if last_request_id == 0:
            return

        if last_finalized_request_id == 0:
            ## there is no finalized request.

            for i in range(1, last_request_id):
                assert self.withdrawal_queue_requests[i].fulfilled == False
        else:

            for i in range(1, last_finalized_request_id + 1):  # id start from 1
                assert self.withdrawal_queue_requests[i].fulfilled == True

            for i in range(last_finalized_request_id + 1, last_request_id + 1):
                assert self.withdrawal_queue_requests[i].fulfilled == False

        assert (
            self.last_checkpoint_index == self.withdrawal_queue.getLastCheckpointIndex()
        )

    @invariant()
    def inv_gas_coverage(self):
        assert (
            self.gas_cost_for_each_withdrawal_request
            == self.withdrawal_queue.getFinalizationGasCostCoverage()
        )

    @invariant()
    def inv_request_status(self):

        if self.withdrawal_queue.getLastRequestId() == 0:
            return

        for id in range(1, self.withdrawal_queue.getLastRequestId()):
            request = self.withdrawal_queue_requests[uint256(id)]
            onchain_request = self.withdrawal_queue.getWithdrawalStatus(id)

            assert request.stv_amount == onchain_request.amountOfStv
            assert request.owner == onchain_request.owner
            assert request.steth_shares_amount == onchain_request.amountOfStethShares
            assert request.fulfilled == onchain_request.isFinalized
            assert request.start_timestamp == onchain_request.timestamp
            assert onchain_request.isClaimed == request.claimed

    @invariant()
    def inv_pool_info(self):

        share = self.pool.totalLiabilityShares()

        assert share == self.pool.totalUnassignedLiabilitySteth()

        assert share == self.pool.totalUnassignedLiabilityShares()
        assert share == 0

    @invariant()
    def inv_pool_total_supply(self):
        assert self.pool_total_supply == self.pool.totalSupply()

    @invariant()
    def inv_pool_total_asset(self):
        nomial_assets = self.pool.totalNominalAssets()
        total_value = self.vault_hub.totalValue(
            self.staking_vault
        )  # maybe do deeply more
        assert nomial_assets == total_value

        assert self.pool_total_asset == self.pool.totalAssets()

    @invariant()
    def inv_unfinalized_amounts(self):

        if len(self.withdrawal_queue_requests) == 0:
            return
        stv_sum = sum(
            req.stv_amount
            for req in self.withdrawal_queue_requests.values()
            if not req.fulfilled and not req.claimed
        )

        assert stv_sum == self.withdrawal_queue.unfinalizedStv()

        assets_sum = sum(
            req.asset_amount
            for req in self.withdrawal_queue_requests.values()
            if not req.fulfilled and not req.claimed
        )

        assert assets_sum == self.withdrawal_queue.unfinalizedAssets()

    @invariant()
    def inv_queue_state(self):

        request: WQData | None = next(
            (
                r
                for r in reversed(self.withdrawal_queue_requests.values())
                if r.fulfilled
            ),
            None,
        )

        if request == None:
            assert self.withdrawal_queue.getLastFinalizedRequestId() == 0
        else:
            assert (
                self.withdrawal_queue.getLastFinalizedRequestId() == request.request_id
            )

        if len(self.withdrawal_queue_requests) == 0:
            assert 0 == self.withdrawal_queue.getLastRequestId()

        else:
            last_key = max(self.withdrawal_queue_requests)
            assert (
                self.withdrawal_queue_requests[last_key].request_id
                == self.withdrawal_queue.getLastRequestId()
            )

    @invariant()
    def status(self):
        un_fullfilled_requests = [
            r for r in self.withdrawal_queue_requests.values() if not r.fulfilled
        ]
        fullfilled_requests = [
            r for r in self.withdrawal_queue_requests.values() if r.fulfilled
        ]
        claimed_requests = [
            r for r in self.withdrawal_queue_requests.values() if r.claimed
        ]

        #############################
        logger.info(
            f"##################################################################"
        )
        logger.info(f"Unfulfilled requests: {len(un_fullfilled_requests)}")
        logger.info(
            f"Claimable requests  : {len(fullfilled_requests) - len(claimed_requests)}"
        )
        logger.info(f"Claimed requests    : {len(claimed_requests)}")

        currnet_rate = self.withdrawal_queue.calculateCurrentStvRate()
        logger.info(f"Current STV rate    : {currnet_rate} ({currnet_rate / 1e27})")
        logger.info(f"node operator {len(self.node_operators)}")


@chain.connect()
@on_revert(revert_handler)
def test_fuzz():
    FuzzPool().run(10, 100_000)
