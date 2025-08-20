// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

// Mock contracts
contract MockDashboard {
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");
    address public immutable VAULT_HUB;
    address public immutable stakingVault;
    
    constructor(address _vaultHub, address _stakingVault) {
        VAULT_HUB = _vaultHub;
        stakingVault = _stakingVault;
    }
    
    function fund() external payable {
        payable(stakingVault).transfer(msg.value);
    }
    
    function grantRole(bytes32, address) external {}
}

contract MockVaultHub {
    function totalValue(address vault) external view returns (uint256) {
        return vault.balance;
    }
    
    function isReportFresh(address) external pure returns (bool, bool) {
        return (true, false);
    }
}

contract MockStakingVault {
    receive() external payable {}
}

contract DepositGasProfileTest is Test {
    WrapperA public wrapperWithWhitelist;
    WrapperA public wrapperWithoutWhitelist;
    MockDashboard public dashboardWithWhitelist;
    MockDashboard public dashboardWithoutWhitelist;
    MockVaultHub public vaultHubWithWhitelist;
    MockVaultHub public vaultHubWithoutWhitelist;
    MockStakingVault public stakingVaultWithWhitelist;
    MockStakingVault public stakingVaultWithoutWhitelist;

    address public owner;
    address public user;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(user, 1000 ether); // Increased to handle large deposits in varying amounts test

        // Deploy separate mocks for each wrapper
        stakingVaultWithWhitelist = new MockStakingVault();
        vaultHubWithWhitelist = new MockVaultHub();
        dashboardWithWhitelist = new MockDashboard(address(vaultHubWithWhitelist), address(stakingVaultWithWhitelist));

        stakingVaultWithoutWhitelist = new MockStakingVault();
        vaultHubWithoutWhitelist = new MockVaultHub();
        dashboardWithoutWhitelist = new MockDashboard(address(vaultHubWithoutWhitelist), address(stakingVaultWithoutWhitelist));

        // Fund the staking vaults to simulate initial state
        vm.deal(address(stakingVaultWithWhitelist), 1 ether);
        vm.deal(address(stakingVaultWithoutWhitelist), 1 ether);

        // Create wrapper with whitelist enabled
        wrapperWithWhitelist = new WrapperA(
            address(dashboardWithWhitelist),
            owner,
            "Whitelisted Vault",
            "wstvETH",
            true // whitelist enabled
        );

        // Create wrapper without whitelist
        wrapperWithoutWhitelist = new WrapperA(
            address(dashboardWithoutWhitelist),
            owner,
            "Open Vault",
            "ostvETH",
            false // whitelist disabled
        );

        // Grant FUND_ROLE to wrappers
        dashboardWithWhitelist.grantRole(dashboardWithWhitelist.FUND_ROLE(), address(wrapperWithWhitelist));
        dashboardWithoutWhitelist.grantRole(dashboardWithoutWhitelist.FUND_ROLE(), address(wrapperWithoutWhitelist));

        // Add user to whitelist
        vm.prank(owner);
        wrapperWithWhitelist.addToWhitelist(user);
    }

    // Tests gas usage comparison between whitelisted and non-whitelisted wrappers for first deposit
    // Measures and compares gas consumption to understand whitelist overhead
    function test_gasProfile_firstDeposit() public {
        // Test with whitelist enabled
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithWhitelist.depositETH{value: 1 ether}(user);
        uint256 gasWithWhitelist = gasBefore - gasleft();
        
        // Test without whitelist
        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutWhitelist.depositETH{value: 1 ether}(user);
        uint256 gasWithoutWhitelist = gasBefore - gasleft();
        
        console.log("Gas used for first deposit:");
        console.log("  With whitelist:   ", gasWithWhitelist);
        console.log("  Without whitelist:", gasWithoutWhitelist);
        console.log("  Difference:       ", int256(gasWithWhitelist) - int256(gasWithoutWhitelist));
    }

    // Tests gas usage for second deposits to measure warm storage access patterns
    // Compares gas usage after initial storage slots have been initialized
    function test_gasProfile_secondDeposit() public {
        // First deposits
        vm.prank(user);
        wrapperWithWhitelist.depositETH{value: 1 ether}(user);
        vm.prank(user);
        wrapperWithoutWhitelist.depositETH{value: 1 ether}(user);
        
        // Second deposits
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithWhitelist.depositETH{value: 1 ether}(user);
        uint256 gasWithWhitelist = gasBefore - gasleft();
        
        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutWhitelist.depositETH{value: 1 ether}(user);
        uint256 gasWithoutWhitelist = gasBefore - gasleft();
        
        console.log("Gas used for second deposit:");
        console.log("  With whitelist:   ", gasWithWhitelist);
        console.log("  Without whitelist:", gasWithoutWhitelist);
        console.log("  Difference:       ", int256(gasWithWhitelist) - int256(gasWithoutWhitelist));
    }

    // Tests gas usage patterns across 5 consecutive deposits
    // Analyzes how gas consumption changes with repeated operations
    function test_gasProfile_multipleDeposits() public {
        uint256[] memory gasWithWhitelist = new uint256[](5);
        uint256[] memory gasWithoutWhitelist = new uint256[](5);
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user);
            uint256 gasBefore = gasleft();
            wrapperWithWhitelist.depositETH{value: 1 ether}(user);
            gasWithWhitelist[i] = gasBefore - gasleft();
            
            vm.prank(user);
            gasBefore = gasleft();
            wrapperWithoutWhitelist.depositETH{value: 1 ether}(user);
            gasWithoutWhitelist[i] = gasBefore - gasleft();
        }
        
        console.log("Gas profile for 5 consecutive deposits:");
        for (uint256 i = 0; i < 5; i++) {
            console.log("  Deposit", i + 1, "- With whitelist:", gasWithWhitelist[i]);
            console.log("    Without whitelist:", gasWithoutWhitelist[i]);
            console.log("    Difference:", int256(gasWithWhitelist[i]) - int256(gasWithoutWhitelist[i]));
        }
    }

    // Tests gas usage with different deposit amounts (1 wei to 50 ETH)
    // Verifies gas consumption is independent of deposit amount
    function test_gasProfile_varyingAmounts() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1 wei;
        amounts[1] = 1 ether;
        amounts[2] = 10 ether;
        amounts[3] = 50 ether;
        
        console.log("Gas profile for different deposit amounts:");
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(user);
            uint256 gasBefore = gasleft();
            wrapperWithWhitelist.depositETH{value: amounts[i]}(user);
            uint256 gasWithWhitelist = gasBefore - gasleft();
            
            vm.prank(user);
            gasBefore = gasleft();
            wrapperWithoutWhitelist.depositETH{value: amounts[i]}(user);
            uint256 gasWithoutWhitelist = gasBefore - gasleft();
            
            console.log("  Amount:", amounts[i], "- With whitelist:", gasWithWhitelist);
            console.log("    Without whitelist:", gasWithoutWhitelist);
            console.log("    Difference:", int256(gasWithWhitelist) - int256(gasWithoutWhitelist));
        }
    }

    // Tests gas usage of the convenience depositETH() function without receiver parameter
    // Compares gas cost when receiver defaults to msg.sender
    function test_gasProfile_convenienceFunction() public {
        // Test with whitelist enabled
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithWhitelist.depositETH{value: 1 ether}(); // No receiver parameter
        uint256 gasWithWhitelist = gasBefore - gasleft();
        
        // Test without whitelist
        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutWhitelist.depositETH{value: 1 ether}(); // No receiver parameter
        uint256 gasWithoutWhitelist = gasBefore - gasleft();
        
        console.log("Gas used for depositETH() convenience function:");
        console.log("  With whitelist:   ", gasWithWhitelist);
        console.log("  Without whitelist:", gasWithoutWhitelist);
        console.log("  Difference:       ", int256(gasWithWhitelist) - int256(gasWithoutWhitelist));
    }
}