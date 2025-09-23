// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";

import {Factory} from "src/Factory.sol";
import {WrapperAFactory} from "src/factories/WrapperAFactory.sol";
import {WrapperBFactory} from "src/factories/WrapperBFactory.sol";
import {WrapperCFactory} from "src/factories/WrapperCFactory.sol";
import {WithdrawalQueueFactory} from "src/factories/WithdrawalQueueFactory.sol";
import {LoopStrategyFactory} from "src/factories/LoopStrategyFactory.sol";
import {GGVStrategyFactory} from "src/factories/GGVStrategyFactory.sol";
import {DummyImplementation} from "src/proxy/DummyImplementation.sol";

import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {ILido} from "src/interfaces/ILido.sol";

contract DeployWrapperFactory is Script {
    struct CoreAddresses {
        address locator;
        address vaultFactory;
        address steth;
        address wsteth;
        address lazyOracle;
    }

    function _readCoreFromJson(string memory deployedJsonPath) internal view returns (CoreAddresses memory core) {
        string memory deployedJson = vm.readFile(deployedJsonPath);
        core.locator = vm.parseJsonAddress(deployedJson, "$.lidoLocator.proxy.address");

        ILidoLocator locator = ILidoLocator(core.locator);
        core.vaultFactory = locator.vaultFactory();
        core.steth = address(locator.lido());
        core.wsteth = locator.wstETH();
        core.lazyOracle = locator.lazyOracle();
    }

    function run() external {
        // Expect environment variables for non-interactive deploys
        // REQUIRED: CORE_DEPLOYED_JSON (path to Lido core deployed json, like CoreHarness)
        // OPTIONAL: OUTPUT_JSON
        string memory deployedJsonPath = vm.envString("CORE_DEPLOYED_JSON");
        string memory outputJsonPath = vm.envOr("OUTPUT_JSON", string(string.concat("deployments/wrapper-", vm.toString(block.chainid), ".json")));

        require(vm.isFile(deployedJsonPath), "CORE_DEPLOYED_JSON file does not exist");


        CoreAddresses memory core = _readCoreFromJson(deployedJsonPath);

        vm.startBroadcast();

        // Deploy implementation factories and proxy stub
        WrapperAFactory waf = new WrapperAFactory();
        WrapperBFactory wbf = new WrapperBFactory();
        WrapperCFactory wcf = new WrapperCFactory();
        WithdrawalQueueFactory wqf = new WithdrawalQueueFactory();
        LoopStrategyFactory lsf = new LoopStrategyFactory();
        GGVStrategyFactory ggvf = new GGVStrategyFactory();
        DummyImplementation dummy = new DummyImplementation();

        // Build Factory configuration struct
        Factory.WrapperConfig memory cfg = Factory.WrapperConfig({
            vaultFactory: core.vaultFactory,
            steth: core.steth,
            wsteth: core.wsteth,
            lazyOracle: core.lazyOracle,
            wrapperAFactory: address(waf),
            wrapperBFactory: address(wbf),
            wrapperCFactory: address(wcf),
            withdrawalQueueFactory: address(wqf),
            loopStrategyFactory: address(lsf),
            ggvStrategyFactory: address(ggvf),
            dummyImplementation: address(dummy)
        });

        Factory factory = new Factory(cfg);

        vm.stopBroadcast();

        // Serialize artifact with deployed addresses
        string memory root = "";
        root = vm.serializeAddress("core", "locator", core.locator);
        root = vm.serializeAddress("core", "vaultFactory", core.vaultFactory);
        root = vm.serializeAddress("core", "steth", core.steth);
        root = vm.serializeAddress("core", "wsteth", core.wsteth);
        root = vm.serializeAddress("core", "lazyOracle", core.lazyOracle);

        string memory facs = "";
        facs = vm.serializeAddress("factories", "wrapperAFactory", address(waf));
        facs = vm.serializeAddress("factories", "wrapperBFactory", address(wbf));
        facs = vm.serializeAddress("factories", "wrapperCFactory", address(wcf));
        facs = vm.serializeAddress("factories", "withdrawalQueueFactory", address(wqf));
        facs = vm.serializeAddress("factories", "loopStrategyFactory", address(lsf));
        facs = vm.serializeAddress("factories", "ggvStrategyFactory", address(ggvf));

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
    function run(string memory deployedJsonPath, Factory.WrapperConfig memory cfg) external {
        CoreAddresses memory core = _readCoreFromJson(deployedJsonPath);
        require(core.vaultFactory == cfg.vaultFactory, "vaultFactory mismatch");
        require(core.steth == cfg.steth, "stETH mismatch");

        vm.startBroadcast();
        Factory factory = new Factory(cfg);
        vm.stopBroadcast();

        string memory outputJsonPath = string(string.concat("deployments/wrapper-", vm.toString(block.chainid), ".json"));
        string memory out = vm.serializeAddress("deployment", "factory", address(factory));
        vm.writeJson(out, outputJsonPath);
    }
}


