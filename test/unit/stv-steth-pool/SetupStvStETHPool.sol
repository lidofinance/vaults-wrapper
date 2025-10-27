// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {MockStakingVault} from "test/mocks/MockStakingVault.sol";

abstract contract SetupStvStETHPool is Test {
    StvStETHPool public pool;
    MockDashboard public dashboard;
    MockStETH public steth;
    MockVaultHub public vaultHub;
    MockStakingVault public stakingVault;

    address public owner;
    address public withdrawalQueue;
    address public userAlice;
    address public userBob;

    uint256 public constant initialDeposit = 1 ether;
    uint256 public constant reserveRatioGapBP = 5_00; // 5%

    function setUp() public virtual {
        owner = makeAddr("owner");
        userAlice = makeAddr("userAlice");
        userBob = makeAddr("userBob");
        withdrawalQueue = makeAddr("withdrawalQueue");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(userAlice, 1000 ether);
        vm.deal(userBob, 1000 ether);

        // Deploy mocks
        dashboard = new MockDashboardFactory().createMockDashboard(owner);
        steth = dashboard.STETH();
        vaultHub = dashboard.VAULT_HUB();
        stakingVault = MockStakingVault(payable(dashboard.stakingVault()));

        // Fund the dashboard with 1 ETH
        dashboard.fund{value: initialDeposit}();

        // Deploy the pool with mock withdrawal queue
        StvStETHPool poolImpl = new StvStETHPool(
            address(steth),
            address(vaultHub),
            address(stakingVault),
            address(dashboard),
            withdrawalQueue,
            address(0), // distributor
            false,
            reserveRatioGapBP
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), "");

        pool = StvStETHPool(payable(poolProxy));
        pool.initialize(owner, "Test", "stvETH");
    }
}
