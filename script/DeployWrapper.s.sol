// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";
import {Factory} from "src/Factory.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IOssifiableProxy} from "src/interfaces/IOssifiableProxy.sol";

contract DeployWrapper is Script {
    struct WrapperParams {
        uint256 poolType; // 0:A, 1:B, 2:LOOP, 3:GGV
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

    struct DeploymentResult {
        address vault;
        address dashboard;
        address payable poolProxy;
        address withdrawalQueueProxy;
        address poolImpl;
        address withdrawalQueueImpl;
        address strategy;
        address timelockAdmin;
        address stethAddr;
        address wstethAddr;
    }

    function _deployWrapper(Factory factory, WrapperParams memory p)
        internal
        returns (DeploymentResult memory r)
    {
        address distributor;
        if (p.poolType == uint256(Factory.WrapperType.NO_MINTING_NO_STRATEGY)) {
            (r.vault, r.dashboard, r.poolProxy, r.withdrawalQueueProxy, distributor) = factory
                .createVaultWithNoMintingNoStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.maxFinalizationTime,
                p.minWithdrawalDelayTime,
                p.allowlistEnabled,
                p.timelockExecutor
            );
        } else if (p.poolType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)) {
            (r.vault, r.dashboard, r.poolProxy, r.withdrawalQueueProxy, distributor) = factory
                .createVaultWithMintingNoStrategy{value: p.value}(
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
        } else if (p.poolType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            (r.vault, r.dashboard, r.poolProxy, r.withdrawalQueueProxy, r.strategy, distributor) = factory
                .createVaultWithLoopStrategy{value: p.value}(
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
        } else if (p.poolType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            (r.vault, r.dashboard, r.poolProxy, r.withdrawalQueueProxy, r.strategy, distributor) = factory
                .createVaultWithGGVStrategy{value: p.value}(
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
        } else {
            revert("invalid poolType");
        }

        // Implementations and admin
        r.poolImpl = IOssifiableProxy(r.poolProxy).proxy__getImplementation();
        r.withdrawalQueueImpl = IOssifiableProxy(address(r.withdrawalQueueProxy)).proxy__getImplementation();
        r.timelockAdmin = IOssifiableProxy(r.poolProxy).proxy__getAdmin();

        // Common addresses
        r.stethAddr = factory.STETH();
        r.wstethAddr = factory.WSTETH();
    }

    function _writeWrapperArtifact(
        Factory factoryView,
        WrapperParams memory p,
        DeploymentResult memory r,
        string memory outputJsonPath
    ) internal {
        string memory out = vm.serializeAddress("pool", "factory", address(factoryView));
        out = vm.serializeAddress("pool", "vault", r.vault);
        out = vm.serializeAddress("pool", "dashboard", r.dashboard);
        out = vm.serializeAddress("pool", "poolProxy", r.poolProxy);
        out = vm.serializeAddress("pool", "poolImpl", r.poolImpl);
        out = vm.serializeAddress("pool", "withdrawalQueue", r.withdrawalQueueProxy);
        out = vm.serializeAddress("pool", "withdrawalQueueImpl", r.withdrawalQueueImpl);
        out = vm.serializeUint("pool", "poolType", p.poolType);
        out = vm.serializeAddress("pool", "strategy", r.strategy);
        out = vm.serializeAddress("pool", "timelock", r.timelockAdmin);

        // Proxy constructor args
        bytes memory poolProxyCtorArgs = abi.encode(factoryView.DUMMY_IMPLEMENTATION(), address(factoryView), bytes(""));
        out = vm.serializeBytes("pool", "poolProxyCtorArgs", poolProxyCtorArgs);

        // WQ proxy constructor args
        bytes memory wqInitData = abi.encodeCall(WithdrawalQueue.initialize, (p.nodeOperator, p.nodeOperator));
        bytes memory withdrawalQueueProxyCtorArgs = abi.encode(r.withdrawalQueueImpl, address(factoryView), wqInitData);
        out = vm.serializeBytes("pool", "withdrawalQueueProxyCtorArgs", withdrawalQueueProxyCtorArgs);

        // Pool implementation constructor args
        bytes memory poolImplCtorArgs;
        if (p.poolType == uint256(Factory.WrapperType.NO_MINTING_NO_STRATEGY)) {
            poolImplCtorArgs = abi.encode(r.dashboard, p.allowlistEnabled, r.withdrawalQueueProxy);
        } else if (p.poolType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)) {
            poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, p.reserveRatioGapBP, r.withdrawalQueueProxy);
        } else if (p.poolType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, r.strategy, p.reserveRatioGapBP, r.withdrawalQueueProxy);
        } else {
            // GGV
            poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, r.strategy, p.reserveRatioGapBP, r.withdrawalQueueProxy);
        }
        out = vm.serializeBytes("pool", "poolImplCtorArgs", poolImplCtorArgs);

        // WQ implementation constructor args
        bytes memory withdrawalQueueImplCtorArgs = abi.encode(r.poolProxy, factoryView.LAZY_ORACLE(), p.maxFinalizationTime, p.minWithdrawalDelayTime);
        out = vm.serializeBytes("pool", "withdrawalQueueImplCtorArgs", withdrawalQueueImplCtorArgs);

        // Strategy constructor args (if any)
        if (r.strategy != address(0)) {
            address strategyProxyImpl = address(0);
            (bool okSpi, bytes memory retSpi) = r.strategy.staticcall(abi.encodeWithSignature("STRATEGY_PROXY_IMPL()"));
            if (okSpi && retSpi.length >= 32) {
                strategyProxyImpl = abi.decode(retSpi, (address));
            }
            bytes memory strategyCtorArgs = abi.encode(strategyProxyImpl, r.poolProxy, r.stethAddr, r.wstethAddr, p.teller, p.boringQueue);
            out = vm.serializeBytes("pool", "strategyCtorArgs", strategyCtorArgs);
        }

        vm.writeJson(out, outputJsonPath);
    }

    function _readFactoryAddress(string memory path) internal view returns (address factory) {
        string memory json = vm.readFile(path);
        // The deployment artifact should contain { deployment: { factory: "0x..." } }
        factory = vm.parseJsonAddress(json, "$.deployment.factory");
        require(factory != address(0), "factory not found");
    }

    function _readWrapperParams(string memory path) internal view returns (WrapperParams memory p) {
        string memory json = vm.readFile(path);
        p.poolType = vm.parseJsonUint(json, "$.poolType");
        p.nodeOperator = vm.parseJsonAddress(json, "$.nodeOperator");
        p.nodeOperatorManager = vm.parseJsonAddress(json, "$.nodeOperatorManager");
        p.nodeOperatorFeeBP = vm.parseJsonUint(json, "$.nodeOperatorFeeBP");
        p.confirmExpiry = vm.parseJsonUint(json, "$.confirmExpiry");
        p.maxFinalizationTime = vm.parseJsonUint(json, "$.maxFinalizationTime");
        p.minWithdrawalDelayTime = vm.parseJsonUint(json, "$.minWithdrawalDelayTime");
        p.allowlistEnabled = vm.parseJsonBool(json, "$.allowlistEnabled");
        p.value = vm.parseJsonUint(json, "$.connectDepositWei");

        // Parse only fields relevant to the pool type
        if (
            p.poolType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)
                || p.poolType == uint256(Factory.WrapperType.LOOP_STRATEGY)
                || p.poolType == uint256(Factory.WrapperType.GGV_STRATEGY)
        ) {
            p.reserveRatioGapBP = vm.parseJsonUint(json, "$.reserveRatioGapBP");
        }
        if (p.poolType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            p.loops = vm.parseJsonUint(json, "$.loops");
        }
        if (p.poolType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
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
        p.timelockExecutor = vm.parseJsonAddress(json, "$.timelock.executor");
    }

    function run() external {
        string memory factoryJsonPath = "deployments/pool-factory-latest.json";
        string memory paramsJsonPath = vm.envString("WRAPPER_PARAMS_JSON");
        string memory outputJsonPath = vm.envString("WRAPPER_DEPLOYED_JSON");

        require(bytes(paramsJsonPath).length != 0, "WRAPPER_PARAMS_JSON env var must be set and non-empty");
        require(bytes(outputJsonPath).length != 0, "WRAPPER_DEPLOYED_JSON env var must be set and non-empty");

        require(vm.isFile(factoryJsonPath), "deployments/pool-factory-latest.json file not found");
        if (!vm.isFile(paramsJsonPath)) {
            revert(string(abi.encodePacked("WRAPPER_PARAMS_JSON file does not exist at: ", paramsJsonPath)));
        }

        address factoryAddr = _readFactoryAddress(factoryJsonPath);
        WrapperParams memory p = _readWrapperParams(paramsJsonPath);

        // Check Lido total shares before broadcasting
        Factory factoryView = Factory(factoryAddr);
        uint256 totalShares = IStETH(factoryView.STETH()).getTotalShares();
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
        DeploymentResult memory r = _deployWrapper(factoryView, p);
        vm.stopBroadcast();

        // write artifact
        _writeWrapperArtifact(factoryView, p, r, outputJsonPath);

        console2.log("Wrapper deployed: vault", r.vault);
        console2.log("Wrapper proxy:", r.poolProxy);
        console2.log("WithdrawalQueue:", r.withdrawalQueueProxy);
        if (r.strategy != address(0)) console2.log("Strategy:", r.strategy);
        console2.log("Output written to", outputJsonPath);
    }
}
