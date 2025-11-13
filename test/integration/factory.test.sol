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

    function test_createPoolFinish_reverts_with_modified_config() public {
        (
            Factory.VaultConfig memory vaultConfig,
            Factory.CommonPoolConfig memory commonPoolConfig,
            Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
            Factory.TimelockConfig memory timelockConfig
        ) = _buildConfigs(false, false, 0, "Factory Tamper Config", "FTCFG");

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

        // Tamper with the configuration before finishing
        vaultConfig.nodeOperatorFeeBP = 999;

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

    function test_initial_acl_configuration() public {
        // Test all three pool types: StvPool (no minting), StvStETHPool (minting), and StvStrategyPool (strategy)
        for (uint256 i = 0; i < 3; i++) {
            bool allowlistEnabled = (i == 2);
            bool mintingEnabled = (i >= 1);
            uint256 reserveRatioGapBP = (i == 2) ? 500 : 0;
            address strategyFactory = (i == 2) ? address(factory.GGV_STRATEGY_FACTORY()) : address(0);

            string memory poolName = i == 0 ? "Factory StvPool" : i == 1 ? "Factory StvStETHPool" : "Factory StrategyPool";
            string memory poolSymbol = i == 0 ? "FSTV" : i == 1 ? "FSTETH" : "FSTRAT";

            (
                Factory.VaultConfig memory vaultConfig,
                Factory.CommonPoolConfig memory commonPoolConfig,
                Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
                Factory.TimelockConfig memory timelockConfig
            ) = _buildConfigs(allowlistEnabled, mintingEnabled, reserveRatioGapBP, poolName, poolSymbol);

            (, Factory.PoolDeployment memory deployment) =
                _deployThroughFactory(vaultConfig, commonPoolConfig, auxiliaryConfig, timelockConfig, strategyFactory);

            bytes32 poolType = factory.derivePoolType(auxiliaryConfig, strategyFactory);

            IDashboard dashboard = IDashboard(payable(deployment.dashboard));
            StvPool pool = StvPool(payable(deployment.pool));
            WithdrawalQueue wq = WithdrawalQueue(payable(deployment.withdrawalQueue));
            address timelock = deployment.timelock;
            address deployer = vaultConfig.nodeOperator;

            // === Verify pool type ===
            assertEq(deployment.poolType, poolType, "deployment pool type should match derived pool type");

            if (poolType == factory.STV_POOL_TYPE()) {
                assertEq(poolType, factory.STV_POOL_TYPE(), "pool type should be STV_POOL_TYPE");
            } else if (poolType == factory.STV_STETH_POOL_TYPE()) {
                assertEq(poolType, factory.STV_STETH_POOL_TYPE(), "pool type should be STV_STETH_POOL_TYPE");
            } else if (poolType == factory.STRATEGY_POOL_TYPE()) {
                assertEq(poolType, factory.STRATEGY_POOL_TYPE(), "pool type should be STRATEGY_POOL_TYPE");
            }

            // === Dashboard AccessControl Roles ===
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

            // Check minting roles based on pool type
            if (mintingEnabled) {
                assertTrue(
                    dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool),
                    "pool should have MINT_ROLE when minting enabled"
                );
                assertTrue(
                    dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool),
                    "pool should have BURN_ROLE when minting enabled"
                );
            } else {
                assertFalse(
                    dashboard.hasRole(dashboard.MINT_ROLE(), deployment.pool),
                    "pool should not have MINT_ROLE when minting disabled"
                );
                assertFalse(
                    dashboard.hasRole(dashboard.BURN_ROLE(), deployment.pool),
                    "pool should not have BURN_ROLE when minting disabled"
                );
            }

            assertTrue(
                dashboard.hasRole(dashboard.DEFAULT_ADMIN_ROLE(), timelock),
                "timelock should have DEFAULT_ADMIN_ROLE on dashboard"
            );

            // === Pool (StvPool) AccessControl Roles ===
            assertTrue(
                pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), timelock),
                "timelock should have DEFAULT_ADMIN_ROLE on pool"
            );
            assertFalse(
                pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), address(factory)),
                "factory should not have DEFAULT_ADMIN_ROLE on pool"
            );
            assertFalse(
                pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), deployer),
                "deployer should not have DEFAULT_ADMIN_ROLE on pool"
            );

            // === WithdrawalQueue AccessControl Roles ===
            assertTrue(
                wq.hasRole(wq.DEFAULT_ADMIN_ROLE(), timelock),
                "timelock should have DEFAULT_ADMIN_ROLE on withdrawal queue"
            );
            assertTrue(
                wq.hasRole(wq.FINALIZE_ROLE(), vaultConfig.nodeOperator),
                "node operator should have FINALIZE_ROLE on withdrawal queue"
            );
            assertFalse(
                wq.hasRole(wq.DEFAULT_ADMIN_ROLE(), address(factory)),
                "factory should not have DEFAULT_ADMIN_ROLE on withdrawal queue"
            );
            assertFalse(
                wq.hasRole(wq.DEFAULT_ADMIN_ROLE(), deployer),
                "deployer should not have DEFAULT_ADMIN_ROLE on withdrawal queue"
            );

            // === Proxy Ownership (OssifiableProxy) ===
            assertEq(
                IOssifiableProxy(deployment.pool).proxy__getAdmin(),
                timelock,
                "pool proxy should be owned by timelock"
            );
            assertNotEq(
                IOssifiableProxy(deployment.pool).proxy__getAdmin(),
                address(factory),
                "pool proxy should not be owned by factory"
            );
            assertNotEq(
                IOssifiableProxy(deployment.pool).proxy__getAdmin(),
                deployer,
                "pool proxy should not be owned by deployer"
            );

            assertEq(
                IOssifiableProxy(deployment.withdrawalQueue).proxy__getAdmin(),
                timelock,
                "withdrawal queue proxy should be owned by timelock"
            );
            assertNotEq(
                IOssifiableProxy(deployment.withdrawalQueue).proxy__getAdmin(),
                address(factory),
                "withdrawal queue proxy should not be owned by factory"
            );
            assertNotEq(
                IOssifiableProxy(deployment.withdrawalQueue).proxy__getAdmin(),
                deployer,
                "withdrawal queue proxy should not be owned by deployer"
            );

            // === Distributor AccessControl Roles ===
            assertTrue(
                pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().DEFAULT_ADMIN_ROLE(), timelock),
                "timelock should have DEFAULT_ADMIN_ROLE on distributor"
            );
            assertTrue(
                pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().MANAGER_ROLE(), vaultConfig.nodeOperatorManager),
                "node operator manager should have MANAGER_ROLE on distributor"
            );
            assertFalse(
                pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().DEFAULT_ADMIN_ROLE(), address(factory)),
                "factory should not have DEFAULT_ADMIN_ROLE on distributor"
            );
            assertFalse(
                pool.DISTRIBUTOR().hasRole(pool.DISTRIBUTOR().DEFAULT_ADMIN_ROLE(), deployer),
                "deployer should not have DEFAULT_ADMIN_ROLE on distributor"
            );

            // === Vault Ownership ===
            assertEq(
                core.vaultHub().vaultConnection(address(pool.VAULT())).owner,
                deployment.dashboard,
                "dashboard should be the owner of the vault via VaultHub connection"
            );

            // === Strategy-specific checks ===
            if (poolType == factory.STRATEGY_POOL_TYPE()) {
                assertTrue(deployment.strategy != address(0), "strategy should be deployed");
                assertTrue(pool.isAllowListed(deployment.strategy), "strategy should be allowlisted on pool");
                assertTrue(pool.ALLOW_LIST_ENABLED(), "allowlist should be enabled for strategy pools");
            } else {
                assertEq(deployment.strategy, address(0), "strategy should not be deployed for non-strategy pools");
            }
        }
    }


}
