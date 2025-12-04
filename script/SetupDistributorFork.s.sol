// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Distributor} from "../src/Distributor.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/**
 * @title SetupDistributorForkScript
 * @notice Complete script for testing distributor on a fork
 * @dev This script:
 *   1. Deploys a new ERC20 token
 *   2. Adds it to the distributor using impersonation (fork only)
 *   3. Mints tokens to the distributor address
 * 
 * Usage on Hoodi fork:
 * forge script script/SetupDistributorFork.s.sol:SetupDistributorForkScript \
 *   --rpc-url $HOODI_FORK_RPC \
 *   --broadcast \
 *   --private-key $PRIVATE_KEY \
 *   -vvvv
 * 
 * Or with just file:
 * just setup-distributor-fork
 */
contract SetupDistributorForkScript is Script {
    function run() external returns (address tokenAddress, uint256 finalBalance) {
        // Configuration from environment or defaults
        address distributorManager = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        address distributorAddress = 0x0adFB2DE8c64a5674d497DEC347162C6b261872F;
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1000000 * 10 ** 18)); // 1M tokens
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Test Reward Token"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("REWARD"));
        
        console.log("=== Setup Distributor Fork Test ===");
        console.log("Distributor Address:", distributorAddress);
        console.log("Mint Amount:", mintAmount);
        console.log("Token Name:", tokenName);
        console.log("Token Symbol:", tokenSymbol);
        console.log("");

        // Get distributor instance
        Distributor distributor = Distributor(distributorAddress);
        
        // Query current state
        console.log("=== Current Distributor State ===");
        bytes32 managerRole = distributor.MANAGER_ROLE();
        bytes32 adminRole = distributor.DEFAULT_ADMIN_ROLE();
        
        address manager = distributor.getRoleMember(managerRole, 0);
        address admin = distributor.getRoleMember(adminRole, 0);

        console.log("Manager address:", manager);
        console.log("Admin address:", admin);

        // Transfer ETH from distributorManager to admin for grantRole transaction
        console.log("Transferring ETH from distributorManager to admin...");
        vm.broadcast(distributorManager);
        (bool success,) = admin.call{value: 1 ether}("");
        require(success, "ETH transfer failed");
        console.log("Transferred 1 ETH to admin");
        console.log("");

        vm.broadcast(admin);
        distributor.grantRole(managerRole, distributorManager);
        

        console.log("");

        // Step 1: Deploy ERC20 token
        console.log("Step 1: Deploying MockERC20 token...");
        vm.startBroadcast();
        MockERC20 token = new MockERC20(tokenName, tokenSymbol);
        tokenAddress = address(token);
        vm.stopBroadcast();
        
        console.log("Token deployed at:", tokenAddress);
        console.log("Token name:", token.name());
        console.log("Token symbol:", token.symbol());
        console.log("Token decimals:", token.decimals());
        console.log("");

        // Step 2: Add token to distributor (using impersonation for fork)
        console.log("Step 2: Adding token to distributor...");
        console.log("Impersonating manager:", manager);
        
        vm.broadcast(manager);
        distributor.addToken(tokenAddress);

        
        
        console.log("Token added successfully!");
        console.log("");

        // Step 3: Mint tokens to distributor
        console.log("Step 3: Minting tokens to distributor...");
        vm.startBroadcast();
        token.mint(distributorAddress, mintAmount);
        vm.stopBroadcast();
        
        finalBalance = token.balanceOf(distributorAddress);
        console.log("Minted:", mintAmount);
        console.log("Distributor balance:", finalBalance);
        console.log("");

        // Verification
        console.log("=== Verification ===");
        address[] memory supportedTokens = distributor.getTokens();
        console.log("Number of supported tokens:", supportedTokens.length);
        
        bool isSupported = false;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            console.log("Token", i, ":", supportedTokens[i]);
            if (supportedTokens[i] == tokenAddress) {
                isSupported = true;
            }
        }
        
        console.log("");
        console.log("Token is supported:", isSupported);
        console.log("Balance check:", finalBalance == mintAmount);
        console.log("");
        
        if (!isSupported) {
            revert("Token was not added to distributor!");
        }
        
        if (finalBalance != mintAmount) {
            revert("Balance mismatch!");
        }

        console.log("=== Setup Complete! ===");
        console.log("Summary:");
        console.log("  Token Address:", tokenAddress);
        console.log("  Distributor Address:", distributorAddress);
        console.log("  Balance:", finalBalance);
        console.log("  Token is supported: YES");
        console.log("");
        console.log("Next steps:");
        console.log("1. Set up merkle tree with token rewards");
        console.log("2. Call distributor.setMerkleRoot() as manager");
        console.log("3. Test claiming with distributor.claim()");
    }
}

