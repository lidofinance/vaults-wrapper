// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";

import {Factory} from "src/Factory.sol";
import {StvPoolFactory} from "src/factories/StvPoolFactory.sol";
import {StvStETHPoolFactory} from "src/factories/StvStETHPoolFactory.sol";
import {StvStrategyPoolFactory} from "src/factories/StvStrategyPoolFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {DistributorFactory} from "src/factories/DistributorFactory.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";
import {TimelockFactory} from "src/factories/TimelockFactory.sol";

import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";

contract DeployWrapperFactory is Script {
    struct CoreRefs {
        address vaultFactory;
        address steth;
        address wsteth;
        address lazyOracle;
    }

    struct LocalFactories {
        address stvPoolFactory;
        address stvStETHPoolFactory;
        address stvStrategyPoolFactory;
        address withdrawalQueueFactory;
        address distributorFactory;
        address loopStrategyFactory;
        address ggvStrategyFactory;
        address dummyImplementation;
        address timelockFactory;
    }

    function _readCore(address locatorAddress) internal view returns (CoreRefs memory c) {
        ILidoLocator locator = ILidoLocator(locatorAddress);
        c.vaultFactory = locator.vaultFactory();
        c.steth = address(locator.lido());
        c.wsteth = address(locator.wstETH());
        c.lazyOracle = locator.lazyOracle();
    }

    function _deployImplFactories() internal returns (LocalFactories memory f) {
        f.stvPoolFactory = address(new StvPoolFactory());
        f.stvStETHPoolFactory = address(new StvStETHPoolFactory());
        f.stvStrategyPoolFactory = address(new StvStrategyPoolFactory());
        f.withdrawalQueueFactory = address(new WithdrawalQueueFactory());
        f.distributorFactory = address(new DistributorFactory());
        f.loopStrategyFactory = address(new LoopStrategyFactory());
        f.ggvStrategyFactory = address(new GGVStrategyFactory());
        f.dummyImplementation = address(new DummyImplementation());
        f.timelockFactory = address(new TimelockFactory());
    }

    function _writeArtifacts(LocalFactories memory f, address factoryAddr, string memory outputJsonPath) internal {
        string memory facs = "";
        facs = vm.serializeAddress("factories", "stvPoolFactory", f.stvPoolFactory);
        facs = vm.serializeAddress("factories", "stvStETHPoolFactory", f.stvStETHPoolFactory);
        facs = vm.serializeAddress("factories", "stvStrategyPoolFactory", f.stvStrategyPoolFactory);
        facs = vm.serializeAddress("factories", "withdrawalQueueFactory", f.withdrawalQueueFactory);
        facs = vm.serializeAddress("factories", "loopStrategyFactory", f.loopStrategyFactory);
        facs = vm.serializeAddress("factories", "ggvStrategyFactory", f.ggvStrategyFactory);
        facs = vm.serializeAddress("factories", "timelockFactory", f.timelockFactory);

        string memory out = "";
        out = vm.serializeAddress("deployment", "factory", factoryAddr);
        out = vm.serializeString("deployment", "network", vm.toString(block.chainid));

        string memory json = vm.serializeString("_root", "factories", facs);
        json = vm.serializeString("_root", "deployment", out);

        vm.writeJson(json, outputJsonPath);
        vm.writeJson(json, "deployments/pool-factory-latest.json");
    }

    function _readTimelockFromJson(string memory paramsPath)
        internal
        view
        returns (Factory.TimelockConfig memory tcfg)
    {
        require(vm.isFile(paramsPath), string(abi.encodePacked("FACTORY_PARAMS_JSON file does not exist at: ", paramsPath)));
        string memory json = vm.readFile(paramsPath);

        tcfg.minDelaySeconds = vm.parseJsonUint(json, "$.timelock.minDelaySeconds");
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
        CoreRefs memory core = _readCore(locatorAddress);
        Factory.TimelockConfig memory tcfg = _readTimelockFromJson(paramsJsonPath);

        vm.startBroadcast();

        // Deploy implementation factories and proxy stub
        LocalFactories memory f = _deployImplFactories();

        // Build Factory configuration struct
        Factory.PoolConfig memory cfg = Factory.PoolConfig({
            vaultFactory: core.vaultFactory,
            steth: core.steth,
            wsteth: core.wsteth,
            lazyOracle: core.lazyOracle,
            stvPoolFactory: f.stvPoolFactory,
            stvStETHPoolFactory: f.stvStETHPoolFactory,
            stvStrategyPoolFactory: f.stvStrategyPoolFactory,
            withdrawalQueueFactory: f.withdrawalQueueFactory,
            distributorFactory: f.distributorFactory,
            loopStrategyFactory: f.loopStrategyFactory,
            ggvStrategyFactory: f.ggvStrategyFactory,
            dummyImplementation: f.dummyImplementation,
            timelockFactory: f.timelockFactory
        });

        Factory factory = new Factory(cfg, tcfg);

        vm.stopBroadcast();

        // Write artifacts
        _writeArtifacts(f, address(factory), outputJsonPath);

        console2.log("Deployed Factory at", address(factory));
        console2.log("Output written to", outputJsonPath);
        console2.log("Also updated", "deployments/pool-factory-latest.json");
    }

    // Optional overload to allow passing a pre-built PoolConfig and skipping internal factory deploys
    function run(string memory locatorAddressStr, Factory.PoolConfig memory cfg) external {
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        ILidoLocator locator = ILidoLocator(locatorAddress);
        require(locator.vaultFactory() == cfg.vaultFactory, "vaultFactory mismatch");
        require(address(locator.lido()) == cfg.steth, "stETH mismatch");

        vm.startBroadcast();
        Factory factory = new Factory(cfg, Factory.TimelockConfig({
            minDelaySeconds: 0
        }));
        vm.stopBroadcast();

        string memory outputJsonPath = string(
            abi.encodePacked(
                "deployments/pool-factory-",
                vm.toString(block.chainid),
                "-",
                vm.toString(block.timestamp),
                ".json"
            )
        );
        string memory out = vm.serializeAddress("deployment", "factory", address(factory));
        vm.writeJson(out, outputJsonPath);
        vm.writeJson(out, "deployments/pool-factory-latest.json");
    }

    // Overload with explicit timelock configuration
    function run(string memory locatorAddressStr, Factory.PoolConfig memory cfg, Factory.TimelockConfig memory tcfg)
        external
    {
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        ILidoLocator locator = ILidoLocator(locatorAddress);
        require(locator.vaultFactory() == cfg.vaultFactory, "vaultFactory mismatch");
        require(address(locator.lido()) == cfg.steth, "stETH mismatch");

        vm.startBroadcast();
        Factory factory = new Factory(cfg, tcfg);
        vm.stopBroadcast();

        string memory outputJsonPath = string(
            abi.encodePacked(
                "deployments/pool-factory-",
                vm.toString(block.chainid),
                "-",
                vm.toString(block.timestamp),
                ".json"
            )
        );
        string memory out = vm.serializeAddress("deployment", "factory", address(factory));
        vm.writeJson(out, outputJsonPath);
    }
}
