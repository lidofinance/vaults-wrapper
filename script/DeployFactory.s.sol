// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";

import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";

import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";

contract DeployFactory is Script {
    // function _readCore(address locatorAddress) internal view returns (CoreRefs memory c) {
    //     ILidoLocator locator = ILidoLocator(locatorAddress);
    //     c.vaultFactory = locator.vaultFactory();
    //     c.steth = address(locator.lido());
    //     c.wsteth = address(locator.wstETH());
    //     c.lazyOracle = locator.lazyOracle();
    // }

    function _deployImplFactories() internal returns (Factory.SubFactories memory f) {
        f.stvPoolFactory = address(new StvPoolFactory());
        f.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        f.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        f.distributorFactory = address(new DistributorFactory());
        f.loopStrategyFactory = address(new LoopStrategyFactory());
        f.ggvStrategyFactory = address(new GGVStrategyFactory());
        f.timelockFactory = address(new TimelockFactory());
    }

    function _writeArtifacts(Factory.SubFactories memory subFactories, address factoryAddr, string memory outputJsonPath) internal {
        string memory factoriesSection = "";
        factoriesSection = vm.serializeAddress("factories", "stvPoolFactory", subFactories.stvPoolFactory);
        factoriesSection = vm.serializeAddress("factories", "stvStETHPoolFactory", subFactories.stvStETHPoolFactory);
        factoriesSection = vm.serializeAddress("factories", "withdrawalQueueFactory", subFactories.withdrawalQueueFactory);
        factoriesSection = vm.serializeAddress("factories", "loopStrategyFactory", subFactories.loopStrategyFactory);
        factoriesSection = vm.serializeAddress("factories", "ggvStrategyFactory", subFactories.ggvStrategyFactory);
        factoriesSection = vm.serializeAddress("factories", "timelockFactory", subFactories.timelockFactory);

        string memory out = "";
        out = vm.serializeAddress("deployment", "factory", factoryAddr);
        out = vm.serializeString("deployment", "network", vm.toString(block.chainid));

        string memory json = vm.serializeString("_root", "factories", factoriesSection);
        json = vm.serializeString("_root", "deployment", out);

        vm.writeJson(json, outputJsonPath);
        vm.writeJson(json, "deployments/pool-factory-latest.json");
    }

    function _readTimelockFromJson(string memory paramsPath)
        internal
        view
        returns (Factory.TimelockConfig memory timelockConfig)
    {
        require(vm.isFile(paramsPath), string(abi.encodePacked("FACTORY_PARAMS_JSON file does not exist at: ", paramsPath)));
        string memory json = vm.readFile(paramsPath);

        timelockConfig.minDelaySeconds = vm.parseJsonUint(json, "$.timelock.minDelaySeconds");
    }

    function _readStrategyParamsFromJson(string memory paramsPath)
        internal
        view
        returns (Factory.StrategyParameters memory strategyParams)
    {
        require(vm.isFile(paramsPath), string(abi.encodePacked("FACTORY_PARAMS_JSON file does not exist at: ", paramsPath)));
        string memory json = vm.readFile(paramsPath);

        try vm.parseJsonAddress(json, "$.strategies.ggv.teller") returns (address teller) {
            strategyParams.ggvTeller = teller;
        } catch {}

        try vm.parseJsonAddress(json, "$.strategies.ggv.boringOnChainQueue") returns (address queue) {
            strategyParams.ggvBoringOnChainQueue = queue;
        } catch {}
    }

    function run() external {
        // Expect environment variables for non-interactive deploys
        // REQUIRED: CORE_LOCATOR_ADDRESS (address of Lido Locator proxy)
        // REQUIRED: FACTORY_PARAMS_JSON (path to config with timelock params)
        string memory locatorAddressStr = vm.envString("CORE_LOCATOR_ADDRESS");
        string memory outputJsonPath = string(
            abi.encodePacked(
                "deployments/pool-factory-",
                vm.toString(block.chainid),
                "-",
                vm.toString(block.timestamp),
                ".json"
            )
        );
        string memory paramsJsonPath = vm.envString("FACTORY_PARAMS_JSON");
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        Factory.TimelockConfig memory timelockConfig = _readTimelockFromJson(paramsJsonPath);
        Factory.StrategyParameters memory strategyParams = _readStrategyParamsFromJson(paramsJsonPath);

        vm.startBroadcast();

        // Deploy implementation factories and proxy stub
        Factory.SubFactories memory subFactories = _deployImplFactories();

        Factory factory = new Factory(locatorAddress, subFactories, timelockConfig, strategyParams);

        vm.stopBroadcast();

        // Write artifacts
        _writeArtifacts(subFactories, address(factory), outputJsonPath);

        console2.log("Deployed Factory at", address(factory));
        console2.log("Output written to", outputJsonPath);
        console2.log("Also updated", "deployments/pool-factory-latest.json");
    }

    // // Optional overload to allow passing a pre-built PoolConfig and skipping internal factory deploys
    // function run(string memory locatorAddressStr, Factory.SubFactories memory subFactories, Factory.TimelockConfig memory timelockConfig) external {
    //     address locatorAddress = vm.parseAddress(locatorAddressStr);

    //     vm.startBroadcast();
    //     Factory factory = new Factory(locatorAddress, subFactories, timelockConfig);
    //     vm.stopBroadcast();

    //     string memory outputJsonPath = string(
    //         abi.encodePacked(
    //             "deployments/pool-factory-",
    //             vm.toString(block.chainid),
    //             "-",
    //             vm.toString(block.timestamp),
    //             ".json"
    //         )
    //     );
    //     string memory out = vm.serializeAddress("deployment", "factory", address(factory));
    //     vm.writeJson(out, outputJsonPath);
    //     vm.writeJson(out, "deployments/pool-factory-latest.json");
    // }

    // // Overload with explicit timelock configuration
    // function run(string memory locatorAddressStr, Factory.PoolConfig memory cfg, Factory.TimelockConfig memory tcfg)
    //     external
    // {
    //     address locatorAddress = vm.parseAddress(locatorAddressStr);
    //     ILidoLocator locator = ILidoLocator(locatorAddress);
    //     require(locator.vaultFactory() == cfg.vaultFactory, "vaultFactory mismatch");
    //     require(address(locator.lido()) == cfg.steth, "stETH mismatch");

    //     vm.startBroadcast();
    //     Factory factory = new Factory(cfg, tcfg);
    //     vm.stopBroadcast();

    //     string memory outputJsonPath = string(
    //         abi.encodePacked(
    //             "deployments/pool-factory-",
    //             vm.toString(block.chainid),
    //             "-",
    //             vm.toString(block.timestamp),
    //             ".json"
    //         )
    //     );
    //     string memory out = vm.serializeAddress("deployment", "factory", address(factory));
    //     vm.writeJson(out, outputJsonPath);
    // }
}
