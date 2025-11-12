// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Script.sol";

import {Factory} from "src/Factory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {ILidoLocator} from "src/interfaces/core/ILidoLocator.sol";

contract DeployFactory is Script {
    function _deployImplFactories(address _ggvTeller, address _ggvBoringQueue, address _steth, address _wsteth)
        internal
        returns (Factory.SubFactories memory f)
    {
        f.stvPoolFactory = address(new StvPoolFactory());
        f.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        f.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        f.distributorFactory = address(new DistributorFactory());
        f.ggvStrategyFactory = address(new GGVStrategyFactory(_ggvTeller, _ggvBoringQueue));
        f.timelockFactory = address(new TimelockFactory());
    }

    function _writeArtifacts(
        Factory.SubFactories memory _subFactories,
        address _factoryAddr,
        string memory _outputJsonPath
    ) internal {
        string memory factoriesSection = "";
        factoriesSection = vm.serializeAddress("factories", "stvPoolFactory", _subFactories.stvPoolFactory);
        factoriesSection = vm.serializeAddress("factories", "stvStETHPoolFactory", _subFactories.stvStETHPoolFactory);
        factoriesSection =
            vm.serializeAddress("factories", "withdrawalQueueFactory", _subFactories.withdrawalQueueFactory);
        factoriesSection = vm.serializeAddress("factories", "ggvStrategyFactory", _subFactories.ggvStrategyFactory);
        factoriesSection = vm.serializeAddress("factories", "timelockFactory", _subFactories.timelockFactory);

        string memory out = "";
        out = vm.serializeAddress("deployment", "factory", _factoryAddr);
        out = vm.serializeString("deployment", "network", vm.toString(block.chainid));

        string memory json = vm.serializeString("_root", "factories", factoriesSection);
        json = vm.serializeString("_root", "deployment", out);

        vm.writeJson(json, _outputJsonPath);
        vm.writeJson(json, "deployments/pool-factory-latest.json");
    }

    function _readGGVStrategyAddresses(string memory _paramsPath)
        internal
        view
        returns (address teller, address boringQueue)
    {
        require(
            vm.isFile(_paramsPath),
            string(abi.encodePacked("FACTORY_PARAMS_JSON file does not exist at: ", _paramsPath))
        );
        string memory json = vm.readFile(_paramsPath);

        teller = vm.parseJsonAddress(json, "$.strategies.ggv.teller");
        boringQueue = vm.parseJsonAddress(json, "$.strategies.ggv.boringOnChainQueue");

        require(teller != address(0), "strategies.ggv.teller missing");
        require(boringQueue != address(0), "strategies.ggv.boringOnChainQueue missing");
    }

    function run() external {
        // Expect environment variables for non-interactive deploys
        // REQUIRED: CORE_LOCATOR_ADDRESS (address of Lido Locator proxy)
        // REQUIRED: FACTORY_PARAMS_JSON (path to config with timelock params)
        string memory locatorAddressStr = vm.envString("CORE_LOCATOR_ADDRESS");
        string memory paramsJsonPath = vm.envString("FACTORY_PARAMS_JSON");
        require(bytes(locatorAddressStr).length != 0, "CORE_LOCATOR_ADDRESS env var must be set and non-empty");
        require(bytes(paramsJsonPath).length != 0, "FACTORY_PARAMS_JSON env var must be set and non-empty");

        string memory outputJsonPath = string(
            abi.encodePacked(
                "deployments/pool-factory-", vm.toString(block.chainid), "-", vm.toString(block.timestamp), ".json"
            )
        );

        address locatorAddress = vm.parseAddress(locatorAddressStr);

        (address ggvTeller, address ggvBoringQueue) = _readGGVStrategyAddresses(paramsJsonPath);

        ILidoLocator locator = ILidoLocator(locatorAddress);
        address steth = address(locator.lido());
        address wsteth = address(locator.wstETH());

        vm.startBroadcast();

        // Deploy implementation factories and proxy stub
        Factory.SubFactories memory subFactories = _deployImplFactories(ggvTeller, ggvBoringQueue, steth, wsteth);

        Factory factory = new Factory(locatorAddress, subFactories);

        vm.stopBroadcast();

        // Write artifacts
        _writeArtifacts(subFactories, address(factory), outputJsonPath);

        console2.log("Deployed Factory at", address(factory));
        console2.log("Output written to", outputJsonPath);
        console2.log("Also updated", "deployments/pool-factory-latest.json");
    }
}
