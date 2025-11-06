// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Factory} from "src/Factory.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IOssifiableProxy} from "src/interfaces/IOssifiableProxy.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {StvPool} from "src/StvPool.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {IStETH} from "src/interfaces/IStETH.sol";

contract DeployWrapper is Script {
    struct PoolParams {
        Factory.VaultConfig vaultConfig;
        Factory.CommonPoolConfig commonPoolConfig;
        Factory.AuxiliaryPoolConfig auxiliaryPoolConfig;
        Factory.TimelockConfig timelockConfig;
        address strategyFactory;
        uint256 connectDepositWei;
    }

    function _readPoolParams(string memory path) internal view returns (PoolParams memory p) {
        string memory json = vm.readFile(path);
        p.vaultConfig = Factory.VaultConfig({
            nodeOperator: vm.parseJsonAddress(json, "$.vaultConfig.nodeOperator"),
            nodeOperatorManager: vm.parseJsonAddress(json, "$.vaultConfig.nodeOperatorManager"),
            nodeOperatorFeeBP: vm.parseJsonUint(json, "$.vaultConfig.nodeOperatorFeeBP"),
            confirmExpiry: vm.parseJsonUint(json, "$.vaultConfig.confirmExpiry")
        });

        p.commonPoolConfig = Factory.CommonPoolConfig({
            maxFinalizationTime: vm.parseJsonUint(json, "$.commonPoolConfig.maxFinalizationTime"),
            minWithdrawalDelayTime: vm.parseJsonUint(json, "$.commonPoolConfig.minWithdrawalDelayTime"),
            name: vm.parseJsonString(json, "$.commonPoolConfig.name"),
            symbol: vm.parseJsonString(json, "$.commonPoolConfig.symbol")
        });

        p.auxiliaryPoolConfig = Factory.AuxiliaryPoolConfig({
            allowlistEnabled: vm.parseJsonBool(json, "$.auxiliaryPoolConfig.allowlistEnabled"),
            mintingEnabled: vm.parseJsonBool(json, "$.auxiliaryPoolConfig.mintingEnabled"),
            reserveRatioGapBP: vm.parseJsonUint(json, "$.auxiliaryPoolConfig.reserveRatioGapBP")
        });

        p.timelockConfig = Factory.TimelockConfig({
            minDelaySeconds: vm.parseJsonUint(json, "$.timelockConfig.minDelaySeconds"),
            executor: vm.parseJsonAddress(json, "$.timelockConfig.executor")
        });

        p.connectDepositWei = vm.parseJsonUint(json, "$.connectDepositWei");

        try vm.parseJsonAddress(json, "$.strategyFactory") returns (address addr) {
            p.strategyFactory = addr;
        } catch {
            // Leave p.strategyFactory as default (address(0))
        }
    }

    function _buildOutputPath() internal view returns (string memory) {
        return string(
            abi.encodePacked(
                "deployments/pool-", vm.toString(block.chainid), "-", vm.toString(block.timestamp), ".json"
            )
        );
    }

    function _serializeVaultConfig(Factory.VaultConfig memory cfg) internal returns (string memory json) {
        json = vm.serializeAddress("_vaultConfig", "nodeOperator", cfg.nodeOperator);
        json = vm.serializeAddress("_vaultConfig", "nodeOperatorManager", cfg.nodeOperatorManager);
        json = vm.serializeUint("_vaultConfig", "nodeOperatorFeeBP", cfg.nodeOperatorFeeBP);
        json = vm.serializeUint("_vaultConfig", "confirmExpiry", cfg.confirmExpiry);
    }

    function _serializeCommonPoolConfig(Factory.CommonPoolConfig memory cfg) internal returns (string memory json) {
        json = vm.serializeUint("_commonPoolConfig", "maxFinalizationTime", cfg.maxFinalizationTime);
        json = vm.serializeUint("_commonPoolConfig", "minWithdrawalDelayTime", cfg.minWithdrawalDelayTime);
        json = vm.serializeString("_commonPoolConfig", "name", cfg.name);
        json = vm.serializeString("_commonPoolConfig", "symbol", cfg.symbol);
    }

    function _serializeAuxiliaryPoolConfig(Factory.AuxiliaryPoolConfig memory cfg)
        internal
        returns (string memory json)
    {
        json = vm.serializeBool("_auxiliaryPoolConfig", "allowlistEnabled", cfg.allowlistEnabled);
        json = vm.serializeBool("_auxiliaryPoolConfig", "mintingEnabled", cfg.mintingEnabled);
        json = vm.serializeUint("_auxiliaryPoolConfig", "reserveRatioGapBP", cfg.reserveRatioGapBP);
    }

    function _serializeTimelockConfig(Factory.TimelockConfig memory cfg) internal returns (string memory json) {
        json = vm.serializeUint("_timelockConfig", "minDelaySeconds", cfg.minDelaySeconds);
        json = vm.serializeAddress("_timelockConfig", "executor", cfg.executor);
    }

    function _serializeConfig(PoolParams memory p) internal returns (string memory json) {
        string memory vaultJson = _serializeVaultConfig(p.vaultConfig);
        string memory commonJson = _serializeCommonPoolConfig(p.commonPoolConfig);
        string memory auxiliaryJson = _serializeAuxiliaryPoolConfig(p.auxiliaryPoolConfig);
        string memory timelockJson = _serializeTimelockConfig(p.timelockConfig);

        json = vm.serializeString("_deployConfig", "vaultConfig", vaultJson);
        json = vm.serializeString("_deployConfig", "commonPoolConfig", commonJson);
        json = vm.serializeString("_deployConfig", "auxiliaryPoolConfig", auxiliaryJson);
        json = vm.serializeString("_deployConfig", "timelockConfig", timelockJson);
        json = vm.serializeAddress("_deployConfig", "strategyFactory", p.strategyFactory);
        json = vm.serializeUint("_deployConfig", "connectDepositWei", p.connectDepositWei);
    }

    function _serializeIntermediate(Factory.StvPoolIntermediate memory intermediate)
        internal
        returns (string memory json)
    {
        json = vm.serializeString("_intermediate", "poolType", vm.toString(intermediate.poolType));
        json = vm.serializeAddress("_intermediate", "vault", intermediate.vault);
        json = vm.serializeAddress("_intermediate", "dashboard", intermediate.dashboard);
        json = vm.serializeAddress("_intermediate", "pool", intermediate.pool);
        json = vm.serializeAddress("_intermediate", "withdrawalQueue", intermediate.withdrawalQueue);
        json = vm.serializeAddress("_intermediate", "distributor", intermediate.distributor);
        json = vm.serializeAddress("_intermediate", "timelock", intermediate.timelock);
        json = vm.serializeAddress("_intermediate", "strategyFactory", intermediate.strategyFactory);
    }

    function _serializeDeployment(Factory.StvPoolDeployment memory deployment)
        internal
        returns (string memory json)
    {
        json = vm.serializeString("_deployment", "poolType", vm.toString(deployment.poolType));
        json = vm.serializeAddress("_deployment", "vault", deployment.vault);
        json = vm.serializeAddress("_deployment", "dashboard", deployment.dashboard);
        json = vm.serializeAddress("_deployment", "pool", deployment.pool);
        json = vm.serializeAddress("_deployment", "withdrawalQueue", deployment.withdrawalQueue);
        json = vm.serializeAddress("_deployment", "distributor", deployment.distributor);
        json = vm.serializeAddress("_deployment", "timelock", deployment.timelock);
        json = vm.serializeAddress("_deployment", "strategy", deployment.strategy);
    }

    function _serializeCtorBytecode(
        Factory factory,
        Factory.StvPoolIntermediate memory intermediate,
        Factory.VaultConfig memory vaultConfig,
        Factory.AuxiliaryPoolConfig memory auxiliaryConfig
    ) internal returns (string memory json) {
        bytes memory poolCtorBytecode = abi.encodePacked(
            type(OssifiableProxy).creationCode,
            abi.encode(factory.DUMMY_IMPLEMENTATION(), address(factory), bytes(""))
        );

        bytes memory poolImplementationCtorBytecode;
        if (intermediate.poolType == factory.STV_POOL_TYPE()) {
            poolImplementationCtorBytecode = abi.encodePacked(
                type(StvPool).creationCode,
                abi.encode(
                    intermediate.dashboard,
                    auxiliaryConfig.allowlistEnabled,
                    intermediate.withdrawalQueue,
                    intermediate.distributor
                )
            );
        } else {
            poolImplementationCtorBytecode = abi.encodePacked(
                type(StvStETHPool).creationCode,
                abi.encode(
                    intermediate.dashboard,
                    auxiliaryConfig.allowlistEnabled,
                    auxiliaryConfig.reserveRatioGapBP,
                    intermediate.withdrawalQueue,
                    intermediate.distributor,
                    intermediate.poolType
                )
            );
        }

        address withdrawalImpl = IOssifiableProxy(intermediate.withdrawalQueue).proxy__getImplementation();
        bytes memory withdrawalInitData = abi.encodeCall(
            WithdrawalQueue.initialize,
            (vaultConfig.nodeOperatorManager, vaultConfig.nodeOperator)
        );
        bytes memory withdrawalCtorBytecode = abi.encodePacked(
            type(OssifiableProxy).creationCode,
            abi.encode(withdrawalImpl, intermediate.timelock, withdrawalInitData)
        );

        json = vm.serializeBytes("_ctorBytecode", "poolProxy", poolCtorBytecode);
        json = vm.serializeBytes("_ctorBytecode", "poolImplementation", poolImplementationCtorBytecode);
        json = vm.serializeBytes("_ctorBytecode", "withdrawalQueueProxy", withdrawalCtorBytecode);
    }

    function run() external {
        string memory factoryAddress = vm.envString("FACTORY_ADDRESS");
        string memory paramsJsonPath = vm.envString("POOL_PARAMS_JSON");

        require(bytes(factoryAddress).length != 0, "FACTORY_ADDRESS env var must be set and non-empty");
        require(bytes(paramsJsonPath).length != 0, "POOL_PARAMS_JSON env var must be set and non-empty");
        if (!vm.isFile(paramsJsonPath)) {
            revert(string(abi.encodePacked("POOL_PARAMS_JSON file does not exist at: ", paramsJsonPath)));
        }

        require(msg.sender.balance > 1 ether, "msg.sender balance must be above 1 ether");

        string memory outputJsonPath = _buildOutputPath();

        Factory factory = Factory(vm.parseAddress(factoryAddress));
        PoolParams memory p = _readPoolParams(paramsJsonPath);

        require(bytes(p.commonPoolConfig.name).length != 0, "commonPoolConfig.name missing");
        require(bytes(p.commonPoolConfig.symbol).length != 0, "commonPoolConfig.symbol missing");
        require(p.connectDepositWei > 0, "connectDepositWei missing");

        vm.startBroadcast();

        Factory.StvPoolIntermediate memory intermediate = factory.createPoolStart{value: p.connectDepositWei}(
            p.vaultConfig,
            p.commonPoolConfig,
            p.auxiliaryPoolConfig,
            p.timelockConfig,
            p.strategyFactory
        );
        console2.log("Intermediate:");
        console2.log("  vault:", intermediate.vault);
        console2.log("  dashboard:", intermediate.dashboard);
        console2.log("  pool:", intermediate.pool);
        console2.log("  withdrawalQueue:", intermediate.withdrawalQueue);
        console2.log("  distributor:", intermediate.distributor);
        console2.log("  timelock:", intermediate.timelock);

        Factory.StvPoolDeployment memory deployment = factory.createPoolFinish(intermediate);

        console2.log("Deploy config:");
        console2.log("  name:", p.commonPoolConfig.name);
        console2.log("  symbol:", p.commonPoolConfig.symbol);
        console2.log("  allowlistEnabled:", p.auxiliaryPoolConfig.allowlistEnabled);
        console2.log("  mintingEnabled:", p.auxiliaryPoolConfig.mintingEnabled);
        console2.log("  owner:", p.vaultConfig.nodeOperator);
        console2.log("  nodeOperator:", p.vaultConfig.nodeOperator);
        console2.log("  nodeOperatorManager:", p.vaultConfig.nodeOperatorManager);
        console2.log("  nodeOperatorFeeBP:", p.vaultConfig.nodeOperatorFeeBP);
        console2.log("  confirmExpiry:", p.vaultConfig.confirmExpiry);
        console2.log("  maxFinalizationTime:", p.commonPoolConfig.maxFinalizationTime);
        console2.log("  minWithdrawalDelayTime:", p.commonPoolConfig.minWithdrawalDelayTime);
        console2.log("  reserveRatioGapBP:", p.auxiliaryPoolConfig.reserveRatioGapBP);
        console2.log("  strategyFactory:", p.strategyFactory);
        console2.log("  connectDepositWei:", p.connectDepositWei);

        console2.log("Deployment Vault", deployment.vault);
        console2.log("Deployment Dashboard", deployment.dashboard);
        console2.log("Deployment Pool", deployment.pool);
        console2.log("Deployment WithdrawalQueue", deployment.withdrawalQueue);
        console2.log("Deployment Distributor", deployment.distributor);
        console2.log("Deployment Timelock", deployment.timelock);
        console2.log("Deployment PoolType", uint256(deployment.poolType));
        console2.log("Strategy", deployment.strategy);

        vm.stopBroadcast();

        // Prepare JSON artifacts
        string memory configJson = _serializeConfig(p);
        string memory intermediateJson = _serializeIntermediate(intermediate);
        string memory deploymentJson = _serializeDeployment(deployment);
        string memory ctorJson = _serializeCtorBytecode(factory, intermediate, p.vaultConfig, p.auxiliaryPoolConfig);

        string memory rootJson = vm.serializeString("_deploy", "config", configJson);
        rootJson = vm.serializeString("_deploy", "intermediate", intermediateJson);
        rootJson = vm.serializeString("_deploy", "deployment", deploymentJson);
        rootJson = vm.serializeString("_deploy", "ctorBytecode", ctorJson);

        vm.writeJson(rootJson, outputJsonPath);
        console2.log("Deployment artifact saved to", outputJsonPath);
    }
}
