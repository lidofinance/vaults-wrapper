// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Distributor} from "../src/Distributor.sol";
import {WrapperA} from "../src/WrapperA.sol";
import {WrapperBase} from "../src/WrapperBase.sol";

import {ILidoLocator} from "lido-core/contracts/common/interfaces/ILidoLocator.sol";

import {ILido} from "src/interfaces/ILido.sol";
import {MockDashboard} from "../test/mocks/MockDashboard.sol";
import {MockVaultHub} from "../test/mocks/MockVaultHub.sol";
import {MockStakingVault} from "../test/mocks/MockStakingVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import { JsonObj, Json } from "./utils/Json.sol";

interface IHashConsensus {
    function updateInitialEpoch(uint256 initialEpoch) external;
}

contract DeployWrapper is Script {
    ILidoLocator public locator;
    ILido public steth;

    address internal deployer;
    address public agent;
    address public hashConsensus;

    string public artifactDir = "./artifacts/";

    uint256 public constant INITIAL_LIDO_SUBMISSION = 10_000 ether;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;
    uint256 public constant LIDO_TOTAL_BASIS_POINTS = 10000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockStakingVault stakingVault = new MockStakingVault();
        MockVaultHub vaultHub = new MockVaultHub();
        MockDashboard dashboard = new MockDashboard(address(vaultHub), address(stakingVault), deployer);

        WrapperA wrapper = new WrapperA(
            address(dashboard),
            deployer,
            "STV",
            "STV",
            false // whitelist disabled
        );

        MockERC20 obolToken = new MockERC20("ObolToken", "ObolTest");
        MockERC20 ssvToken = new MockERC20("SSVToken", "SSVTest");

        Distributor distributor = new Distributor(deployer);
        distributor.addToken(address(obolToken));
        distributor.addToken(address(ssvToken));

        obolToken.mint(address(distributor), 2 ether);
        ssvToken.mint(address(distributor), 3 ether);

        vm.stopBroadcast();

        console.log("wrapper", address(wrapper));
        console.log("dashboard", address(dashboard));
        console.log("vaultHub", address(vaultHub));
        console.log("stakingVault", address(stakingVault));
        console.log("distributor", address(distributor));
        console.log("obolToken", address(obolToken));
        console.log("ssvToken", address(ssvToken));

        performTestTransactions(wrapper);

        console.log("wrapper balance of obolToken", obolToken.balanceOf(address(distributor)));
        console.log("wrapper balance of ssvToken", ssvToken.balanceOf(address(distributor)));

        JsonObj memory deployJson = Json.newObj("artifact");
        deployJson.set("wrapper", address(wrapper));
        deployJson.set("distributor", address(distributor));
        deployJson.set("obolToken", address(obolToken));
        deployJson.set("ssvToken", address(ssvToken));
        deployJson.set("blockNumber", block.number);
        vm.writeJson(deployJson.str, _deployJsonFilename());
    }

    function _deployJsonFilename() internal view returns (string memory) {
        return
            string(
                abi.encodePacked(artifactDir, "deploy-local.json")
            );
    }

    function performTestTransactions(WrapperBase wrapper) internal {
        // Create test users
        uint256 user1PrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        uint256 user2PrivateKey = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

        uint256 user3PrivateKey = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
        uint256 user4PrivateKey = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

        uint256 user5PrivateKey = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
        uint256 user6PrivateKey = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;


        address user1 = vm.addr(user1PrivateKey);
        address user2 = vm.addr(user2PrivateKey);

        // Fund users with random amounts in a loop
        uint256[] memory users = new uint256[](6);
        users[0] = user1PrivateKey;
        users[1] = user2PrivateKey;
        users[2] = user3PrivateKey;
        users[3] = user4PrivateKey;
        users[4] = user5PrivateKey;
        users[5] = user6PrivateKey;

        for(uint i = 0; i < users.length; i++) {
            // Generate random amount between 1-100 ETH
            uint256 amount = uint256(keccak256(abi.encodePacked(block.timestamp, users[i], i))) % 100 ether + 1 ether;
            vm.deal(vm.addr(users[i]), amount);
            console.log(string.concat("Funded user", vm.toString(i + 1), " with ", vm.toString(amount), " ETH"));

            // Fund the wrapper contract with the user's ETH
            vm.startBroadcast(users[i]);
            wrapper.depositETH{value: amount}(vm.addr(users[i]));
            vm.stopBroadcast();
        }


        console.log("\n=== Final State ===");
        console.log("Wrapper total supply:", wrapper.totalSupply());
        console.log("Wrapper total assets:", wrapper.totalAssets());

        for(uint i = 0; i < users.length; i++) {
            console.log(string.concat("User", vm.toString(i + 1), " balance: ", vm.toString(wrapper.balanceOf(vm.addr(users[i])))));
        }
    }

}