// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {MockLazyOracle} from "test/mocks/MockLazyOracle.sol";
import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";

abstract contract SetupWithdrawalQueue is Test {
    WithdrawalQueue public withdrawalQueue;
    StvStETHPool public pool;
    MockLazyOracle public lazyOracle;
    MockDashboard public dashboard;
    MockStETH public steth;

    address public owner;
    address public finalizeRoleHolder;
    address public pauseRoleHolder;
    address public resumeRoleHolder;
    address public userAlice;
    address public userBob;

    uint256 public constant MAX_ACCEPTABLE_WQ_FINALIZATION_TIME = 7 days;
    uint256 public constant MIN_WITHDRAWAL_DELAY_TIME = 1 days;
    uint256 public constant initialDeposit = 1 ether;
    uint256 public constant reserveRatioGapBP = 5_00; // 5%

    uint256 public constant STV_DECIMALS = 27;
    uint256 public constant ASSETS_DECIMALS = 18;

    function setUp() public virtual {
        // Create addresses
        owner = makeAddr("owner");
        finalizeRoleHolder = makeAddr("finalizeRoleHolder");
        pauseRoleHolder = makeAddr("pauseRoleHolder");
        resumeRoleHolder = makeAddr("resumeRoleHolder");
        userAlice = makeAddr("userAlice");
        userBob = makeAddr("userBob");

        // Fund accounts
        vm.deal(owner, 100 ether);
        vm.deal(userAlice, 1000 ether);
        vm.deal(userBob, 1000 ether);

        // Deploy mocks
        dashboard = new MockDashboardFactory().createMockDashboard(owner);
        lazyOracle = new MockLazyOracle();
        steth = dashboard.STETH();

        // Fund dashboard
        dashboard.fund{value: initialDeposit}();

        // Deploy StvStETHPool proxy with temporary implementation
        StvStETHPool tempImpl = new StvStETHPool(address(dashboard), false, reserveRatioGapBP, address(0), address(0));
        OssifiableProxy poolProxy = new OssifiableProxy(address(tempImpl), owner, "");
        pool = StvStETHPool(payable(poolProxy));

        // Deploy WithdrawalQueue with correct pool address
        WithdrawalQueue wqImpl = new WithdrawalQueue(
            address(pool),
            address(dashboard),
            address(dashboard.VAULT_HUB()),
            address(steth),
            address(dashboard.STAKING_VAULT()),
            address(lazyOracle),
            MAX_ACCEPTABLE_WQ_FINALIZATION_TIME,
            MIN_WITHDRAWAL_DELAY_TIME
        );

        OssifiableProxy wqProxy = new OssifiableProxy(address(wqImpl), owner, "");
        withdrawalQueue = WithdrawalQueue(payable(wqProxy));

        // Initialize WithdrawalQueue
        withdrawalQueue.initialize(owner, finalizeRoleHolder);

        // Grant additional roles
        vm.startPrank(owner);
        withdrawalQueue.grantRole(withdrawalQueue.PAUSE_ROLE(), pauseRoleHolder);
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), resumeRoleHolder);

        // Pause first (since initialize resets pause state), then resume
        withdrawalQueue.grantRole(withdrawalQueue.PAUSE_ROLE(), owner);
        withdrawalQueue.pause();
        vm.stopPrank();

        // Resume the queue
        vm.prank(resumeRoleHolder);
        withdrawalQueue.resume();

        // Set oracle timestamp to current time
        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);

        // Deploy Wrapper implementation
        StvStETHPool poolImpl = new StvStETHPool(
            address(dashboard),
            false,
            reserveRatioGapBP,
            address(withdrawalQueue),
            address(0)
        );
        vm.prank(owner);
        poolProxy.proxy__upgradeTo(address(poolImpl));

        // Initialize pool
        pool.initialize(owner, "Test", "stvETH");
    }

    // Helper function to create and finalize a withdrawal request

    function _requestWithdrawalAndFinalize(uint256 _stvAmount) internal returns (uint256 requestId) {
        requestId = pool.requestWithdrawal(_stvAmount);
        _finalizeRequests(1);
    }

    function _finalizeRequests(uint256 _maxRequests) internal {
        lazyOracle.mock__updateLatestReportTimestamp(block.timestamp);
        vm.warp(MIN_WITHDRAWAL_DELAY_TIME + 1 + block.timestamp);
        vm.prank(finalizeRoleHolder);
        withdrawalQueue.finalize(_maxRequests);
    }
}
