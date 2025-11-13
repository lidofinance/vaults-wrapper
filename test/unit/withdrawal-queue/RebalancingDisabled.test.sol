// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test} from "forge-std/Test.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {OssifiableProxy} from "src/proxy/OssifiableProxy.sol";

contract RebalancingDisabledTest is Test {
    WithdrawalQueue internal withdrawalQueue;

    address internal owner;
    address internal finalizeRoleHolder;

    function setUp() public {
        owner = makeAddr("owner");
        finalizeRoleHolder = makeAddr("finalizeRoleHolder");

        WithdrawalQueue impl = new WithdrawalQueue(
            makeAddr("pool"),
            makeAddr("dashboard"),
            makeAddr("vaultHub"),
            makeAddr("steth"),
            makeAddr("stakingVault"),
            makeAddr("lazyOracle"),
            1 days,
            false
        );
        OssifiableProxy proxy = new OssifiableProxy(address(impl), owner, "");
        withdrawalQueue = WithdrawalQueue(payable(proxy));
    }

    function test_RequestWithdrawal_RevertWhenRebalancingDisabled() public {
        vm.expectRevert(WithdrawalQueue.RebalancingIsNotSupported.selector);
        withdrawalQueue.requestWithdrawal(address(this), 1, 1);
    }

    function test_RequestWithdrawalBatch_RevertWhenRebalancingDisabled() public {
        uint256[] memory stvAmounts = new uint256[](1);
        stvAmounts[0] = 1;

        uint256[] memory stethShares = new uint256[](1);
        stethShares[0] = 1;

        vm.expectRevert(WithdrawalQueue.RebalancingIsNotSupported.selector);
        withdrawalQueue.requestWithdrawalBatch(address(this), stvAmounts, stethShares);
    }
}
