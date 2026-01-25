// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";

import "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "src/interfaces/mellow/IDepositQueue.sol";
import "src/interfaces/mellow/IRedeemQueue.sol";
import "src/interfaces/mellow/ISyncDepositQueue.sol";
import "src/interfaces/mellow/IVault.sol";

import {StvStrategyPoolHarness} from "test/utils/StvStrategyPoolHarness.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "src/interfaces/IStrategyCallForwarder.sol";
import {MellowStrategy} from "src/strategy/MellowStrategy.sol";

import {TableUtils} from "../utils/format/TableUtils.sol";
import {AllowList} from "src/AllowList.sol";

import "src/interfaces/core/IWstETH.sol";

contract MellowTest is StvStrategyPoolHarness {
    using SafeCast for uint256;
    using TableUtils for TableUtils.Context;

    address public constant ADMIN = address(0x1337);
    address public constant SOLVER = address(0x1338);

    MellowStrategy public mellowStrategy;

    StvStETHPool public pool;
    WithdrawalQueue public withdrawalQueue;

    bytes32 public constant SUBMIT_REPORTS_ROLE = keccak256("oracles.Oracle.SUBMIT_REPORTS_ROLE");
    bytes32 public constant ACCEPT_REPORT_ROLE = keccak256("oracles.Oracle.ACCEPT_REPORT_ROLE");
    bytes32 public constant SET_SECURITY_PARAMS_ROLE = keccak256("oracles.Oracle.SET_SECURITY_PARAMS_ROLE");
    bytes32 public constant SET_HOOK_ROLE = keccak256("modules.ShareModule.SET_HOOK_ROLE");
    bytes32 public constant CREATE_QUEUE_ROLE = keccak256("modules.ShareModule.CREATE_QUEUE_ROLE");
    bytes32 public constant SET_QUEUE_STATUS_ROLE = keccak256("modules.ShareModule.SET_QUEUE_STATUS_ROLE");
    bytes32 public constant SET_QUEUE_LIMIT_ROLE = keccak256("modules.ShareModule.SET_QUEUE_LIMIT_ROLE");
    bytes32 public constant REMOVE_QUEUE_ROLE = keccak256("modules.ShareModule.REMOVE_QUEUE_ROLE");

    IVault public immutable strETH = IVault(0x277C6A642564A91ff78b008022D65683cEE5CCC5);
    address public constant proxyAdmin = 0x81698f87C6482bF1ce9bFcfC0F103C4A0Adf0Af0;
    address public syncDepositQueue;
    address public asyncDepositQueue;
    address public asyncRedeemQueue;

    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    TableUtils.User[] public logUsers;

    WrapperContext public ctx;

    address public user1StrategyCallForwarder;
    address public user2StrategyCallForwarder;

    function getRoleHolder(bytes32 role) internal view returns (address) {
        return IAccessControlEnumerable(address(strETH)).getRoleMember(role, 0);
    }

    function isValidBlock() internal view returns (bool) {
        return block.chainid == 1 && block.number >= 24307000;
    }

    function setUp() public {
        if (!isValidBlock()) return;
        _initializeCore();

        vm.deal(ADMIN, 100_000 ether);
        vm.deal(SOLVER, 100_000 ether);

        // sync deposit queue deployment
        {
            address lazyAdmin = getRoleHolder(bytes32(0));
            vm.startPrank(lazyAdmin);
            IAccessControl(address(strETH)).grantRole(CREATE_QUEUE_ROLE, lazyAdmin);
            IAccessControl(address(strETH)).grantRole(SET_QUEUE_LIMIT_ROLE, lazyAdmin);
            strETH.setQueueLimit(10);
            strETH.createQueue(2, true, proxyAdmin, WSTETH, abi.encode(0, 24 hours));
            vm.stopPrank();
        }

        asyncDepositQueue = strETH.queueAt(WSTETH, 0);
        asyncRedeemQueue = strETH.queueAt(WSTETH, 1);
        syncDepositQueue = strETH.queueAt(WSTETH, 2);

        ctx = _deployStvStETHPool(
            true, 0, 0, StrategyKind.MELLOW, abi.encode(strETH, syncDepositQueue, asyncDepositQueue, asyncRedeemQueue)
        );
        pool = StvStETHPool(payable(ctx.pool));
        vm.label(address(pool), "WrapperProxy");

        strategy = IStrategy(ctx.strategy);
        mellowStrategy = MellowStrategy(address(strategy));

        user1StrategyCallForwarder = address(mellowStrategy.getStrategyCallForwarderAddress(USER1));
        vm.label(user1StrategyCallForwarder, "User1StrategyCallForwarder");

        user2StrategyCallForwarder = address(mellowStrategy.getStrategyCallForwarderAddress(USER2));
        vm.label(user2StrategyCallForwarder, "User2StrategyCallForwarder");

        withdrawalQueue = pool.WITHDRAWAL_QUEUE();

        address securityParamsSetter = getRoleHolder(SET_SECURITY_PARAMS_ROLE);

        vm.startPrank(securityParamsSetter);
        // inf params for testing only
        strETH.oracle().setSecurityParams(
            IOracle.SecurityParams({
                maxAbsoluteDeviation: type(uint224).max,
                suspiciousAbsoluteDeviation: type(uint224).max,
                maxRelativeDeviationD18: 1 ether,
                suspiciousRelativeDeviationD18: 1 ether,
                timeout: 1,
                depositInterval: 1,
                redeemInterval: 1
            })
        );
        vm.stopPrank();
    }

    function test_revert_if_user_is_not_allowlisted() public {
        if (!isValidBlock()) return;
        uint256 depositAmount = 1 ether;
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(AllowList.NotAllowListed.selector, USER1));
        pool.depositETH{value: depositAmount}(USER1, address(0));
    }

    function test_scenario_1() public {
        if (!isValidBlock()) return;
        uint256 stethIncrease = 1;
        uint256 vaultProfit = 0;
        uint256 depositAmount = 1 ether;

        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(user1StrategyCallForwarder, "user1_forwarder"));
        logUsers.push(TableUtils.User(address(pool), "pool"));
        logUsers.push(TableUtils.User(address(pool.WITHDRAWAL_QUEUE()), "wq"));
        logUsers.push(TableUtils.User(address(strETH), "strETH"));
        if (syncDepositQueue != address(0)) {
            logUsers.push(TableUtils.User(address(syncDepositQueue), "syncDepositQueue"));
        }
        logUsers.push(TableUtils.User(address(asyncDepositQueue), "asyncDepositQueue"));
        logUsers.push(TableUtils.User(address(asyncRedeemQueue), "asyncRedeemQueue"));

        core.increaseBufferedEther(steth.totalSupply() * stethIncrease / 100);

        uint256 wstethToMint = pool.remainingMintingCapacitySharesOf(USER1, depositAmount);

        vm.prank(USER1);
        mellowStrategy.supply{value: depositAmount}(
            address(0),
            wstethToMint,
            abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}))
        );

        uint256 mellowShares = strETH.shareManager().sharesOf(user1StrategyCallForwarder);
        assertEq(mellowShares, 0);

        skip(1 seconds);
        core.increaseBufferedEther(steth.totalSupply() * 1 / 100);
        _submitMellowReport(0);
        _handleBatches();

        mellowShares = strETH.shareManager().sharesOf(user1StrategyCallForwarder);
        assertNotEq(mellowShares, 0);

        uint256 userMintedStethSharesAfterDeposit = mellowStrategy.mintedStethSharesOf(USER1);
        assertEq(mellowStrategy.sharesOf(USER1), mellowShares);
        assertEq(mellowStrategy.activeSharesOf(USER1), 0);
        assertEq(mellowStrategy.claimableSharesOf(USER1), mellowShares);

        vm.prank(USER1);
        mellowStrategy.claimShares();

        assertEq(mellowStrategy.sharesOf(USER1), mellowShares);
        assertEq(mellowStrategy.activeSharesOf(USER1), mellowShares);
        assertEq(mellowStrategy.claimableSharesOf(USER1), 0);

        vm.startPrank(USER1);
        bytes32 requestId = mellowStrategy.requestExitByShares(mellowStrategy.sharesOf(USER1), new bytes(0));
        vm.stopPrank();

        assertEq(mellowStrategy.sharesOf(USER1), 0);
        assertEq(mellowStrategy.activeSharesOf(USER1), 0);
        assertEq(mellowStrategy.claimableSharesOf(USER1), 0);

        skip(1 seconds);

        _submitMellowReport(0);
        _handleBatches();

        mellowStrategy.getRedeemQueueRequests(USER1, 0, 10);

        vm.startPrank(USER1);
        mellowStrategy.finalizeRequestExit(requestId);
        vm.stopPrank();

        // simulate the unwrapping of wstETH to stETH with rounding issue
        uint256 wstethUserBalance = mellowStrategy.wstethOf(USER1);
        assertGt(
            userMintedStethSharesAfterDeposit,
            wstethUserBalance,
            "user minted steth shares should be greater than wsteth balance"
        );

        uint256 mintedStethShares = mellowStrategy.mintedStethSharesOf(USER1);
        uint256 wstethToBurn = Math.min(mintedStethShares, wstethUserBalance);

        uint256 stETHAmount = steth.getPooledEthByShares(wstethToBurn);
        uint256 sharesAfterUnwrapping = steth.getSharesByPooledEth(stETHAmount);

        uint256 stethSharesToRebalance = 0;
        if (mintedStethShares > sharesAfterUnwrapping) {
            stethSharesToRebalance = mintedStethShares - sharesAfterUnwrapping;
        }

        uint256 stvToWithdraw = mellowStrategy.stvOf(USER1);

        vm.startPrank(USER1);
        mellowStrategy.burnWsteth(wstethToBurn);
        mellowStrategy.requestWithdrawalFromPool(USER1, stvToWithdraw, stethSharesToRebalance);
        vm.stopPrank();

        vm.deal(address(ctx.vault), 10 ether);
        _finalizeWQ(1, vaultProfit);

        uint256 userBalanceBeforeClaim = USER1.balance;
        uint256[] memory wqRequestIds = withdrawalQueue.withdrawalRequestsOf(USER1);

        vm.prank(USER1);
        withdrawalQueue.claimWithdrawal(USER1, wqRequestIds[0]);

        uint256 ethClaimed = USER1.balance - userBalanceBeforeClaim;
        console.log("ETH Claimed:", ethClaimed);
    }

    function _submitMellowReport(int256 deltaD6) internal {
        IOracle oracle = strETH.oracle();
        IOracle.DetailedReport memory report = oracle.getReport(WSTETH);
        uint256 minTimestamp = report.timestamp + 1 seconds;
        if (block.timestamp < minTimestamp) {
            skip(minTimestamp - block.timestamp);
        }

        uint256 newPriceD18 = report.priceD18;
        if (deltaD6 < 0) {
            deltaD6 = -deltaD6;
            // price increment
            newPriceD18 += newPriceD18 * uint256(deltaD6) / 1e6;
        } else {
            // price decrement
            newPriceD18 -= newPriceD18 * uint256(deltaD6) / 1e6;
        }

        (bool isValid, bool isSuspicious) = oracle.validatePrice(newPriceD18, WSTETH);
        if (!isValid || isSuspicious) {
            revert("Too high deviation");
        }

        address oracleSubmitter = getRoleHolder(SUBMIT_REPORTS_ROLE);

        vm.startPrank(oracleSubmitter);
        IOracle.Report[] memory reports = new IOracle.Report[](1);
        reports[0].asset = WSTETH;
        reports[0].priceD18 = newPriceD18.toUint224();
        oracle.submitReports(reports);
        vm.stopPrank();
    }

    function _handleBatches() public {
        IRedeemQueue(asyncRedeemQueue).handleBatches(type(uint256).max);
    }

    function _finalizeWQ(uint256 _maxRequest, uint256 vaultProfit) public {
        vm.deal(address(pool.VAULT()), 1 ether);

        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(pool.VAULT()), pool.totalAssets(), 0, pool.DASHBOARD().liabilityShares(), 0);

        if (vaultProfit != 0) {
            vm.startPrank(NODE_OPERATOR);
            pool.DASHBOARD().fund{value: 10 ether}();
            vm.stopPrank();
        }

        vm.startPrank(NODE_OPERATOR);
        uint256 finalizedRequests = pool.WITHDRAWAL_QUEUE().finalize(_maxRequest, address(0));
        vm.stopPrank();

        assertEq(finalizedRequests, _maxRequest, "Invalid finalized requests");
    }
}
