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

contract DeployPool is Script {
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
        json = vm.serializeAddress("_intermediate", "pool", intermediate.pool);
        json = vm.serializeAddress("_intermediate", "timelock", intermediate.timelock);
        json = vm.serializeAddress("_intermediate", "strategyFactory", intermediate.strategyFactory);
    }

    function _serializeDeployment(Factory.StvPoolDeployment memory deployment)
        internal
        returns (string memory json)
    {
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
        Factory.AuxiliaryPoolConfig memory auxiliaryConfig,
        bytes32 poolType
    ) internal returns (string memory json) {
        StvPool pool = StvPool(payable(intermediate.pool));
        address dashboard = address(pool.DASHBOARD());
        address withdrawalQueue = address(pool.WITHDRAWAL_QUEUE());
        address distributor = address(pool.DISTRIBUTOR());

        bytes memory poolCtorBytecode = abi.encodePacked(
            type(OssifiableProxy).creationCode,
            abi.encode(factory.DUMMY_IMPLEMENTATION(), address(factory), bytes(""))
        );

        bytes memory poolImplementationCtorBytecode;
        if (poolType == factory.STV_POOL_TYPE()) {
            poolImplementationCtorBytecode = abi.encodePacked(
                type(StvPool).creationCode,
                abi.encode(
                    dashboard,
                    auxiliaryConfig.allowlistEnabled,
                    withdrawalQueue,
                    distributor
                )
            );
        } else {
            poolImplementationCtorBytecode = abi.encodePacked(
                type(StvStETHPool).creationCode,
                abi.encode(
                    dashboard,
                    auxiliaryConfig.allowlistEnabled,
                    auxiliaryConfig.reserveRatioGapBP,
                    withdrawalQueue,
                    distributor,
                    poolType
                )
            );
        }

        address withdrawalImpl = IOssifiableProxy(withdrawalQueue).proxy__getImplementation();
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

    function _loadIntermediate(string memory path) internal view returns (Factory.StvPoolIntermediate memory) {
        string memory json = vm.readFile(path);
        return Factory.StvPoolIntermediate({
            pool: vm.parseJsonAddress(json, "$.intermediate.pool"),
            timelock: vm.parseJsonAddress(json, "$.intermediate.timelock"),
            strategyFactory: vm.parseJsonAddress(json, "$.intermediate.strategyFactory")
        });
    }

    function _loadPoolParams(string memory path) internal view returns (PoolParams memory) {
        string memory json = vm.readFile(path);
        return PoolParams({
            vaultConfig: Factory.VaultConfig({
                nodeOperator: vm.parseJsonAddress(json, "$.config.vaultConfig.nodeOperator"),
                nodeOperatorManager: vm.parseJsonAddress(json, "$.config.vaultConfig.nodeOperatorManager"),
                nodeOperatorFeeBP: vm.parseJsonUint(json, "$.config.vaultConfig.nodeOperatorFeeBP"),
                confirmExpiry: vm.parseJsonUint(json, "$.config.vaultConfig.confirmExpiry")
            }),
            commonPoolConfig: Factory.CommonPoolConfig({
                minWithdrawalDelayTime: vm.parseJsonUint(json, "$.config.commonPoolConfig.minWithdrawalDelayTime"),
                name: vm.parseJsonString(json, "$.config.commonPoolConfig.name"),
                symbol: vm.parseJsonString(json, "$.config.commonPoolConfig.symbol")
            }),
            auxiliaryPoolConfig: Factory.AuxiliaryPoolConfig({
                allowlistEnabled: vm.parseJsonBool(json, "$.config.auxiliaryPoolConfig.allowlistEnabled"),
                mintingEnabled: vm.parseJsonBool(json, "$.config.auxiliaryPoolConfig.mintingEnabled"),
                reserveRatioGapBP: vm.parseJsonUint(json, "$.config.auxiliaryPoolConfig.reserveRatioGapBP")
            }),
            timelockConfig: Factory.TimelockConfig({
                minDelaySeconds: vm.parseJsonUint(json, "$.config.timelockConfig.minDelaySeconds"),
                executor: vm.parseJsonAddress(json, "$.config.timelockConfig.executor")
            }),
            strategyFactory: vm.parseJsonAddress(json, "$.config.strategyFactory"),
            connectDepositWei: vm.parseJsonUint(json, "$.config.connectDepositWei")
        });
    }

    function run() external {
        string memory factoryAddress = vm.envString("FACTORY_ADDRESS");
        string memory deployMode = vm.envOr("DEPLOY_MODE", string(""));

        require(bytes(factoryAddress).length != 0, "FACTORY_ADDRESS env var must be set and non-empty");
        Factory factory = Factory(vm.parseAddress(factoryAddress));

        string memory intermediateJsonPath = vm.envOr("INTERMEDIATE_JSON", _buildOutputPath());

        if (keccak256(bytes(deployMode)) == keccak256(bytes("start"))) {
            _runStart(factory, intermediateJsonPath);
        } else if (keccak256(bytes(deployMode)) == keccak256(bytes("finish"))) {
            _runFinish(factory, intermediateJsonPath);
        } else {
            _runStart(factory, intermediateJsonPath);
            _runFinish(factory, intermediateJsonPath);
        }
    }

    function _runStart(Factory factory, string memory intermediateJsonPath) internal {
        require(!vm.isFile(intermediateJsonPath), string(abi.encodePacked("Intermediate JSON file already exists at: ", intermediateJsonPath)));

        string memory paramsJsonPath = vm.envString("POOL_PARAMS_JSON");
        require(bytes(paramsJsonPath).length != 0, "POOL_PARAMS_JSON env var must be set and non-empty");
        if (!vm.isFile(paramsJsonPath)) {
            revert(string(abi.encodePacked("POOL_PARAMS_JSON file does not exist at: ", paramsJsonPath)));
        }

        require(msg.sender.balance > 1 ether, "msg.sender balance must be above 1 ether");

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

        vm.stopBroadcast();

        console2.log("Intermediate:");
        console2.log("  pool:", intermediate.pool);
        console2.log("  timelock:", intermediate.timelock);
        console2.log("  strategyFactory:", intermediate.strategyFactory);

        // Save config and intermediate to output file
        string memory configJson = _serializeConfig(p);
        string memory intermediateJson = _serializeIntermediate(intermediate);

        string memory rootJson = vm.serializeString("_deploy", "config", configJson);
        rootJson = vm.serializeString("_deploy", "intermediate", intermediateJson);

        vm.writeJson(rootJson, intermediateJsonPath);
        console2.log("\nDeployment intermediate saved to:", intermediateJsonPath);
    }

    function _runFinish(Factory factory, string memory intermediateJsonPath) internal {
        require(bytes(intermediateJsonPath).length != 0, "INTERMEDIATE_JSON env var must be set and non-empty");
        if (!vm.isFile(intermediateJsonPath)) {
            revert(string(abi.encodePacked("INTERMEDIATE_JSON file does not exist at: ", intermediateJsonPath)));
        }

        Factory.StvPoolIntermediate memory intermediate = _loadIntermediate(intermediateJsonPath);
        PoolParams memory p = _loadPoolParams(intermediateJsonPath);

        StvPool pool = StvPool(payable(intermediate.pool));
        bytes32 poolType = pool.poolType();

        vm.startBroadcast();

        factory.createPoolFinish(intermediate);

        vm.stopBroadcast();

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
        console2.log("  minWithdrawalDelayTime:", p.commonPoolConfig.minWithdrawalDelayTime);
        console2.log("  reserveRatioGapBP:", p.auxiliaryPoolConfig.reserveRatioGapBP);
        console2.log("  strategyFactory:", p.strategyFactory);
        console2.log("  connectDepositWei:", p.connectDepositWei);

        // console2.log("\nDeployment addresses:");
        // console2.log("  Vault:", deployment.vault);
        // console2.log("  Dashboard:", deployment.dashboard);
        // console2.log("  Pool:", deployment.pool);
        // console2.log("  WithdrawalQueue:", deployment.withdrawalQueue);
        // console2.log("  Distributor:", deployment.distributor);
        // console2.log("  Timelock:", deployment.timelock);
        // console2.log("  Strategy:", deployment.strategy);

        // // Read existing intermediate file and update with deployment
        // string memory configJson = _serializeConfig(p);
        // string memory intermediateJson = _serializeIntermediate(intermediate);
        // string memory deploymentJson = _serializeDeployment(deployment);
        // string memory ctorJson = _serializeCtorBytecode(factory, intermediate, p.vaultConfig, p.auxiliaryPoolConfig, poolType);

        // string memory rootJson = vm.serializeString("_deploy", "config", configJson);
        // rootJson = vm.serializeString("_deploy", "intermediate", intermediateJson);
        // rootJson = vm.serializeString("_deploy", "deployment", deploymentJson);
        // rootJson = vm.serializeString("_deploy", "ctorBytecode", ctorJson);

        // vm.writeJson(rootJson, intermediateJsonPath);
        // console2.log("\nDeployment completed and saved to:", intermediateJsonPath);
    }

}
