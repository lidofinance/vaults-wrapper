// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import {Factory} from "src/Factory.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IOssifiableProxy} from "src/interfaces/IOssifiableProxy.sol";

contract DeployWrapper is Script {
    struct PoolParams {
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        uint256 maxFinalizationTime;
        uint256 minWithdrawalDelayTime;
        bool allowlistEnabled;
        bool mintingEnabled; // required by Factory.StvPoolConfig
        uint256 reserveRatioGapBP; // optional; used when minting is enabled / strategy present
        address strategyFactory; // optional; if set => strategy pool
        uint256 value; // msg.value to send (CONNECT_DEPOSIT)
        address timelockExecutor; // optional (not used by new Factory)
        string name;
        string symbol;
    }

    // struct DeploymentResult {
    //     address vault;
    //     address dashboard;
    //     address payable poolProxy;
    //     address withdrawalQueueProxy;
    //     address poolImpl;
    //     address withdrawalQueueImpl;
    //     address strategy;
    //     address timelockAdmin;
    //     address stethAddr;
    //     address wstethAddr;
    // }



    // function _writePoolArtifact(
    //     Factory factoryView,
    //     PoolParams memory p,
    //     Factory.StvPoolIntermediate memory intermediate,
    //     string memory outputJsonPath
    // ) internal {
    //     string memory out = vm.serializeAddress("pool", "factory", address(factoryView));
    //     out = vm.serializeAddress("pool", "vault", r.vault);
    //     out = vm.serializeAddress("pool", "dashboard", r.dashboard);
    //     out = vm.serializeAddress("pool", "poolProxy", r.poolProxy);
    //     out = vm.serializeAddress("pool", "poolImpl", r.poolImpl);
    //     out = vm.serializeAddress("pool", "withdrawalQueue", r.withdrawalQueueProxy);
    //     out = vm.serializeAddress("pool", "withdrawalQueueImpl", r.withdrawalQueueImpl);
    //     out = vm.serializeUint("pool", "poolType", p.poolType);
    //     out = vm.serializeAddress("pool", "strategy", r.strategy);
    //     out = vm.serializeAddress("pool", "timelock", r.timelockAdmin);

    //     // Proxy constructor args
    //     bytes memory poolProxyCtorArgs = abi.encode(factoryView.DUMMY_IMPLEMENTATION(), address(factoryView), bytes(""));
    //     out = vm.serializeBytes("pool", "poolProxyCtorArgs", poolProxyCtorArgs);

    //     // WQ proxy constructor args
    //     bytes memory wqInitData = abi.encodeCall(WithdrawalQueue.initialize, (p.nodeOperator, p.nodeOperator));
    //     bytes memory withdrawalQueueProxyCtorArgs = abi.encode(r.withdrawalQueueImpl, address(factoryView), wqInitData);
    //     out = vm.serializeBytes("pool", "withdrawalQueueProxyCtorArgs", withdrawalQueueProxyCtorArgs);

    //     // Pool implementation constructor args
    //     bytes memory poolImplCtorArgs;
    //     if (p.poolType == uint256(Factory.PoolType.NO_MINTING_NO_STRATEGY)) {
    //         poolImplCtorArgs = abi.encode(r.dashboard, p.allowlistEnabled, r.withdrawalQueueProxy);
    //     } else if (p.poolType == uint256(Factory.PoolType.MINTING_NO_STRATEGY)) {
    //         poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, p.reserveRatioGapBP, r.withdrawalQueueProxy);
    //     } else if (p.poolType == uint256(Factory.PoolType.LOOP_STRATEGY)) {
    //         poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, r.strategy, p.reserveRatioGapBP, r.withdrawalQueueProxy);
    //     } else {
    //         // GGV
    //         poolImplCtorArgs = abi.encode(r.dashboard, r.stethAddr, p.allowlistEnabled, r.strategy, p.reserveRatioGapBP, r.withdrawalQueueProxy);
    //     }
    //     out = vm.serializeBytes("pool", "poolImplCtorArgs", poolImplCtorArgs);

    //     // WQ implementation constructor args
    //     bytes memory withdrawalQueueImplCtorArgs = abi.encode(r.poolProxy, factoryView.LAZY_ORACLE(), p.maxFinalizationTime, p.minWithdrawalDelayTime);
    //     out = vm.serializeBytes("pool", "withdrawalQueueImplCtorArgs", withdrawalQueueImplCtorArgs);

    //     // Strategy constructor args (if any)
    //     if (r.strategy != address(0)) {
    //         address strategyProxyImpl = address(0);
    //         (bool okSpi, bytes memory retSpi) = r.strategy.staticcall(abi.encodeWithSignature("STRATEGY_PROXY_IMPL()"));
    //         if (okSpi && retSpi.length >= 32) {
    //             strategyProxyImpl = abi.decode(retSpi, (address));
    //         }
    //         bytes memory strategyCtorArgs = abi.encode(strategyProxyImpl, r.poolProxy, r.stethAddr, r.wstethAddr, p.teller, p.boringQueue);
    //         out = vm.serializeBytes("pool", "strategyCtorArgs", strategyCtorArgs);
    //     }

    //     vm.writeJson(out, outputJsonPath);
    // }

    function _readFactoryAddress(string memory path) internal view returns (address factory) {
        string memory json = vm.readFile(path);
        // The deployment artifact should contain { deployment: { factory: "0x..." } }
        factory = vm.parseJsonAddress(json, "$.deployment.factory");
        require(factory != address(0), "factory not found");
    }

    function _readPoolParams(string memory path) internal view returns (PoolParams memory p) {
        string memory json = vm.readFile(path);
        p.nodeOperator = vm.parseJsonAddress(json, "$.nodeOperator");
        p.nodeOperatorManager = vm.parseJsonAddress(json, "$.nodeOperatorManager");
        p.nodeOperatorFeeBP = vm.parseJsonUint(json, "$.nodeOperatorFeeBP");
        p.confirmExpiry = vm.parseJsonUint(json, "$.confirmExpiry");
        p.maxFinalizationTime = vm.parseJsonUint(json, "$.maxFinalizationTime");
        p.minWithdrawalDelayTime = vm.parseJsonUint(json, "$.minWithdrawalDelayTime");
        p.allowlistEnabled = vm.parseJsonBool(json, "$.allowlistEnabled");
        p.value = vm.parseJsonUint(json, "$.connectDepositWei");

        // Parse only fields relevant to the pool type
        // Optional: explicit mintingEnabled in JSON, else derive later
        try vm.parseJsonBool(json, "$.mintingEnabled") returns (bool me) {
            p.mintingEnabled = me;
        } catch {}

        // Reserve ratio gap (optional); if set or strategy present, Factory will treat as minting-enabled
        try vm.parseJsonUint(json, "$.reserveRatioGapBP") returns (uint256 rr) {
            p.reserveRatioGapBP = rr;
        } catch {}

        // Strategy-specific params (optional)
        try vm.parseJsonAddress(json, "$.strategy.factory") returns (address sf) {
            p.strategyFactory = sf;
        } catch {}

        // Optional legacy field
        try vm.parseJsonAddress(json, "$.timelock.executor") returns (address ex) {
            p.timelockExecutor = ex;
        } catch {}

        try vm.parseJsonString(json, "$.token.name") returns (string memory tokenName) {
            p.name = tokenName;
        } catch {}

        try vm.parseJsonString(json, "$.token.symbol") returns (string memory tokenSymbol) {
            p.symbol = tokenSymbol;
        } catch {}
    }

    function run() external {
        string memory factoryJsonPath = "deployments/pool-factory-latest.json";
        string memory paramsJsonPath = vm.envString("POOL_PARAMS_JSON");

        // string memory outputJsonPath = vm.envString("WRAPPER_DEPLOYED_JSON");
        string memory outputJsonPath = string(
            abi.encodePacked(
                "deployments/pool-",
                vm.toString(block.chainid),
                "-",
                vm.toString(block.timestamp),
                ".json"
            )
        );

        require(bytes(paramsJsonPath).length != 0, "WRAPPER_PARAMS_JSON env var must be set and non-empty");
        require(bytes(outputJsonPath).length != 0, "WRAPPER_DEPLOYED_JSON env var must be set and non-empty");

        require(vm.isFile(factoryJsonPath), "deployments/pool-factory-latest.json file not found");
        if (!vm.isFile(paramsJsonPath)) {
            revert(string(abi.encodePacked("WRAPPER_PARAMS_JSON file does not exist at: ", paramsJsonPath)));
        }

        Factory factory = Factory(_readFactoryAddress(factoryJsonPath));
        PoolParams memory p = _readPoolParams(paramsJsonPath);

        require(bytes(p.name).length != 0, "token.name missing");
        require(bytes(p.symbol).length != 0, "token.symbol missing");

        // Check Lido total shares before broadcasting
        // uint256 totalShares = IStETH(factory.STETH()).getTotalShares();
        // console2.log("Lido getTotalShares:", totalShares);
        // require(totalShares > 100000, "Lido totalShares must be > 100000");

        vm.startBroadcast();

        Factory.StrategyConfig memory strategyConfig = Factory.StrategyConfig({
            factory: p.strategyFactory
        });

        Factory.StvPoolIntermediate memory intermediate = factory.createPoolStart{value: p.value}(
            Factory.PoolFullConfig({
                allowlistEnabled: p.allowlistEnabled,
                mintingEnabled: p.mintingEnabled,
                owner: p.nodeOperator,
                nodeOperator: p.nodeOperator,
                nodeOperatorManager: p.nodeOperatorManager,
                nodeOperatorFeeBP: p.nodeOperatorFeeBP,
                confirmExpiry: p.confirmExpiry,
                maxFinalizationTime: p.maxFinalizationTime,
                minWithdrawalDelayTime: p.minWithdrawalDelayTime,
                reserveRatioGapBP: p.reserveRatioGapBP,
                name: p.name,
                symbol: p.symbol
            }),
            strategyConfig
        );

        Factory.StvPoolDeployment memory deployment = factory.createPoolFinish(intermediate, strategyConfig);

        console2.log("Deployment Vault", deployment.vault);
        console2.log("Deployment Dashboard", deployment.dashboard);
        console2.log("Deployment Pool", deployment.pool);
        console2.log("Deployment WithdrawalQueue", deployment.withdrawalQueue);
        console2.log("Deployment Distributor", deployment.distributor);
        console2.log("Deployment Timelock", deployment.timelock);
        console2.log("Deployment PoolType", uint256(deployment.poolType));
        console2.log("Strategy", deployment.strategy);

        vm.stopBroadcast();

    }
}
