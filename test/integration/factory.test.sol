// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {StvPoolHarness} from "test/utils/StvPoolHarness.sol";
import {Factory} from "src/Factory.sol";
import {FactoryHelper} from "test/utils/FactoryHelper.sol";
import {StvPool} from "src/StvPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IDashboard} from "src/interfaces/core/IDashboard.sol";
import {IOssifiableProxy} from "src/interfaces/core/IOssifiableProxy.sol";
import {Vm} from "forge-std/Vm.sol";

contract FactoryIntegrationTest is StvPoolHarness {
    Factory internal factory;

    function setUp() public {
        _initializeCore();

        FactoryHelper helper = new FactoryHelper();

        factory = helper.deployMainFactory(address(core.locator()), address(0), address(0));
    }

    function _buildConfigs(
        bool allowlistEnabled,
        bool mintingEnabled,
        uint256 reserveRatioGapBP,
        string memory name,
        string memory symbol
    )
        internal
        pure
        returns (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        )
    {
        vaultConfig = Factory.VaultConfig({
            nodeOperator: NODE_OPERATOR,
            nodeOperatorManager: NODE_OPERATOR,
            nodeOperatorFeeBP: 500,
            confirmExpiry: CONFIRM_EXPIRY
        });

        commonPoolConfig = Factory.CommonPoolConfig({
            minWithdrawalDelayTime: 1 days,
            name: name,
            symbol: symbol
        });

        auxiliaryConfig = Factory.AuxiliaryPoolConfig({
            allowlistEnabled: allowlistEnabled,
            mintingEnabled: mintingEnabled,
            reserveRatioGapBP: reserveRatioGapBP
        });

        timelockConfig = Factory.TimelockConfig({minDelaySeconds: 0, proposer: NODE_OPERATOR, executor: NODE_OPERATOR});
    }

    function _deployThroughFactory(
        Factory.VaultConfig memory vaultConfig,
        Factory.CommonPoolConfig memory commonPoolConfig,
        Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
        Factory.TimelockConfig memory timelockConfig,
        address strategyFactory
    ) internal returns (Factory.PoolIntermediate memory, Factory.PoolDeployment memory) {
        vm.startPrank(vaultConfig.nodeOperator);
        Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: CONNECT_DEPOSIT}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory,
            ""
        );
        Factory.PoolDeployment memory deployment = factory.createPoolFinish(
            vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, "", intermediate
        );
        vm.stopPrank();

        return (intermediate, deployment);
    }

    function test_createPoolStart_reverts_without_exact_connect_deposit() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Test Pool", "FT-STV");
        address strategyFactory = address(0);

        assertGt(CONNECT_DEPOSIT, 1, "CONNECT_DEPOSIT must be > 1 for this test");

        vm.startPrank(vaultConfig.nodeOperator);
        vm.expectRevert(
            abi.encodeWithSelector(
                Factory.InsufficientConnectDeposit.selector, CONNECT_DEPOSIT - 1, CONNECT_DEPOSIT
            )
        );
        factory.createPoolStart{value: CONNECT_DEPOSIT - 1}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory,
            ""
        );
        vm.stopPrank();
    }

    function test_createPool_without_minting_configures_roles() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory No Mint", "FNM");
        address strategyFactory = address(0);

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        assertEq(deployment.strategy, address(0), "strategy should not be deployed");

        IDashboard dashboard = IDashboard(payable(deployment.dashboard));
        StvPool pool = StvPool(payable(deployment.pool));

        assertTrue(
            dashboard.hasRole(dashboard.FUND_ROLE(), deployment.pool), "pool should have FUND_ROLE"
        );
        assertTrue(
            dashboard.hasRole(dashboard.WITHDRAW_ROLE(), deployment.withdrawalQueue),
            "withdrawal queue should have WITHDRAW_ROLE"
        );
        assertFalse(dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool), "mint role should not be granted");
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), deployment.timelock), "timelock should own pool");
    }

    function test_createPool_with_minting_grants_mint_and_burn_roles() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, true, 0, "Factory Mint Pool", "FMP");
        address strategyFactory = address(0);

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);


        IDashboard dashboard = IDashboard(payable(deployment.dashboard));

        assertTrue(dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool), "mint role should be granted");
        assertTrue(dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool), "burn role should be granted");
    }

    function test_createPool_with_strategy_deploys_strategy_and_allowlists_it() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(true, true, 500, "Factory Strategy Pool", "FSP");
        address strategyFactory = address(factory.GGV_STRATEGY_FACTORY());

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        assertTrue(deployment.strategy != address(0), "strategy should be deployed");

        StvPool pool = StvPool(payable(deployment.pool));
        assertTrue(pool.ALLOW_LIST_ENABLED(), "allowlist should be enabled");
        assertTrue(pool.isAllowListed(deployment.strategy), "strategy should be allowlisted");
    }

    function test_createPoolFinish_reverts_with_modified_intermediate() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Tamper", "FTAMP");

        address strategyFactory = address(0);

        vm.startPrank(vaultConfig.nodeOperator);
        Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: CONNECT_DEPOSIT}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory,
            ""
        );

        // Tamper with the intermediate before finishing to ensure the deployment hash is checked.
        intermediate.poolProxy = address(0xdead);

        vm.expectRevert(abi.encodeWithSelector(Factory.InvalidConfiguration.selector, "deploy not started"));
        factory.createPoolFinish(
            vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, "", intermediate
        );
        vm.stopPrank();
    }

    function test_createPoolFinish_reverts_with_different_sender() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Wrong Sender", "FWS");

        address strategyFactory = address(0);

        vm.startPrank(vaultConfig.nodeOperator);
        Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: CONNECT_DEPOSIT}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory,
            ""
        );
        vm.stopPrank();

        address otherSender = address(0xbeef);
        vm.expectRevert(abi.encodeWithSelector(Factory.InvalidConfiguration.selector, "deploy not started"));
        vm.prank(otherSender);
        factory.createPoolFinish(
            vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, "", intermediate
        );
    }

    function test_createPoolFinish_reverts_when_called_twice() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Double Finish", "FDF");

        address strategyFactory = address(0);

        vm.startPrank(vaultConfig.nodeOperator);
        Factory.PoolIntermediate memory intermediate = factory.createPoolStart{value: CONNECT_DEPOSIT}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory,
            ""
        );

        factory.createPoolFinish(
            vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, "", intermediate
        );

        // The intermediate hash is set to DEPLOY_COMPLETE after the first successful call; the second should fail.
        vm.expectRevert(abi.encodeWithSelector(Factory.InvalidConfiguration.selector, "deploy already finished"));
        factory.createPoolFinish(
            vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory, "", intermediate
        );
        vm.stopPrank();
    }

    function test_emits_pool_intermediate_created_event() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Event Pool", "FEP");
        address strategyFactory = address(0);

        vm.recordLogs();
        (Factory.PoolIntermediate memory intermediate,) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256(
            "PoolCreationStarted((address,address,address,address),uint256)"
        );

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(factory)) continue;
            if (entries[i].topics.length == 0 || entries[i].topics[0] != expectedTopic) continue;

            Factory.PoolIntermediate memory emitted =
                abi.decode(entries[i].data, (Factory.PoolIntermediate));
            assertEq(emitted.dashboard, intermediate.dashboard, "dashboard address should match");
            assertEq(emitted.poolProxy, intermediate.poolProxy, "poolProxy address should match");
            assertEq(emitted.withdrawalQueueProxy, intermediate.withdrawalQueueProxy, "withdrawalQueueProxy should match");
            assertEq(emitted.timelock, intermediate.timelock, "timelock should match");
            found = true;
            break;
        }

        assertTrue(found, "PoolIntermediateCreated event should be emitted");
    }

    function test_initial_acl_configuration_without_minting() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory ACL Pool", "FAP");
        address strategyFactory = address(0);

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        IDashboard dashboard = IDashboard(payable(deployment.dashboard));
        StvPool pool = StvPool(payable(deployment.pool));
        address timelock = deployment.timelock;

        // === Dashboard AccessControl Roles ===
        // Pool should have FUND_ROLE to fund the vault
        assertTrue(
            dashboard.hasRole(dashboard.FUND_ROLE(), deployment.pool),
            "pool should have FUND_ROLE on dashboard"
        );

        // Pool should have REBALANCE_ROLE to rebalance the vault
        assertTrue(
            dashboard.hasRole(dashboard.REBALANCE_ROLE(), deployment.pool),
            "pool should have REBALANCE_ROLE on dashboard"
        );

        // Withdrawal queue should have WITHDRAW_ROLE to withdraw from vault
        assertTrue(
            dashboard.hasRole(dashboard.WITHDRAW_ROLE(), deployment.withdrawalQueue),
            "withdrawal queue should have WITHDRAW_ROLE on dashboard"
        );

        // Without minting enabled, MINT_ROLE should not be granted
        assertFalse(
            dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool),
            "pool should not have MINT_ROLE when minting disabled"
        );

        // Without minting enabled, BURN_ROLE should not be granted
        assertFalse(
            dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool),
            "pool should not have BURN_ROLE when minting disabled"
        );

        // Timelock should have DEFAULT_ADMIN_ROLE on dashboard (set by VaultFactory)
        assertTrue(
            dashboard.hasRole(dashboard.DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on dashboard"
        );

        // === Pool (StvPool) AccessControl Roles ===
        // Timelock should have DEFAULT_ADMIN_ROLE on pool
        assertTrue(
            pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on pool"
        );

        // Factory should not retain admin role on pool
        assertFalse(
            pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), address(factory)),
            "factory should not have DEFAULT_ADMIN_ROLE on pool"
        );

        // === Proxy Ownership (OssifiableProxy) ===
        // Pool proxy should be owned by timelock
        assertEq(
            IOssifiableProxy(deployment.pool).proxy__getAdmin(),
            timelock,
            "pool proxy should be owned by timelock"
        );

        // Withdrawal queue proxy should be owned by timelock
        assertEq(
            IOssifiableProxy(deployment.withdrawalQueue).proxy__getAdmin(),
            timelock,
            "withdrawal queue proxy should be owned by timelock"
        );

        // === Distributor AccessControl Roles ===
        // Distributor should have timelock as DEFAULT_ADMIN_ROLE
        assertTrue(
            pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on distributor"
        );

        // Node operator manager should have MANAGER_ROLE on distributor
        assertTrue(
            pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().MANAGER_ROLE(), vaultConfig.nodeOperatorManager),
            "node operator manager should have MANAGER_ROLE on distributor"
        );

        // === Vault Ownership ===
        // Dashboard should be the owner of the vault (via VaultHub connection)
        // Note: Vault ownership is managed through VaultHub.vaultConnection(vault).owner
        assertEq(
            core.vaultHub().vaultConnection(address(pool.VAULT())).owner,
            deployment.dashboard,
            "dashboard should be the owner of the vault via VaultHub connection"
        );
    }

    function test_initial_acl_configuration_with_minting() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, true, 0, "Factory ACL Mint Pool", "FAMP");
        address strategyFactory = address(0);

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        IDashboard dashboard = IDashboard(payable(deployment.dashboard));

        // === Dashboard Minting Roles ===
        // With minting enabled, pool should have MINT_ROLE
        assertTrue(
            dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool),
            "pool should have MINT_ROLE when minting enabled"
        );

        // With minting enabled, pool should have BURN_ROLE
        assertTrue(
            dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool),
            "pool should have BURN_ROLE when minting enabled"
        );

        // Other roles should still be set correctly
        assertTrue(
            dashboard.hasRole(dashboard.FUND_ROLE(), deployment.pool),
            "pool should have FUND_ROLE on dashboard"
        );
        assertTrue(
            dashboard.hasRole(dashboard.REBALANCE_ROLE(), deployment.pool),
            "pool should have REBALANCE_ROLE on dashboard"
        );
        assertTrue(
            dashboard.hasRole(dashboard.WITHDRAW_ROLE(), deployment.withdrawalQueue),
            "withdrawal queue should have WITHDRAW_ROLE on dashboard"
        );
    }

    function test_initial_acl_configuration_with_strategy() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(true, true, 500, "Factory ACL Strategy Pool", "FASP");
        address strategyFactory = address(factory.GGV_STRATEGY_FACTORY());

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        IDashboard dashboard = IDashboard(payable(deployment.dashboard));
        StvPool pool = StvPool(payable(deployment.pool));
        address timelock = deployment.timelock;

        // === Strategy-specific checks ===
        // Strategy should be deployed
        assertTrue(deployment.strategy != address(0), "strategy should be deployed");

        // Strategy should be allowlisted on the pool
        assertTrue(pool.isAllowListed(deployment.strategy), "strategy should be allowlisted on pool");

        // Allowlist should be enabled
        assertTrue(pool.ALLOW_LIST_ENABLED(), "allowlist should be enabled for strategy pools");

        // === All standard ACL should still be in place ===
        assertTrue(
            dashboard.hasRole(dashboard.FUND_ROLE(), deployment.pool),
            "pool should have FUND_ROLE on dashboard"
        );
        assertTrue(
            dashboard.hasRole(dashboard.REBALANCE_ROLE(), deployment.pool),
            "pool should have REBALANCE_ROLE on dashboard"
        );
        assertTrue(
            dashboard.hasRole(dashboard.WITHDRAW_ROLE(), deployment.withdrawalQueue),
            "withdrawal queue should have WITHDRAW_ROLE on dashboard"
        );
        assertTrue(
            dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool),
            "pool should have MINT_ROLE when strategy enabled"
        );
        assertTrue(
            dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool),
            "pool should have BURN_ROLE when strategy enabled"
        );
        assertTrue(
            pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on pool"
        );
        assertTrue(
            dashboard.hasRole(dashboard.DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on dashboard"
        );
    }

    function test_withdrawal_queue_acl_configuration() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory WQ ACL", "FWQACL");
        address strategyFactory = address(0);

        (, Factory.PoolDeployment memory deployment) =
            _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

        WithdrawalQueue wq = WithdrawalQueue(payable(deployment.withdrawalQueue));
        address timelock = deployment.timelock;

        // === WithdrawalQueue AccessControl Roles ===
        // Timelock should have DEFAULT_ADMIN_ROLE
        assertTrue(
            wq.hasRole(wq.DEFAULT_ADMIN_ROLE(), timelock),
            "timelock should have DEFAULT_ADMIN_ROLE on withdrawal queue"
        );

        // Node operator should have FINALIZE_ROLE
        assertTrue(
            wq.hasRole(wq.FINALIZE_ROLE(), vaultConfig.nodeOperator),
            "node operator should have FINALIZE_ROLE on withdrawal queue"
        );

        // Factory should not retain any roles
        assertFalse(
            wq.hasRole(wq.DEFAULT_ADMIN_ROLE(), address(factory)),
            "factory should not have DEFAULT_ADMIN_ROLE on withdrawal queue"
        );

        // === WithdrawalQueue Proxy Ownership ===
        assertEq(
            IOssifiableProxy(deployment.withdrawalQueue).proxy__getAdmin(),
            timelock,
            "withdrawal queue proxy should be owned by timelock"
        );
    }
}
