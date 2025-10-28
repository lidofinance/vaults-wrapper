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
        // OPTIONAL: FACTORY_DEPLOYED_JSON
        // REQUIRED: FACTORY_PARAMS_JSON (path to config with timelock params)
        string memory locatorAddressStr = vm.envString("CORE_LOCATOR_ADDRESS");
        string memory outputJsonPath = vm.envOr(
            "FACTORY_DEPLOYED_JSON", string(string.concat("deployments/pool-", vm.toString(block.chainid), ".json"))
        );
        string memory paramsJsonPath = vm.envString("FACTORY_PARAMS_JSON");
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        ILidoLocator locator = ILidoLocator(locatorAddress);
        address vaultFactory = locator.vaultFactory();
        address steth = address(locator.lido());
        address wsteth = address(locator.wstETH());
        address lazyOracle = locator.lazyOracle();
        Factory.TimelockConfig memory tcfg = _readTimelockFromJson(paramsJsonPath);

        vm.startBroadcast();

        // Deploy implementation factories and proxy stub
        StvPoolFactory poolFac = new StvPoolFactory();
        StvStETHPoolFactory stethPoolFac = new StvStETHPoolFactory();
        StvStrategyPoolFactory strategyPoolFac = new StvStrategyPoolFactory();
        WithdrawalQueueFactory wqf = new WithdrawalQueueFactory();
        DistributorFactory df = new DistributorFactory();
        LoopStrategyFactory lsf = new LoopStrategyFactory();
        GGVStrategyFactory ggvf = new GGVStrategyFactory();
        DummyImplementation dummy = new DummyImplementation();
        TimelockFactory tlf = new TimelockFactory();

        // Build Factory configuration struct
        Factory.WrapperConfig memory cfg = Factory.WrapperConfig({
            vaultFactory: vaultFactory,
            steth: steth,
            wsteth: wsteth,
            lazyOracle: lazyOracle,
            stvPoolFactory: address(poolFac),
            stvStETHPoolFactory: address(stethPoolFac),
            stvStrategyPoolFactory: address(strategyPoolFac),
            withdrawalQueueFactory: address(wqf),
            distributorFactory: address(df),
            loopStrategyFactory: address(lsf),
            ggvStrategyFactory: address(ggvf),
            dummyImplementation: address(dummy),
            timelockFactory: address(tlf)
        });

        Factory factory = new Factory(cfg, tcfg);

        vm.stopBroadcast();

        // Serialize artifact with deployed addresses
        string memory root = "";
        root = vm.serializeAddress("core", "locator", locatorAddress);
        root = vm.serializeAddress("core", "vaultFactory", vaultFactory);
        root = vm.serializeAddress("core", "steth", steth);
        root = vm.serializeAddress("core", "wsteth", wsteth);
        root = vm.serializeAddress("core", "lazyOracle", lazyOracle);

        string memory facs = "";
        facs = vm.serializeAddress("factories", "stvPoolFactory", address(poolFac));
        facs = vm.serializeAddress("factories", "stvStETHPoolFactory", address(stethPoolFac));
        facs = vm.serializeAddress("factories", "stvStrategyPoolFactory", address(strategyPoolFac));
        facs = vm.serializeAddress("factories", "withdrawalQueueFactory", address(wqf));
        facs = vm.serializeAddress("factories", "loopStrategyFactory", address(lsf));
        facs = vm.serializeAddress("factories", "ggvStrategyFactory", address(ggvf));
        facs = vm.serializeAddress("factories", "timelockFactory", address(tlf));

        string memory meta = "";
        meta = vm.serializeString("meta", "chainId", vm.toString(block.chainid));

        string memory out = "";
        out = vm.serializeAddress("deployment", "factory", address(factory));
        out = vm.serializeAddress("deployment", "dummyImplementation", address(dummy));
        out = vm.serializeString("deployment", "network", vm.toString(block.chainid));

        // Compose final JSON
        string memory json = vm.serializeString("_root", "meta", meta);
        json = vm.serializeString("_root", "core", root);
        json = vm.serializeString("_root", "factories", facs);
        json = vm.serializeString("_root", "deployment", out);

        vm.writeJson(json, outputJsonPath);

        console2.log("Deployed Factory at", address(factory));
        console2.log("Output written to", outputJsonPath);
    }

    // Optional overload to allow passing a pre-built WrapperConfig and skipping internal factory deploys
    function run(string memory locatorAddressStr, Factory.WrapperConfig memory cfg) external {
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        ILidoLocator locator = ILidoLocator(locatorAddress);
        require(locator.vaultFactory() == cfg.vaultFactory, "vaultFactory mismatch");
        require(address(locator.lido()) == cfg.steth, "stETH mismatch");

        vm.startBroadcast();
        Factory factory = new Factory(cfg, Factory.TimelockConfig({
            minDelaySeconds: 0
        }));
        vm.stopBroadcast();

        string memory outputJsonPath =
            string(string.concat("deployments/pool-", vm.toString(block.chainid), ".json"));
        string memory out = vm.serializeAddress("deployment", "factory", address(factory));
        vm.writeJson(out, outputJsonPath);
    }

    // Overload with explicit timelock configuration
    function run(string memory locatorAddressStr, Factory.WrapperConfig memory cfg, Factory.TimelockConfig memory tcfg)
        external
    {
        address locatorAddress = vm.parseAddress(locatorAddressStr);
        ILidoLocator locator = ILidoLocator(locatorAddress);
        require(locator.vaultFactory() == cfg.vaultFactory, "vaultFactory mismatch");
        require(address(locator.lido()) == cfg.steth, "stETH mismatch");

        vm.startBroadcast();
        Factory factory = new Factory(cfg, tcfg);
        vm.stopBroadcast();

        string memory outputJsonPath =
            string(string.concat("deployments/pool-", vm.toString(block.chainid), ".json"));
        string memory out = vm.serializeAddress("deployment", "factory", address(factory));
        vm.writeJson(out, outputJsonPath);
    }
}
