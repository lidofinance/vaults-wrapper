// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";
import {Factory} from "src/Factory.sol";
import {WrapperC} from "src/WrapperC.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IOssifiableProxy} from "src/interfaces/IOssifiableProxy.sol";

contract DeployWrapper is Script {
    struct WrapperParams {
        uint256 wrapperType; // 0:A, 1:B, 2:LOOP, 3:GGV
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        bool allowlistEnabled;
        uint256 reserveRatioGapBP; // B/C only
        uint256 loops; // LOOP only
        address teller; // GGV only
        address boringQueue; // GGV only
        uint256 value; // msg.value to send (CONNECT_DEPOSIT)
        address timelockExecutor; // per deployment
    }

    function _readFactoryAddress(string memory path) internal view returns (address factory) {
        string memory json = vm.readFile(path);
        // The deployment artifact should contain { deployment: { factory: "0x..." } }
        factory = vm.parseJsonAddress(json, "$.deployment.factory");
        require(factory != address(0), "factory not found");
    }

    function _readWrapperParams(string memory path) internal view returns (WrapperParams memory p) {
        string memory json = vm.readFile(path);
        p.wrapperType = vm.parseJsonUint(json, "$.wrapperType");
        p.nodeOperator = vm.parseJsonAddress(json, "$.nodeOperator");
        p.nodeOperatorManager = vm.parseJsonAddress(json, "$.nodeOperatorManager");
        p.nodeOperatorFeeBP = vm.parseJsonUint(json, "$.nodeOperatorFeeBP");
        p.confirmExpiry = vm.parseJsonUint(json, "$.confirmExpiry");
        p.maxFinalizationTime = vm.parseJsonUint(json, "$.maxFinalizationTime");
        p.minWithdrawalDelayTime = vm.parseJsonUint(json, "$.minWithdrawalDelayTime");
        p.allowlistEnabled = vm.parseJsonBool(json, "$.allowlistEnabled");
        // Parse only fields relevant to the wrapper type
        if (
            p.wrapperType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)
                || p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)
                || p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)
        ) {
            p.reserveRatioGapBP = vm.parseJsonUint(json, "$.reserveRatioGapBP");
        }
        if (p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            p.loops = vm.parseJsonUint(json, "$.loops");
        }
        if (p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            address ggvTeller = address(0);
            address ggvQueue = address(0);
            try vm.parseJsonAddress(json, "$.ggv.teller") returns (address t) {
                ggvTeller = t;
            } catch {}
            try vm.parseJsonAddress(json, "$.ggv.boringOnChainQueue") returns (address q) {
                ggvQueue = q;
            } catch {}
            require(ggvTeller != address(0), "ggv.teller must be set");
            require(ggvQueue != address(0), "ggv.boringOnChainQueue must be set");
            p.teller = ggvTeller;
            p.boringQueue = ggvQueue;
        }
        p.value = vm.parseJsonUint(json, "$.value");
        p.timelockExecutor = vm.parseJsonAddress(json, "$.timelock.executor");
    }

    function run() external {
        string memory factoryJsonPath = vm.envString("FACTORY_DEPLOYED_JSON");
        string memory paramsJsonPath = vm.envString("WRAPPER_PARAMS_JSON");
        string memory outputJsonPath = vm.envString("WRAPPER_DEPLOYED_JSON");

        require(bytes(factoryJsonPath).length != 0, "FACTORY_DEPLOYED_JSON env var must be set and non-empty");
        require(bytes(paramsJsonPath).length != 0, "WRAPPER_PARAMS_JSON env var must be set and non-empty");
        require(bytes(outputJsonPath).length != 0, "WRAPPER_DEPLOYED_JSON env var must be set and non-empty");

        if (!vm.isFile(factoryJsonPath)) {
            revert(string(abi.encodePacked("FACTORY_DEPLOYED_JSON file does not exist at: ", factoryJsonPath)));
        }
        if (!vm.isFile(paramsJsonPath)) {
            revert(string(abi.encodePacked("WRAPPER_PARAMS_JSON file does not exist at: ", paramsJsonPath)));
        }

        address factoryAddr = _readFactoryAddress(factoryJsonPath);
        WrapperParams memory p = _readWrapperParams(paramsJsonPath);

        // Check Lido total shares before broadcasting
        Factory factoryView = Factory(factoryAddr);
        address stethAddr = factoryView.STETH();
        uint256 totalShares = IStETH(stethAddr).getTotalShares();
        console2.log("Lido getTotalShares:", totalShares);
        require(totalShares > 100000, "Lido totalShares must be > 100000");

        // Optional: bump core VaultFactory nonce on local fork to avoid CREATE address collision when deploying Dashboard.
        // This is useful if, on your fork, the core VaultFactory’s “creation nonce” is not aligned with the real chain’s history.
        // This misalignment is common on forks: the RPC eth_getTransactionCount for contracts is often 0, and many fork providers don’t restore the contract-creation nonce correctly.
        // Enabled by setting BUMP_CORE_FACTORY_NONCE to a non-zero value in the environment.
        uint256 bumpFlag = vm.envOr("BUMP_CORE_FACTORY_NONCE", uint256(0));
        if (bumpFlag != 0) {
            address coreVaultFactory = address(factoryView.VAULT_FACTORY());
            uint64 nonce = vm.getNonce(coreVaultFactory);
            // Find the next pair of nonces where both predicted CREATE addresses are free of code
            for (uint64 i = 0; i < 64; i++) {
                address predictedFirst = vm.computeCreateAddress(coreVaultFactory, uint256(nonce));
                address predictedSecond = vm.computeCreateAddress(coreVaultFactory, uint256(nonce) + 1);
                if (predictedFirst.code.length == 0 && predictedSecond.code.length == 0) {
                    break;
                }
                nonce++;
            }
            // Apply the new nonce if it changed
            if (nonce != vm.getNonce(coreVaultFactory)) {
                vm.setNonce(coreVaultFactory, nonce);
                console2.log("Bumped core VaultFactory nonce to", uint256(nonce));
            }
        }

        vm.startBroadcast();
        Factory factory = Factory(factoryAddr);

        address vault;
        address dashboard;
        address payable wrapperProxy;
        address withdrawalQueueProxy;
        address wrapperImpl;
        address withdrawalQueueImpl;
        address strategy = address(0);

        if (p.wrapperType == uint256(Factory.WrapperType.NO_MINTING_NO_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithNoMintingNoStrategy{
                value: p.value
            }(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.maxFinalizationTime,
                p.minWithdrawalDelayTime,
                p.allowlistEnabled,
                p.timelockExecutor
            );
        } else if (p.wrapperType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithMintingNoStrategy{
                value: p.value
            }(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.maxFinalizationTime,
                p.minWithdrawalDelayTime,
                p.allowlistEnabled,
                p.reserveRatioGapBP,
                p.timelockExecutor
            );
        } else if (p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithLoopStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.maxFinalizationTime,
                p.minWithdrawalDelayTime,
                p.allowlistEnabled,
                p.reserveRatioGapBP,
                p.loops,
                p.timelockExecutor
            );
            strategy = address(WrapperC(wrapperProxy).STRATEGY());
        } else if (p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithGGVStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.maxFinalizationTime,
                p.minWithdrawalDelayTime,
                p.allowlistEnabled,
                p.reserveRatioGapBP,
                p.teller,
                p.boringQueue,
                p.timelockExecutor
            );
            strategy = address(WrapperC(wrapperProxy).STRATEGY());
        } else {
            revert("invalid wrapperType");
        }

        vm.stopBroadcast();

        // Read implementation addresses from proxies (OssifiableProxy exposes proxy__getImplementation())
        wrapperImpl = IOssifiableProxy(wrapperProxy).proxy__getImplementation();
        withdrawalQueueImpl = IOssifiableProxy(address(withdrawalQueueProxy)).proxy__getImplementation();

        // Read admin (timelock) from proxy
        address timelockAdmin = IOssifiableProxy(wrapperProxy).proxy__getAdmin();

        // write artifact
        string memory out = vm.serializeAddress("wrapper", "factory", factoryAddr);
        out = vm.serializeAddress("wrapper", "vault", vault);
        out = vm.serializeAddress("wrapper", "dashboard", dashboard);
        out = vm.serializeAddress("wrapper", "wrapperProxy", wrapperProxy);
        out = vm.serializeAddress("wrapper", "wrapperImpl", wrapperImpl);
        out = vm.serializeAddress("wrapper", "withdrawalQueue", withdrawalQueueProxy);
        out = vm.serializeAddress("wrapper", "withdrawalQueueImpl", withdrawalQueueImpl);
        out = vm.serializeUint("wrapper", "wrapperType", p.wrapperType);
        out = vm.serializeAddress("wrapper", "strategy", strategy);
        out = vm.serializeAddress("wrapper", "timelock", timelockAdmin);

        // ------------------------------------------------------------------------------------
        // Compute and save ABI-encoded constructor args for contract verification
        // ------------------------------------------------------------------------------------
        // Proxy constructor args: (address implementation, address admin, bytes data)
        bytes memory wrapperProxyCtorArgs = abi.encode(factoryView.DUMMY_IMPLEMENTATION(), factoryAddr, bytes(""));
        out = vm.serializeBytes("wrapper", "wrapperProxyCtorArgs", wrapperProxyCtorArgs);

        // WithdrawalQueue proxy constructor args: (impl, admin, abi.encodeCall(WithdrawalQueue.initialize, (...)))
        bytes memory wqInitData = abi.encodeCall(WithdrawalQueue.initialize, (p.nodeOperator, p.nodeOperator));
        bytes memory withdrawalQueueProxyCtorArgs = abi.encode(withdrawalQueueImpl, factoryAddr, wqInitData);
        out = vm.serializeBytes("wrapper", "withdrawalQueueProxyCtorArgs", withdrawalQueueProxyCtorArgs);

        // Wrapper implementation constructor args depend on wrapper type
        bytes memory wrapperImplCtorArgs;
        if (p.wrapperType == uint256(Factory.WrapperType.NO_MINTING_NO_STRATEGY)) {
            wrapperImplCtorArgs = abi.encode(dashboard, p.allowlistEnabled, withdrawalQueueProxy);
        } else if (p.wrapperType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)) {
            wrapperImplCtorArgs =
                abi.encode(dashboard, stethAddr, p.allowlistEnabled, p.reserveRatioGapBP, withdrawalQueueProxy);
        } else if (p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            wrapperImplCtorArgs = abi.encode(
                dashboard,
                stethAddr,
                p.allowlistEnabled,
                strategy, // loop strategy addr
                p.reserveRatioGapBP,
                withdrawalQueueProxy
            );
        } else if (p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            wrapperImplCtorArgs = abi.encode(
                dashboard,
                stethAddr,
                p.allowlistEnabled,
                strategy, // ggv strategy addr
                p.reserveRatioGapBP,
                withdrawalQueueProxy
            );
        }
        out = vm.serializeBytes("wrapper", "wrapperImplCtorArgs", wrapperImplCtorArgs);

        // WithdrawalQueue implementation constructor args: (wrapper, lazyOracle, maxFinalizationTime, minWithdrawalDelayTime)
        bytes memory withdrawalQueueImplCtorArgs =
            abi.encode(wrapperProxy, factoryView.LAZY_ORACLE(), p.maxFinalizationTime, p.minWithdrawalDelayTime);
        out = vm.serializeBytes("wrapper", "withdrawalQueueImplCtorArgs", withdrawalQueueImplCtorArgs);

        // Strategy constructor args (if any)
        if (strategy != address(0)) {
            address wstethAddr = factoryView.WSTETH();
            // Try reading STRATEGY_PROXY_IMPL via a staticcall to avoid importing the type
            address strategyProxyImpl = address(0);
            (bool okSpi, bytes memory retSpi) = strategy.staticcall(abi.encodeWithSignature("STRATEGY_PROXY_IMPL()"));
            if (okSpi && retSpi.length >= 32) {
                strategyProxyImpl = abi.decode(retSpi, (address));
            }
            bytes memory strategyCtorArgs =
                abi.encode(strategyProxyImpl, wrapperProxy, stethAddr, wstethAddr, p.teller, p.boringQueue);
            out = vm.serializeBytes("wrapper", "strategyCtorArgs", strategyCtorArgs);
        }
        vm.writeJson(out, outputJsonPath);

        console2.log("Wrapper deployed: vault", vault);
        console2.log("Wrapper proxy:", wrapperProxy);
        console2.log("WithdrawalQueue:", withdrawalQueueProxy);
        if (strategy != address(0)) console2.log("Strategy:", strategy);
        console2.log("Output written to", outputJsonPath);
    }
}
