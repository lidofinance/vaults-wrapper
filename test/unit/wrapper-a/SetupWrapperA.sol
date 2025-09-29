// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {WrapperA} from "src/WrapperA.sol";
import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";

abstract contract SetupWrapperA is Test {
    WrapperA public wrapper;
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

        // Deploy the wrapper
        WrapperA wrapperImpl = new WrapperA(address(dashboard), false, address(0));
        ERC1967Proxy wrapperProxy = new ERC1967Proxy(address(wrapperImpl), "");

        wrapper = WrapperA(payable(wrapperProxy));
        wrapper.initialize(owner, address(0), "Test", "stvETH");
    }
}
