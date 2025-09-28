// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperBase} from "src/WrapperBase.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {MockLazyOracle} from "../mocks/MockLazyOracle.sol";

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

    function maxLockableValue() external view returns (uint256) {
        return stakingVault.balance;
    }
}

contract MockVaultHub {
    function totalValue(address vault) external view returns (uint256) {
        return vault.balance;
    }

    function isReportFresh(address) external pure returns (bool, bool) {
        return (true, false);
    }

    function CONNECT_DEPOSIT() external pure returns (uint256) {
        return 1 ether;
    }
}

contract MockStakingVault {
    receive() external payable {}
}

contract DepositGasProfileTest is Test {
    WrapperA public wrapperWithAllowList;
    WrapperA public wrapperWithoutAllowList;
    MockDashboard public dashboardWithAllowList;
    MockDashboard public dashboardWithoutAllowList;
    MockVaultHub public vaultHubWithAllowList;
    MockVaultHub public vaultHubWithoutAllowList;
    MockStakingVault public stakingVaultWithAllowList;
    MockStakingVault public stakingVaultWithoutAllowList;

    address public owner;
    address public user;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(user, 1000 ether); // Increased to handle large deposits in varying amounts test

        // Deploy separate mocks for each wrapper
        stakingVaultWithAllowList = new MockStakingVault();
        vaultHubWithAllowList = new MockVaultHub();
        dashboardWithAllowList = new MockDashboard(address(vaultHubWithAllowList), address(stakingVaultWithAllowList));

        stakingVaultWithoutAllowList = new MockStakingVault();
        vaultHubWithoutAllowList = new MockVaultHub();
        dashboardWithoutAllowList =
            new MockDashboard(address(vaultHubWithoutAllowList), address(stakingVaultWithoutAllowList));

        // Fund the staking vaults to simulate initial state
        vm.deal(address(stakingVaultWithAllowList), 1 ether);
        vm.deal(address(stakingVaultWithoutAllowList), 1 ether);

        // Create wrapper with allowlist enabled
        // Precreate wrapper proxy addresses first
        ERC1967Proxy allowListProxy;
        ERC1967Proxy openProxy;

        MockLazyOracle lazyOracle = new MockLazyOracle();
        address wqImpl1 = address(new WithdrawalQueue(address(0), address(lazyOracle), 30 days));
        address wqProxy1 = address(new ERC1967Proxy(wqImpl1, ""));
        WrapperA allowListImpl = new WrapperA(address(dashboardWithAllowList), true, wqProxy1);
        bytes memory initDataAllowList =
            abi.encodeCall(WrapperBase.initialize, (owner, owner, "AllowListed Vault", "wstvETH"));
        allowListProxy = new ERC1967Proxy(address(allowListImpl), initDataAllowList);
        wrapperWithAllowList = WrapperA(payable(address(allowListProxy)));

        // Create wrapper without allowlist
        address wqImpl2 = address(new WithdrawalQueue(address(0), address(lazyOracle), 30 days));
        address wqProxy2 = address(new ERC1967Proxy(wqImpl2, ""));
        WrapperA openImpl = new WrapperA(address(dashboardWithoutAllowList), false, wqProxy2);
        bytes memory initDataOpen = abi.encodeCall(WrapperBase.initialize, (owner, owner, "Open Vault", "ostvETH"));
        openProxy = new ERC1967Proxy(address(openImpl), initDataOpen);
        wrapperWithoutAllowList = WrapperA(payable(address(openProxy)));

        // Grant FUND_ROLE to wrappers
        dashboardWithAllowList.grantRole(dashboardWithAllowList.FUND_ROLE(), address(wrapperWithAllowList));
        dashboardWithoutAllowList.grantRole(dashboardWithoutAllowList.FUND_ROLE(), address(wrapperWithoutAllowList));

        // Add user to allowlist
        vm.prank(owner);
        wrapperWithAllowList.addToAllowList(user);
    }

    // Tests gas usage comparison between allowlisted and non-allowlisted wrappers for first deposit
    // Measures and compares gas consumption to understand allowlist overhead
    function test_gasProfile_firstDeposit() public {
        // Test with allowlist enabled
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithAllowList.depositETH{value: 1 ether}(user);
        uint256 gasWithAllowList = gasBefore - gasleft();

        // Test without allowlist
        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutAllowList.depositETH{value: 1 ether}(user);
        uint256 gasWithoutAllowList = gasBefore - gasleft();

        console.log("Gas used for first deposit:");
        console.log("  With allowlist:   ", gasWithAllowList);
        console.log("  Without allowlist:", gasWithoutAllowList);
        console.log("  Difference:       ", int256(gasWithAllowList) - int256(gasWithoutAllowList));
    }

    // Tests gas usage for second deposits to measure warm storage access patterns
    // Compares gas usage after initial storage slots have been initialized
    function test_gasProfile_secondDeposit() public {
        // First deposits
        vm.prank(user);
        wrapperWithAllowList.depositETH{value: 1 ether}(user);
        vm.prank(user);
        wrapperWithoutAllowList.depositETH{value: 1 ether}(user);

        // Second deposits
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithAllowList.depositETH{value: 1 ether}(user);
        uint256 gasWithAllowList = gasBefore - gasleft();

        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutAllowList.depositETH{value: 1 ether}(user);
        uint256 gasWithoutAllowList = gasBefore - gasleft();

        console.log("Gas used for second deposit:");
        console.log("  With allowlist:   ", gasWithAllowList);
        console.log("  Without allowlist:", gasWithoutAllowList);
        console.log("  Difference:       ", int256(gasWithAllowList) - int256(gasWithoutAllowList));
    }

    // Tests gas usage patterns across 5 consecutive deposits
    // Analyzes how gas consumption changes with repeated operations
    function test_gasProfile_multipleDeposits() public {
        uint256[] memory gasWithAllowList = new uint256[](5);
        uint256[] memory gasWithoutAllowList = new uint256[](5);

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user);
            uint256 gasBefore = gasleft();
            wrapperWithAllowList.depositETH{value: 1 ether}(user);
            gasWithAllowList[i] = gasBefore - gasleft();

            vm.prank(user);
            gasBefore = gasleft();
            wrapperWithoutAllowList.depositETH{value: 1 ether}(user);
            gasWithoutAllowList[i] = gasBefore - gasleft();
        }

        console.log("Gas profile for 5 consecutive deposits:");
        for (uint256 i = 0; i < 5; i++) {
            console.log("  Deposit", i + 1, "- With allowlist:", gasWithAllowList[i]);
            console.log("    Without allowlist:", gasWithoutAllowList[i]);
            console.log("    Difference:", int256(gasWithAllowList[i]) - int256(gasWithoutAllowList[i]));
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
            wrapperWithAllowList.depositETH{value: amounts[i]}(user);
            uint256 gasWithAllowList = gasBefore - gasleft();

            vm.prank(user);
            gasBefore = gasleft();
            wrapperWithoutAllowList.depositETH{value: amounts[i]}(user);
            uint256 gasWithoutAllowList = gasBefore - gasleft();

            console.log("  Amount:", amounts[i], "- With allowlist:", gasWithAllowList);
            console.log("    Without allowlist:", gasWithoutAllowList);
            console.log("    Difference:", int256(gasWithAllowList) - int256(gasWithoutAllowList));
        }
    }

    // Tests gas usage of the convenience depositETH() function without receiver parameter
    // Compares gas cost when receiver defaults to msg.sender
    function test_gasProfile_convenienceFunction() public {
        // Test with allowlist enabled
        vm.prank(user);
        uint256 gasBefore = gasleft();
        wrapperWithAllowList.depositETH{value: 1 ether}(); // No receiver parameter
        uint256 gasWithAllowList = gasBefore - gasleft();

        // Test without allowlist
        vm.prank(user);
        gasBefore = gasleft();
        wrapperWithoutAllowList.depositETH{value: 1 ether}(); // No receiver parameter
        uint256 gasWithoutAllowList = gasBefore - gasleft();

        console.log("Gas used for depositETH() convenience function:");
        console.log("  With allowlist:   ", gasWithAllowList);
        console.log("  Without allowlist:", gasWithoutAllowList);
        console.log("  Difference:       ", int256(gasWithAllowList) - int256(gasWithoutAllowList));
    }
}
