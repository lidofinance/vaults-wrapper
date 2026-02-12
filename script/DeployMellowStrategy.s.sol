// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Factory} from "src/Factory.sol";

contract DeployMellowStrategy is Script {
    struct MellowConfig {
        address vault;
        address syncDepositQueue;
        address asyncDepositQueue;
        address asyncRedeemQueue;
    }

    struct DeployParams {
        Factory.VaultConfig vaultConfig;
        Factory.CommonPoolConfig commonPoolConfig;
        Factory.AuxiliaryPoolConfig auxiliaryPoolConfig;
        Factory.TimelockConfig timelockConfig;
        address strategyFactory;
        uint256 connectDepositWei;
        MellowConfig mellow;
    }

    function _buildOutputPath() internal view returns (string memory) {
        return string(
            abi.encodePacked(
                "deployments/mellow-pool-intermediate-",
                vm.toString(block.chainid),
                "-",
                vm.toString(block.timestamp),
                ".json"
            )
        );
    }

    function _encodeMellowDeployBytes(MellowConfig memory _cfg) internal pure returns (bytes memory) {
        return abi.encode(_cfg.vault, _cfg.syncDepositQueue, _cfg.asyncDepositQueue, _cfg.asyncRedeemQueue);
    }

    function _validate(DeployParams memory _p) internal pure {
        require(bytes(_p.commonPoolConfig.name).length != 0, "commonPoolConfig.name missing");
        require(bytes(_p.commonPoolConfig.symbol).length != 0, "commonPoolConfig.symbol missing");
        require(_p.strategyFactory != address(0), "strategyFactory missing");
        require(_p.connectDepositWei > 0, "connectDepositWei missing");

        require(_p.auxiliaryPoolConfig.allowListEnabled, "allowListEnabled must be true for strategy pool");
        require(_p.auxiliaryPoolConfig.mintingEnabled, "mintingEnabled must be true for strategy pool");

        require(_p.mellow.vault != address(0), "mellow.vault missing");
        require(_p.mellow.asyncRedeemQueue != address(0), "mellow.asyncRedeemQueue missing");
        require(
            _p.mellow.syncDepositQueue != address(0) || _p.mellow.asyncDepositQueue != address(0),
            "at least one mellow deposit queue must be set"
        );
    }

    function _serializeVaultConfig(Factory.VaultConfig memory _cfg) internal returns (string memory json) {
        json = vm.serializeAddress("_vaultConfig", "nodeOperator", _cfg.nodeOperator);
        json = vm.serializeAddress("_vaultConfig", "nodeOperatorManager", _cfg.nodeOperatorManager);
        json = vm.serializeUint("_vaultConfig", "nodeOperatorFeeBP", _cfg.nodeOperatorFeeBP);
        json = vm.serializeUint("_vaultConfig", "confirmExpiry", _cfg.confirmExpiry);
    }

    function _serializeCommonPoolConfig(Factory.CommonPoolConfig memory _cfg) internal returns (string memory json) {
        json = vm.serializeUint("_commonPoolConfig", "minWithdrawalDelayTime", _cfg.minWithdrawalDelayTime);
        json = vm.serializeString("_commonPoolConfig", "name", _cfg.name);
        json = vm.serializeString("_commonPoolConfig", "symbol", _cfg.symbol);
        json = vm.serializeAddress("_commonPoolConfig", "emergencyCommittee", _cfg.emergencyCommittee);
    }

    function _serializeAuxiliaryPoolConfig(Factory.AuxiliaryPoolConfig memory _cfg)
        internal
        returns (string memory json)
    {
        json = vm.serializeBool("_auxiliaryPoolConfig", "allowListEnabled", _cfg.allowListEnabled);
        json = vm.serializeAddress("_auxiliaryPoolConfig", "allowListManager", _cfg.allowListManager);
        json = vm.serializeBool("_auxiliaryPoolConfig", "mintingEnabled", _cfg.mintingEnabled);
        json = vm.serializeUint("_auxiliaryPoolConfig", "reserveRatioGapBP", _cfg.reserveRatioGapBP);
    }

    function _serializeTimelockConfig(Factory.TimelockConfig memory _cfg) internal returns (string memory json) {
        json = vm.serializeUint("_timelockConfig", "minDelaySeconds", _cfg.minDelaySeconds);
        json = vm.serializeAddress("_timelockConfig", "proposer", _cfg.proposer);
        json = vm.serializeAddress("_timelockConfig", "executor", _cfg.executor);
    }

    function _serializeMellowConfig(MellowConfig memory _cfg) internal returns (string memory json) {
        json = vm.serializeAddress("_mellow", "vault", _cfg.vault);
        json = vm.serializeAddress("_mellow", "syncDepositQueue", _cfg.syncDepositQueue);
        json = vm.serializeAddress("_mellow", "asyncDepositQueue", _cfg.asyncDepositQueue);
        json = vm.serializeAddress("_mellow", "asyncRedeemQueue", _cfg.asyncRedeemQueue);
    }

    function _serializeConfig(DeployParams memory _p) internal returns (string memory json) {
        string memory vaultJson = _serializeVaultConfig(_p.vaultConfig);
        string memory commonJson = _serializeCommonPoolConfig(_p.commonPoolConfig);
        string memory auxiliaryJson = _serializeAuxiliaryPoolConfig(_p.auxiliaryPoolConfig);
        string memory timelockJson = _serializeTimelockConfig(_p.timelockConfig);
        string memory mellowJson = _serializeMellowConfig(_p.mellow);

        json = vm.serializeString("_deployConfig", "vaultConfig", vaultJson);
        json = vm.serializeString("_deployConfig", "commonPoolConfig", commonJson);
        json = vm.serializeString("_deployConfig", "auxiliaryPoolConfig", auxiliaryJson);
        json = vm.serializeString("_deployConfig", "timelockConfig", timelockJson);
        json = vm.serializeAddress("_deployConfig", "strategyFactory", _p.strategyFactory);
        json = vm.serializeUint("_deployConfig", "connectDepositWei", _p.connectDepositWei);
        json = vm.serializeString("_deployConfig", "mellow", mellowJson);
    }

    function _serializeIntermediate(Factory.PoolIntermediate memory _intermediate)
        internal
        returns (string memory json)
    {
        json = vm.serializeAddress("_intermediate", "dashboard", _intermediate.dashboard);
        json = vm.serializeAddress("_intermediate", "poolProxy", _intermediate.poolProxy);
        json = vm.serializeAddress("_intermediate", "poolImpl", _intermediate.poolImpl);
        json = vm.serializeAddress("_intermediate", "withdrawalQueueProxy", _intermediate.withdrawalQueueProxy);
        json = vm.serializeAddress("_intermediate", "wqImpl", _intermediate.wqImpl);
        json = vm.serializeAddress("_intermediate", "timelock", _intermediate.timelock);
    }

    function _serializeDeployment(Factory.PoolDeployment memory _deployment) internal returns (string memory json) {
        json = vm.serializeAddress("_deployment", "vault", _deployment.vault);
        json = vm.serializeAddress("_deployment", "dashboard", _deployment.dashboard);
        json = vm.serializeAddress("_deployment", "pool", _deployment.pool);
        json = vm.serializeAddress("_deployment", "withdrawalQueue", _deployment.withdrawalQueue);
        json = vm.serializeAddress("_deployment", "distributor", _deployment.distributor);
        json = vm.serializeAddress("_deployment", "timelock", _deployment.timelock);
        json = vm.serializeAddress("_deployment", "strategy", _deployment.strategy);
    }

    function _readParams(string memory _path) internal view returns (DeployParams memory p) {
        require(vm.isFile(_path), string(abi.encodePacked("MELLOW_POOL_PARAMS_JSON file does not exist at: ", _path)));

        string memory json = vm.readFile(_path);

        p.vaultConfig = Factory.VaultConfig({
            nodeOperator: vm.parseJsonAddress(json, "$.vaultConfig.nodeOperator"),
            nodeOperatorManager: vm.parseJsonAddress(json, "$.vaultConfig.nodeOperatorManager"),
            nodeOperatorFeeBP: vm.parseJsonUint(json, "$.vaultConfig.nodeOperatorFeeBP"),
            confirmExpiry: vm.parseJsonUint(json, "$.vaultConfig.confirmExpiry")
        });

        p.commonPoolConfig = Factory.CommonPoolConfig({
            minWithdrawalDelayTime: vm.parseJsonUint(json, "$.commonPoolConfig.minWithdrawalDelayTime"),
            name: vm.parseJsonString(json, "$.commonPoolConfig.name"),
            symbol: vm.parseJsonString(json, "$.commonPoolConfig.symbol"),
            emergencyCommittee: vm.parseJsonAddress(json, "$.commonPoolConfig.emergencyCommittee")
        });

        p.auxiliaryPoolConfig = Factory.AuxiliaryPoolConfig({
            allowListEnabled: vm.parseJsonBool(json, "$.auxiliaryPoolConfig.allowListEnabled"),
            allowListManager: vm.parseJsonAddress(json, "$.auxiliaryPoolConfig.allowListManager"),
            mintingEnabled: vm.parseJsonBool(json, "$.auxiliaryPoolConfig.mintingEnabled"),
            reserveRatioGapBP: vm.parseJsonUint(json, "$.auxiliaryPoolConfig.reserveRatioGapBP")
        });

        p.timelockConfig = Factory.TimelockConfig({
            minDelaySeconds: vm.parseJsonUint(json, "$.timelockConfig.minDelaySeconds"),
            proposer: vm.parseJsonAddress(json, "$.timelockConfig.proposer"),
            executor: vm.parseJsonAddress(json, "$.timelockConfig.executor")
        });

        p.connectDepositWei = vm.parseJsonUint(json, "$.connectDepositWei");

        p.mellow = MellowConfig({
            vault: vm.parseJsonAddress(json, "$.mellow.vault"),
            syncDepositQueue: vm.parseJsonAddress(json, "$.mellow.syncDepositQueue"),
            asyncDepositQueue: vm.parseJsonAddress(json, "$.mellow.asyncDepositQueue"),
            asyncRedeemQueue: vm.parseJsonAddress(json, "$.mellow.asyncRedeemQueue")
        });

        p.strategyFactory = vm.parseJsonAddress(json, "$.strategyFactory");
    }

    function _loadIntermediate(string memory _path) internal view returns (Factory.PoolIntermediate memory) {
        string memory json = vm.readFile(_path);
        return Factory.PoolIntermediate({
            dashboard: vm.parseJsonAddress(json, "$.intermediate.dashboard"),
            poolProxy: vm.parseJsonAddress(json, "$.intermediate.poolProxy"),
            poolImpl: vm.parseJsonAddress(json, "$.intermediate.poolImpl"),
            withdrawalQueueProxy: vm.parseJsonAddress(json, "$.intermediate.withdrawalQueueProxy"),
            wqImpl: vm.parseJsonAddress(json, "$.intermediate.wqImpl"),
            timelock: vm.parseJsonAddress(json, "$.intermediate.timelock")
        });
    }

    function _readIntermediateDeployParams(string memory _path) internal view returns (DeployParams memory p) {
        string memory json = vm.readFile(_path);

        p = DeployParams({
            vaultConfig: Factory.VaultConfig({
                nodeOperator: vm.parseJsonAddress(json, "$.config.vaultConfig.nodeOperator"),
                nodeOperatorManager: vm.parseJsonAddress(json, "$.config.vaultConfig.nodeOperatorManager"),
                nodeOperatorFeeBP: vm.parseJsonUint(json, "$.config.vaultConfig.nodeOperatorFeeBP"),
                confirmExpiry: vm.parseJsonUint(json, "$.config.vaultConfig.confirmExpiry")
            }),
            commonPoolConfig: Factory.CommonPoolConfig({
                minWithdrawalDelayTime: vm.parseJsonUint(json, "$.config.commonPoolConfig.minWithdrawalDelayTime"),
                name: vm.parseJsonString(json, "$.config.commonPoolConfig.name"),
                symbol: vm.parseJsonString(json, "$.config.commonPoolConfig.symbol"),
                emergencyCommittee: vm.parseJsonAddress(json, "$.config.commonPoolConfig.emergencyCommittee")
            }),
            auxiliaryPoolConfig: Factory.AuxiliaryPoolConfig({
                allowListEnabled: vm.parseJsonBool(json, "$.config.auxiliaryPoolConfig.allowListEnabled"),
                allowListManager: vm.parseJsonAddress(json, "$.config.auxiliaryPoolConfig.allowListManager"),
                mintingEnabled: vm.parseJsonBool(json, "$.config.auxiliaryPoolConfig.mintingEnabled"),
                reserveRatioGapBP: vm.parseJsonUint(json, "$.config.auxiliaryPoolConfig.reserveRatioGapBP")
            }),
            timelockConfig: Factory.TimelockConfig({
                minDelaySeconds: vm.parseJsonUint(json, "$.config.timelockConfig.minDelaySeconds"),
                proposer: vm.parseJsonAddress(json, "$.config.timelockConfig.proposer"),
                executor: vm.parseJsonAddress(json, "$.config.timelockConfig.executor")
            }),
            strategyFactory: vm.parseJsonAddress(json, "$.config.strategyFactory"),
            connectDepositWei: vm.parseJsonUint(json, "$.config.connectDepositWei"),
            mellow: MellowConfig({
                vault: vm.parseJsonAddress(json, "$.config.mellow.vault"),
                syncDepositQueue: vm.parseJsonAddress(json, "$.config.mellow.syncDepositQueue"),
                asyncDepositQueue: vm.parseJsonAddress(json, "$.config.mellow.asyncDepositQueue"),
                asyncRedeemQueue: vm.parseJsonAddress(json, "$.config.mellow.asyncRedeemQueue")
            })
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

    function _runStart(Factory _factory, string memory _intermediateJsonPath) internal {
        require(
            !vm.isFile(_intermediateJsonPath),
            string(abi.encodePacked("Intermediate JSON file already exists at: ", _intermediateJsonPath))
        );

        string memory paramsJsonPath = vm.envString("MELLOW_POOL_PARAMS_JSON");
        require(bytes(paramsJsonPath).length != 0, "MELLOW_POOL_PARAMS_JSON env var must be set and non-empty");

        require(msg.sender.balance > 1 ether, "msg.sender balance must be above 1 ether");

        DeployParams memory p = _readParams(paramsJsonPath);
        _validate(p);

        bytes memory strategyDeployBytes = _encodeMellowDeployBytes(p.mellow);

        vm.startBroadcast();

        Factory.PoolIntermediate memory intermediate = _factory.createPoolStart(
            p.vaultConfig,
            p.timelockConfig,
            p.commonPoolConfig,
            p.auxiliaryPoolConfig,
            p.strategyFactory,
            strategyDeployBytes
        );

        vm.stopBroadcast();

        string memory configJson = _serializeConfig(p);
        string memory intermediateJson = _serializeIntermediate(intermediate);

        string memory rootJson = vm.serializeString("_deploy", "config", configJson);
        rootJson = vm.serializeString("_deploy", "intermediate", intermediateJson);
        rootJson = vm.serializeString("_deploy", "network", vm.toString(block.chainid));

        vm.writeJson(rootJson, _intermediateJsonPath);

        console2.log("Mellow pool deployment started");
        console2.log("  strategyFactory:", p.strategyFactory);
        console2.log("  dashboard:", intermediate.dashboard);
        console2.log("  poolProxy:", intermediate.poolProxy);
        console2.log("  withdrawalQueueProxy:", intermediate.withdrawalQueueProxy);
        console2.log("  timelock:", intermediate.timelock);
        console2.log("Saved intermediate to", _intermediateJsonPath);
    }

    function _runFinish(Factory _factory, string memory _intermediateJsonPath) internal {
        require(bytes(_intermediateJsonPath).length != 0, "INTERMEDIATE_JSON env var must be set and non-empty");
        if (!vm.isFile(_intermediateJsonPath)) {
            revert(string(abi.encodePacked("INTERMEDIATE_JSON file does not exist at: ", _intermediateJsonPath)));
        }

        Factory.PoolIntermediate memory intermediate = _loadIntermediate(_intermediateJsonPath);
        DeployParams memory p = _readIntermediateDeployParams(_intermediateJsonPath);
        _validate(p);

        bytes memory strategyDeployBytes = _encodeMellowDeployBytes(p.mellow);

        vm.startBroadcast();

        Factory.PoolDeployment memory deployment = _factory.createPoolFinish{value: p.connectDepositWei}(
            p.vaultConfig,
            p.timelockConfig,
            p.commonPoolConfig,
            p.auxiliaryPoolConfig,
            p.strategyFactory,
            strategyDeployBytes,
            intermediate
        );

        vm.stopBroadcast();

        string memory configJson = _serializeConfig(p);
        string memory intermediateJson = _serializeIntermediate(intermediate);
        string memory deploymentJson = _serializeDeployment(deployment);

        string memory rootJson = vm.serializeString("_deploy", "config", configJson);
        rootJson = vm.serializeString("_deploy", "intermediate", intermediateJson);
        rootJson = vm.serializeString("_deploy", "deployment", deploymentJson);
        rootJson = vm.serializeString("_deploy", "network", vm.toString(block.chainid));

        vm.writeJson(rootJson, "deployments/mellow-pool-latest.json");
        if (keccak256(bytes(_intermediateJsonPath)) != keccak256(bytes("deployments/mellow-pool-latest.json"))) {
            vm.removeFile(_intermediateJsonPath);
        }

        console2.log("Mellow pool deployment finished");
        console2.log("  vault:", deployment.vault);
        console2.log("  pool:", deployment.pool);
        console2.log("  withdrawalQueue:", deployment.withdrawalQueue);
        console2.log("  strategy:", deployment.strategy);
        console2.log("Removed intermediate", _intermediateJsonPath);
        console2.log("Also updated", "deployments/mellow-pool-latest.json");
    }
}
