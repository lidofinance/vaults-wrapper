// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";
import {Factory} from "src/Factory.sol";
import {WrapperBase} from "src/WrapperBase.sol";
import {WrapperC} from "src/WrapperC.sol";
import {IStETH} from "src/interfaces/IStETH.sol";

contract DeployWrapper is Script {
    struct WrapperParams {
        uint256 wrapperType; // 0:A, 1:B, 2:LOOP, 3:GGV
        address nodeOperator;
        address nodeOperatorManager;
        uint256 nodeOperatorFeeBP;
        uint256 confirmExpiry;
        bool allowlistEnabled;
        uint256 reserveRatioGapBP; // B/C only
        uint256 loops; // LOOP only
        address teller; // GGV only
        address boringQueue; // GGV only
        uint256 value; // msg.value to send (CONNECT_DEPOSIT)
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
        p.allowlistEnabled = vm.parseJsonBool(json, "$.allowlistEnabled");
        // Parse only fields relevant to the wrapper type
        if (
            p.wrapperType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY) ||
            p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY) ||
            p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)
        ) {
            p.reserveRatioGapBP = vm.parseJsonUint(json, "$.reserveRatioGapBP");
        }
        if (p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            p.loops = vm.parseJsonUint(json, "$.loops");
        }
        if (p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            p.teller = vm.parseJsonAddress(json, "$.teller");
            p.boringQueue = vm.parseJsonAddress(json, "$.boringQueue");
        }
        p.value = vm.parseJsonUint(json, "$.value");
    }

    function run() external {
        string memory factoryJsonPath = vm.envOr("FACTORY_JSON", string("deployments/wrapper-local.json"));
        string memory paramsJsonPath = vm.envOr("WRAPPER_PARAMS_JSON", string("script/deploy-local-config.json"));
        string memory outputJsonPath = vm.envOr("OUTPUT_INSTANCE_JSON", string("deployments/wrapper-instance.json"));

        address factoryAddr = _readFactoryAddress(factoryJsonPath);
        WrapperParams memory p = _readWrapperParams(paramsJsonPath);

        // Check Lido total shares before broadcasting
        Factory factoryView = Factory(factoryAddr);
        address stethAddr = factoryView.STETH();
        uint256 totalShares = IStETH(stethAddr).getTotalShares();
        console2.log("Lido getTotalShares:", totalShares);
        require(totalShares > 100000, "Lido totalShares must be > 100000");

        vm.startBroadcast();
        Factory factory = Factory(factoryAddr);

        address vault;
        address dashboard;
        address payable wrapperProxy;
        address withdrawalQueueProxy;
        address strategy = address(0);

        if (p.wrapperType == uint256(Factory.WrapperType.NO_MINTING_NO_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithNoMintingNoStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.allowlistEnabled
            );
        } else if (p.wrapperType == uint256(Factory.WrapperType.MINTING_NO_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithMintingNoStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.allowlistEnabled,
                p.reserveRatioGapBP
            );
        } else if (p.wrapperType == uint256(Factory.WrapperType.LOOP_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithLoopStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.allowlistEnabled,
                p.reserveRatioGapBP,
                p.loops
            );
            strategy = address(WrapperC(wrapperProxy).STRATEGY());
        } else if (p.wrapperType == uint256(Factory.WrapperType.GGV_STRATEGY)) {
            (vault, dashboard, wrapperProxy, withdrawalQueueProxy) = factory.createVaultWithGGVStrategy{value: p.value}(
                p.nodeOperator,
                p.nodeOperatorManager,
                p.nodeOperatorFeeBP,
                p.confirmExpiry,
                p.allowlistEnabled,
                p.reserveRatioGapBP,
                p.teller,
                p.boringQueue
            );
            strategy = address(WrapperC(wrapperProxy).STRATEGY());
        } else {
            revert("invalid wrapperType");
        }

        vm.stopBroadcast();

        // write artifact
        string memory out = vm.serializeAddress("wrapper", "factory", factoryAddr);
        out = vm.serializeAddress("wrapper", "vault", vault);
        out = vm.serializeAddress("wrapper", "dashboard", dashboard);
        out = vm.serializeAddress("wrapper", "wrapperProxy", wrapperProxy);
        out = vm.serializeAddress("wrapper", "withdrawalQueue", withdrawalQueueProxy);
        out = vm.serializeUint("wrapper", "wrapperType", p.wrapperType);
        out = vm.serializeAddress("wrapper", "strategy", strategy);
        vm.writeJson(out, outputJsonPath);

        console2.log("Wrapper deployed: vault", vault);
        console2.log("Wrapper proxy:", wrapperProxy);
        console2.log("WithdrawalQueue:", withdrawalQueueProxy);
        if (strategy != address(0)) console2.log("Strategy:", strategy);
        console2.log("Output written to", outputJsonPath);
    }
}


