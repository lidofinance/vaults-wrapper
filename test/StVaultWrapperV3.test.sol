// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {Wrapper} from "../src/Wrapper.sol";
import {MockDashboard} from "./mocks/MockDashboard.sol";
import {MockVaultHub} from "./mocks/MockVaultHub.sol";
import {MockStakingVault} from "./mocks/MockStakingVault.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {Escrow} from "../src/Escrow.sol";
import {ExampleStrategy} from "../src/ExampleStrategy.sol";

contract StVaultWrapperV3Test is Test {
    Wrapper public wrapper;
    MockDashboard public dashboard;
    MockVaultHub public vaultHub;
    MockStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    Escrow public escrow;
    ExampleStrategy public strategy;

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    event VaultFunded(uint256 amount);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event WithdrawalProcessed(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);

    function setUp() public {
        stakingVault = new MockStakingVault();
        vaultHub = new MockVaultHub();
        dashboard = new MockDashboard(address(vaultHub), address(stakingVault));

        wrapper = new Wrapper(
            address(dashboard),
            address(withdrawalQueue),
            address(this), // Owner of the wrapper
            "Staked ETH Vault Wrapper",
            "stvETH"
        );

        address aavePool = address(0x1);
        strategy = new ExampleStrategy(
            address(stakingVault),
            address(aavePool)
        );
        escrow = new Escrow(
            address(wrapper),
            address(withdrawalQueue),
            address(strategy)
        );

        // Fund the vault initially
        // vm.deal(address(vaultHub), 100 ether);
        // vaultHub.simulateRewards(dashboard.stakingVault(), 100 ether);

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
    }

    function test_DepositETH() public {
        vm.deal(user1, 10 ether);

        vm.startPrank(user1);
        uint256 user1shares = wrapper.depositETH{value: 10 ether}();
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2shares = wrapper.depositETH{value: 22 ether}();
        vm.stopPrank();

        assertEq(wrapper.balanceOf(user1), user1shares);
        assertEq(wrapper.balanceOf(user2), user2shares);

        assertEq(wrapper.totalAssets(), 32 ether);
        assertEq(address(dashboard.stakingVault()).balance, 32 ether);

        console.log("=== Initial State ===");
        console.log("User1 shares:", user1shares, "stvW");
        console.log("User2 shares:", user2shares, "stvW");
        console.log("Total supply:", wrapper.totalSupply(), "stvW");
        console.log("Total assets:", wrapper.totalAssets(), "ETH");

        // Calculate initial exchange rate
        uint256 initialExchangeRate = (wrapper.totalAssets() * 1e18) /
            wrapper.totalSupply();
        console.log(
            "Initial exchange rate:",
            initialExchangeRate,
            "ETH per stvW"
        );

        // 2. Simulate rewards (vault totalValue increases)
        int256 rewards = 8 ether; // 25% increase in total value
        vaultHub.mock_simulateRewards(address(stakingVault), rewards);

        console.log("\n=== After Rewards ===");
        console.log("Rewards added:", uint256(rewards), "ETH");
        console.log("New total assets:", wrapper.totalAssets(), "ETH");
        console.log(
            "User1 shares (unchanged):",
            wrapper.balanceOf(user1),
            "stvW"
        );
        console.log(
            "User2 shares (unchanged):",
            wrapper.balanceOf(user2),
            "stvW"
        );

        // Verify shares didn't change
        assertEq(wrapper.balanceOf(user1), user1shares);
        assertEq(wrapper.balanceOf(user2), user2shares);

        // Verify totalAssets increased
        assertEq(wrapper.totalAssets(), 32 ether + uint256(rewards));

        // Calculate new exchange rate
        uint256 newExchangeRate = (wrapper.totalAssets() * 1e18) /
            wrapper.totalSupply();
        console.log("New exchange rate:", newExchangeRate, "ETH per stvW");

        // Verify exchange rate increased
        assertGt(newExchangeRate, initialExchangeRate);

        // 3. Test that users can now withdraw more ETH for the same shares
        // Calculate how much ETH each user can get for their shares now
        uint256 user1EthValue = wrapper.previewRedeem(user1shares);
        uint256 user2EthValue = wrapper.previewRedeem(user2shares);

        console.log("\n=== ETH Value of Shares After Rewards ===");
        console.log(
            "User1 ETH value:",
            user1EthValue / 1e18,
            "ETH (was 10 ETH)"
        );
        console.log(
            "User2 ETH value:",
            user2EthValue / 1e18,
            "ETH (was 22 ETH)"
        );
    }
}
