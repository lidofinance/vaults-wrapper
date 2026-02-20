// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MellowStrategyFactory} from "src/factories/MellowStrategyFactory.sol";

contract DeployMellowStrategyFactory is Script {
    function _writePoolFactoryArtifacts(address _strategyFactory, string memory _poolFactoryJsonPath) internal {
        require(
            vm.isFile(_poolFactoryJsonPath),
            string(abi.encodePacked("POOL_FACTORY_DEPLOYMENT_JSON file does not exist at: ", _poolFactoryJsonPath))
        );

        string memory existing = vm.readFile(_poolFactoryJsonPath);

        string memory deployment = "";
        deployment = vm.serializeAddress("deployment", "factory", vm.parseJsonAddress(existing, "$.deployment.factory"));
        deployment = vm.serializeString("deployment", "network", vm.parseJsonString(existing, "$.deployment.network"));

        string memory factories = "";
        factories = vm.serializeAddress(
            "factories", "stvPoolFactory", vm.parseJsonAddress(existing, "$.factories.stvPoolFactory")
        );
        factories = vm.serializeAddress(
            "factories", "stvStETHPoolFactory", vm.parseJsonAddress(existing, "$.factories.stvStETHPoolFactory")
        );
        factories = vm.serializeAddress(
            "factories", "withdrawalQueueFactory", vm.parseJsonAddress(existing, "$.factories.withdrawalQueueFactory")
        );
        factories = vm.serializeAddress(
            "factories", "distributorFactory", vm.parseJsonAddress(existing, "$.factories.distributorFactory")
        );
        factories = vm.serializeAddress(
            "factories", "timelockFactory", vm.parseJsonAddress(existing, "$.factories.timelockFactory")
        );
        factories = vm.serializeAddress("factories", "mellowStrategyFactory", _strategyFactory);

        string memory root = vm.serializeString("_root", "deployment", deployment);
        root = vm.serializeString("_root", "factories", factories);

        vm.writeJson(root, _poolFactoryJsonPath);
    }

    function run() external {
        string memory poolFactoryJsonPath =
            vm.envOr("POOL_FACTORY_DEPLOYMENT_JSON", string("deployments/pool-factory-hoodi.json"));
        string memory mellowParamsJsonPath = vm.envString("MELLOW_POOL_PARAMS_JSON");
        require(bytes(mellowParamsJsonPath).length != 0, "MELLOW_POOL_PARAMS_JSON env var must be set and non-empty");
        require(
            vm.isFile(mellowParamsJsonPath),
            string(abi.encodePacked("MELLOW_POOL_PARAMS_JSON file does not exist at: ", mellowParamsJsonPath))
        );

        string memory json = vm.readFile(mellowParamsJsonPath);

        address vault = vm.parseJsonAddress(json, "$.mellow.vault");
        address syncDepositQueue = vm.parseJsonAddress(json, "$.mellow.syncDepositQueue");
        address asyncDepositQueue = vm.parseJsonAddress(json, "$.mellow.asyncDepositQueue");
        address asyncRedeemQueue = vm.parseJsonAddress(json, "$.mellow.asyncRedeemQueue");
        bool allowListEnabled = vm.parseJsonBool(json, "$.auxiliaryPoolConfig.allowListEnabled");

        vm.startBroadcast();
        address strategyFactory = address(
            new MellowStrategyFactory(vault, syncDepositQueue, asyncDepositQueue, asyncRedeemQueue, allowListEnabled)
        );
        vm.stopBroadcast();

        _writePoolFactoryArtifacts(strategyFactory, poolFactoryJsonPath);

        console.log("Deployed MellowStrategyFactory at", strategyFactory);
        console.log("Updated", poolFactoryJsonPath);
    }
}
