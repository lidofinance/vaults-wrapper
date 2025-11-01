// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {StvPool} from "src/StvPool.sol";
import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";

abstract contract SetupStvPool is Test {
    StvPool public pool;
    MockDashboard public dashboard;
    MockStETH public steth;

    address public owner;
    address public userAlice;
    address public userBob;

    uint256 public constant initialDeposit = 1 ether;

    function setUp() public virtual {
        owner = makeAddr("owner");
        userAlice = makeAddr("userAlice");
        userBob = makeAddr("userBob");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(userAlice, 1000 ether);
        vm.deal(userBob, 1000 ether);

        // Deploy mocks
        dashboard = new MockDashboardFactory().createMockDashboard(owner);
        steth = dashboard.STETH();

        // Fund the dashboard with 1 ETH
        dashboard.fund{value: initialDeposit}();

        // Deploy the pool
        StvPool poolImpl = new StvPool({
            _dashboard: address(dashboard),
            _allowListEnabled: false,
            _withdrawalQueue: address(0),
            _distributor: address(0)
        });
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), "");

        pool = StvPool(payable(poolProxy));
        pool.initialize(owner, "Test", "stvETH");
    }
}
