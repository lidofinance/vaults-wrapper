// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {WrapperB} from "src/WrapperB.sol";
import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";

abstract contract SetupWrapperB is Test {
    WrapperB public wrapper;
    MockDashboard public dashboard;
    MockStETH public steth;

    address public owner;
    address public userAlice;
    address public userBob;

    uint256 public constant initialDeposit = 1 ether;
    uint256 public constant reserveRatioGapBP = 5_00; // 5%

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
        WrapperB wrapperImpl = new WrapperB(address(dashboard), false, reserveRatioGapBP, address(0));
        ERC1967Proxy wrapperProxy = new ERC1967Proxy(address(wrapperImpl), "");

        wrapper = WrapperB(payable(wrapperProxy));
        wrapper.initialize(owner, address(0), "Test", "stvETH");
    }
}
