// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";
import {StvPoolHarness} from "test/utils/StvPoolHarness.sol";

/**
 * @title DashboardTest
 * @notice Integration tests for Dashboard functionality
 */
contract DashboardTest is StvPoolHarness {
    WrapperContext ctx;

    // Deployment parameters
    uint256 nodeOperatorFeeBP = 200; // 2%
    uint256 confirmExpiry = CONFIRM_EXPIRY;
    address feeRecipient = NODE_OPERATOR;

    // Role holders
    address timelockProposer = NODE_OPERATOR;
    address timelockExecutor = NODE_OPERATOR;
    address nodeOperatorManager = NODE_OPERATOR;

    // Timelock
    bytes32 salt = keccak256("timelock.salt.for.test");

    function setUp() public {
        _initializeCore();
        ctx = _deployStvPool({enableAllowlist: false, nodeOperatorFeeBP: nodeOperatorFeeBP});
    }

    // Helpers for timelock operations

    function _timelockSchedule(address target, bytes memory data) internal {
        uint256 delay = ctx.timelock.getMinDelay();

        vm.prank(timelockProposer);
        ctx.timelock.schedule({target: target, value: 0, data: data, predecessor: bytes32(0), salt: salt, delay: delay});
    }

    function _timelockWarp() internal {
        vm.warp(block.timestamp + ctx.timelock.getMinDelay());
    }

    function _timelockExecute(address target, bytes memory data) internal {
        vm.prank(timelockExecutor);
        ctx.timelock.execute({target: target, value: 0, payload: data, predecessor: bytes32(0), salt: salt});
    }

    function _timelockScheduleAndExecute(address target, bytes memory data) internal {
        _timelockSchedule(target, data);
        _timelockWarp();
        _timelockExecute(target, data);
    }

    // Timelock tests

    function test_Dashboard_RolesAreSetCorrectly() public view {
        // Check that the timelock is the admin of the dashboard
        bytes32 adminRole = ctx.dashboard.DEFAULT_ADMIN_ROLE();
        assertTrue(ctx.dashboard.hasRole(adminRole, address(ctx.timelock)));
        assertEq(ctx.dashboard.getRoleMember(adminRole, 0), address(ctx.timelock));
        assertEq(ctx.dashboard.getRoleMemberCount(adminRole), 1);
        assertEq(ctx.dashboard.getRoleAdmin(adminRole), adminRole);

        // Check that the timelock has proposer and executor roles
        bytes32 proposerRole = ctx.timelock.PROPOSER_ROLE();
        bytes32 executorRole = ctx.timelock.EXECUTOR_ROLE();

        assertTrue(ctx.timelock.hasRole(proposerRole, timelockProposer));
        assertTrue(ctx.timelock.hasRole(executorRole, timelockExecutor));
    }

    // TODO: grant NODE_OPERATOR_MANAGER_ROLE to Timelock
    // Methods required both DEFAULT_ADMIN_ROLE and NODE_OPERATOR_MANAGER_ROLE access:
    // - setFeeRate
    // - setConfirmExpiry
    // - correctSettledGrowth

    function test_Dashboard_CanSetFeeRate() public {
        assertEq(ctx.dashboard.feeRate(), nodeOperatorFeeBP);
        uint256 expectedOperatorFeeBP = nodeOperatorFeeBP + 100; // + 1%

        // 1. Set Fee Rate by Timelock
        _timelockSchedule(address(ctx.dashboard), abi.encodeWithSignature("setFeeRate(uint256)", expectedOperatorFeeBP));
        _timelockWarp();
        reportVaultValueChangeNoFees(ctx, 0); // setFeeRate() requires oracle report
        _timelockExecute(address(ctx.dashboard), abi.encodeWithSignature("setFeeRate(uint256)", expectedOperatorFeeBP));

        assertEq(ctx.dashboard.feeRate(), nodeOperatorFeeBP); // shouldn't change

        // 2. Set Fee Rate by Node Operator Manager
        vm.prank(nodeOperatorManager);
        bool updated = ctx.dashboard.setFeeRate(expectedOperatorFeeBP);
        assertTrue(updated);
        assertEq(uint256(ctx.dashboard.feeRate()), expectedOperatorFeeBP);
    }

    function test_Dashboard_CanSetConfirmExpiry() public {
        assertEq(ctx.dashboard.getConfirmExpiry(), confirmExpiry);
        uint256 newConfirmExpiry = confirmExpiry + 1 hours;

        // 1. Set Confirm Expiry by Timelock
        _timelockScheduleAndExecute(
            address(ctx.dashboard), abi.encodeWithSignature("setConfirmExpiry(uint256)", newConfirmExpiry)
        );
        assertEq(ctx.dashboard.getConfirmExpiry(), confirmExpiry); // shouldn't change

        // 2. Set Confirm Expiry by Node Operator Manager
        vm.prank(nodeOperatorManager);
        bool updated = ctx.dashboard.setConfirmExpiry(newConfirmExpiry);
        assertTrue(updated);
        assertEq(uint256(ctx.dashboard.getConfirmExpiry()), newConfirmExpiry);
    }

    function test_Dashboard_CanCorrectSettledGrowth() public {
        int256 initialSettledGrowth = ctx.dashboard.settledGrowth();
        int256 newSettledGrowth = initialSettledGrowth + 1;

        // 1. Correct Settled Growth by Timelock
        _timelockScheduleAndExecute(
            address(ctx.dashboard),
            abi.encodeWithSignature("correctSettledGrowth(int256,int256)", newSettledGrowth, initialSettledGrowth)
        );
        assertEq(ctx.dashboard.settledGrowth(), initialSettledGrowth); // shouldn't change

        // 2. Correct Settled Growth by Node Operator Manager
        vm.prank(nodeOperatorManager);
        bool updated = ctx.dashboard.correctSettledGrowth(newSettledGrowth, initialSettledGrowth);
        assertTrue(updated);
        assertEq(ctx.dashboard.settledGrowth(), newSettledGrowth);
    }

    // Methods required a DEFAULT_ADMIN_ROLE access:
    // - disburseAbnormallyHighFee
    // - recoverERC20
    // - collectERC20FromVault (can also be called from COLLECT_VAULT_ERC20_ROLE)

    function test_Dashboard_CanDisburseAbnormallyHighFee() public {
        _timelockScheduleAndExecute(address(ctx.dashboard), abi.encodeWithSignature("disburseAbnormallyHighFee()"));
    }

    function test_Dashboard_CanRecoverERC20() public {
        address receiver = makeAddr("receiver");

        // ERC20
        ERC20 tokenERC20 = new ERC20();
        uint256 amountERC20 = 1 * 10 ** 18;

        tokenERC20.mint(address(ctx.dashboard), amountERC20);

        _timelockScheduleAndExecute(
            address(ctx.dashboard),
            abi.encodeWithSignature("recoverERC20(address,address,uint256)", address(tokenERC20), receiver, amountERC20)
        );
        vm.assertEq(tokenERC20.balanceOf(receiver), amountERC20);

        // ETH
        address tokenETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        uint256 amountETH = 1 ether;

        uint256 receiverInitialBalance = receiver.balance;
        vm.deal(address(ctx.dashboard), amountETH);

        _timelockScheduleAndExecute(
            address(ctx.dashboard),
            abi.encodeWithSignature("recoverERC20(address,address,uint256)", tokenETH, receiver, amountETH)
        );
        vm.assertEq(receiver.balance, receiverInitialBalance + amountETH);
    }

    function test_Dashboard_CanCollectERC20FromVault() public {
        ERC20 token = new ERC20();
        address receiver = makeAddr("receiver");
        uint256 amount = 1 * 10 ** 18;

        token.mint(address(ctx.vault), amount);

        _timelockScheduleAndExecute(
            address(ctx.dashboard),
            abi.encodeWithSignature("collectERC20FromVault(address,address,uint256)", address(token), receiver, amount)
        );
        vm.assertEq(token.balanceOf(receiver), amount);
    }

    // Methods required a single-role access:
    // - addFeeExemption. Requires NODE_OPERATOR_FEE_EXEMPT_ROLE
    // - setFeeRecipient. Requires NODE_OPERATOR_MANAGER_ROLE

    function test_Dashboard_CanAddFeeExemption() public {
        // The role is not granted initially
        bytes32 feeExemptionRole = ctx.dashboard.NODE_OPERATOR_FEE_EXEMPT_ROLE();
        assertFalse(ctx.dashboard.hasRole(feeExemptionRole, address(this)));

        // Grant the role to this contract
        vm.prank(nodeOperatorManager);
        ctx.dashboard.grantRole(feeExemptionRole, address(this));
        assertTrue(ctx.dashboard.hasRole(feeExemptionRole, address(this)));

        // Add fee exemptions
        ctx.dashboard.addFeeExemption(1 wei);
    }

    function test_Dashboard_CanSetFeeRecipient() public {
        assertEq(ctx.dashboard.feeRecipient(), feeRecipient);
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.prank(nodeOperatorManager);
        ctx.dashboard.setFeeRecipient(newFeeRecipient);
    }
}

contract ERC20 is ERC20Upgradeable {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
