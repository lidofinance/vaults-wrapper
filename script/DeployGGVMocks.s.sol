// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import "forge-std/Script.sol";

import {MockBoringVault} from "src/mock/ggv/MockBoringVault.sol";
import {MockTeller} from "src/mock/ggv/MockTeller.sol";
import {MockBoringOnChainQueue} from "src/mock/ggv/MockBoringOnChainQueue.sol";
import {MockBoringSolver} from "src/mock/ggv/MockBoringSolver.sol";

contract DeployGGVMocks is Script {
    function run() external {
        string memory outputJsonPath = _getOutputPath();

        vm.startBroadcast();
        MockBoringVault vault = new MockBoringVault();
        MockTeller teller = new MockTeller(address(vault));
        MockBoringOnChainQueue queue = new MockBoringOnChainQueue(address(vault));
        MockBoringSolver solver = new MockBoringSolver(address(vault), address(queue));
        vm.stopBroadcast();

        string memory out = vm.serializeAddress("ggv", "boringVault", address(vault));
        out = vm.serializeAddress("ggv", "teller", address(teller));
        out = vm.serializeAddress("ggv", "boringOnChainQueue", address(queue));
        out = vm.serializeAddress("ggv", "solver", address(solver));
        vm.writeJson(out, outputJsonPath);

        console2.log("GGV mocks deployed:");
        console2.log("  vault:", address(vault));
        console2.log("  teller:", address(teller));
        console2.log("  queue:", address(queue));
        console2.log("  solver:", address(solver));
        console2.log("Output written to", outputJsonPath);
    }

    function _getOutputPath() internal view returns (string memory p) {
        // Prefer env var if provided, fallback to deployments/ggv-mocks-<network>.json
        try vm.envString("GGV_MOCKS_DEPLOYED_JSON") returns (string memory provided) {
            if (bytes(provided).length != 0) {
                return provided;
            }
        } catch {}
        string memory network = "local";
        try vm.envString("NETWORK") returns (string memory n) {
            if (bytes(n).length != 0) network = n;
        } catch {}
        return string(abi.encodePacked("deployments/ggv-mocks-", network, ".json"));
    }
}


