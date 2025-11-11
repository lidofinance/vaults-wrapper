// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {StvPoolHarness} from "test/utils/StvPoolHarness.sol";
import {Factory, InsufficientConnectDeposit, InvalidConfiguration} from "src/Factory.sol";
import {FactoryHelper} from "test/utils/FactoryHelper.sol";
import {StvPool} from "src/StvPool.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
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

        timelockConfig = Factory.TimelockConfig({minDelaySeconds: 0, executor: NODE_OPERATOR});
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
            strategyFactory
        );
        Factory.PoolDeployment memory deployment = factory.createPoolFinish(intermediate);
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
                InsufficientConnectDeposit.selector, CONNECT_DEPOSIT, CONNECT_DEPOSIT - 1
            )
        );
        factory.createPoolStart{value: CONNECT_DEPOSIT - 1}(
            vaultConfig,
            commonPoolConfig,
            auxiliaryConfig,
            timelockConfig,
            strategyFactory
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

        (Factory.PoolIntermediate memory intermediate, Factory.PoolDeployment memory deployment) =
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

        (Factory.PoolIntermediate memory intermediate, Factory.PoolDeployment memory deployment) =
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

        (Factory.PoolIntermediate memory intermediate, Factory.PoolDeployment memory deployment) =
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
            strategyFactory
        );

        // Tamper with the intermediate before finishing to ensure the deployment hash is checked.
        intermediate.pool = address(0xdead);

        vm.expectRevert(abi.encodeWithSelector(InvalidConfiguration.selector, "deploy not started"));
        factory.createPoolFinish(intermediate);
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
            strategyFactory
        );
        vm.stopPrank();

        address otherSender = address(0xbeef);
        vm.expectRevert(abi.encodeWithSelector(InvalidConfiguration.selector, "deploy not started"));
        vm.prank(otherSender);
        factory.createPoolFinish(intermediate);
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
            strategyFactory
        );

        factory.createPoolFinish(intermediate);

        // The intermediate hash is set to DEPLOY_COMPLETE after the first successful call; the second should fail.
        vm.expectRevert(abi.encodeWithSelector(InvalidConfiguration.selector, "deploy already finished"));
        factory.createPoolFinish(intermediate);
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
            "PoolCreationStarted((address,address,address))"
        );

        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter != address(factory)) continue;
            if (entries[i].topics.length == 0 || entries[i].topics[0] != expectedTopic) continue;

            Factory.PoolIntermediate memory emitted =
                abi.decode(entries[i].data, (Factory.PoolIntermediate));
            assertEq(emitted.pool, intermediate.pool, "pool address should match");
            assertEq(emitted.timelock, intermediate.timelock, "timelock should match");
            assertEq(emitted.strategyFactory, intermediate.strategyFactory, "strategy factory should match");
            found = true;
            break;
        }

        assertTrue(found, "PoolIntermediateCreated event should be emitted");
    }
}
