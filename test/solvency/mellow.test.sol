// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IDepositQueue} from "../../src/interfaces/mellow/IDepositQueue.sol";
import {IOracle} from "../../src/interfaces/mellow/IOracle.sol";
import {IRedeemQueue} from "../../src/interfaces/mellow/IRedeemQueue.sol";
import {ISyncDepositQueue} from "../../src/interfaces/mellow/ISyncDepositQueue.sol";
import {IVault} from "../../src/interfaces/mellow/IVault.sol";

import {StvStrategyPoolHarness} from "test/utils/StvStrategyPoolHarness.sol";

import {StvStETHPool} from "../../src/StvStETHPool.sol";
import {WithdrawalQueue} from "../../src/WithdrawalQueue.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IStrategyCallForwarder} from "../../src/interfaces/IStrategyCallForwarder.sol";
import {MellowStrategy} from "../../src/strategy/MellowStrategy.sol";

import {AllowList} from "../../src/AllowList.sol";
import {TableUtils} from "../utils/format/TableUtils.sol";

import {IWstETH} from "../../src/interfaces/core/IWstETH.sol";

import {RandomLib} from "./libraries/RandomLib.sol";

contract MellowSolvencyTest is StvStrategyPoolHarness {
    using SafeCast for uint256;
    using SafeCast for int256;
    using RandomLib for RandomLib.Storage;

    // Constants

    bytes32 public constant SUBMIT_REPORTS_ROLE = keccak256("oracles.Oracle.SUBMIT_REPORTS_ROLE");
    bytes32 public constant ACCEPT_REPORT_ROLE = keccak256("oracles.Oracle.ACCEPT_REPORT_ROLE");
    bytes32 public constant SET_SECURITY_PARAMS_ROLE = keccak256("oracles.Oracle.SET_SECURITY_PARAMS_ROLE");
    bytes32 public constant SET_HOOK_ROLE = keccak256("modules.ShareModule.SET_HOOK_ROLE");
    bytes32 public constant CREATE_QUEUE_ROLE = keccak256("modules.ShareModule.CREATE_QUEUE_ROLE");
    bytes32 public constant SET_QUEUE_STATUS_ROLE = keccak256("modules.ShareModule.SET_QUEUE_STATUS_ROLE");
    bytes32 public constant SET_QUEUE_LIMIT_ROLE = keccak256("modules.ShareModule.SET_QUEUE_LIMIT_ROLE");
    bytes32 public constant REMOVE_QUEUE_ROLE = keccak256("modules.ShareModule.REMOVE_QUEUE_ROLE");

    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    IVault public constant STRETH = IVault(0x277C6A642564A91ff78b008022D65683cEE5CCC5);
    address public constant PROXY_ADMIN = 0x81698f87C6482bF1ce9bFcfC0F103C4A0Adf0Af0;

    // Variables

    address public syncDepositQueue;
    address public asyncDepositQueue;
    address public asyncRedeemQueue;

    MellowStrategy public mellowStrategy;
    StvStETHPool public pool;
    WithdrawalQueue public withdrawalQueue;
    WrapperContext public ctx;

    RandomLib.Storage private rnd;

    address[] private actors;
    mapping(address actors => bytes32[]) pendingWithdrawalRequests;

    // Setup

    function setUp() public {
        if (!isValidBlock()) return;
        _initializeCore();

        // sync deposit queue deployment in case if its not yet in the prod vault
        if (STRETH.getQueueCount(WSTETH) < 3) {
            address lazyAdmin = getRoleHolder(bytes32(0));
            vm.startPrank(lazyAdmin);
            IAccessControlEnumerable(address(STRETH)).grantRole(CREATE_QUEUE_ROLE, lazyAdmin);
            IAccessControlEnumerable(address(STRETH)).grantRole(SET_QUEUE_LIMIT_ROLE, lazyAdmin);
            STRETH.setQueueLimit(10);
            STRETH.createQueue(2, true, PROXY_ADMIN, WSTETH, abi.encode(0, 30 days));
            vm.stopPrank();
        }

        asyncDepositQueue = STRETH.queueAt(WSTETH, 0);
        asyncRedeemQueue = STRETH.queueAt(WSTETH, 1);
        syncDepositQueue = STRETH.queueAt(WSTETH, 2);

        ctx = _deployStvStETHPool(
            true, 0, 0, StrategyKind.MELLOW, abi.encode(STRETH, syncDepositQueue, asyncDepositQueue, asyncRedeemQueue)
        );
        pool = StvStETHPool(payable(ctx.pool));
        vm.label(address(pool), "WrapperProxy");

        strategy = IStrategy(ctx.strategy);
        mellowStrategy = MellowStrategy(address(strategy));

        withdrawalQueue = pool.WITHDRAWAL_QUEUE();

        vm.startPrank(getRoleHolder(SET_SECURITY_PARAMS_ROLE));
        // inf params for testing only
        STRETH.oracle()
            .setSecurityParams(
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

    // Tests

    function testFixedSetOfRandomizedActions() public {
        if (!isValidBlock()) return;

        for (uint256 i = 0; i < 50; i++) {
            transitionRandomSupply();
        }
        for (uint256 i = 0; i < 50; i++) {
            transitionRandomWithdrawal();
        }

        transitionRandomReport();

        for (uint256 i = 0; i < 50; i++) {
            transitionRandomClaim();
        }

        for (uint256 i = 0; i < 50; i++) {
            transitionRandomBurnWsteth();
        }

        for (uint256 i = 0; i < 50; i++) {
            transitionRandomLidoClaim();
        }
    }

    // Transitions

    function transitionRandomSupply() internal {
        address actor;
        if (actors.length > 0 && rnd.randBool()) {
            actor = actors[rnd.randInt(actors.length - 1)];
        } else {
            actor = rnd.randAddress();
            actors.push(actor);
        }

        uint256 ethValue = Math.min(32 ether, rnd.randAmountD18());
        deal(actor, ethValue);
        vm.startPrank(actor);

        uint256 assets = pool.remainingMintingCapacitySharesOf(actor, ethValue);

        MellowStrategy.MellowSupplyParams memory supplyParams =
            MellowStrategy.MellowSupplyParams(rnd.randBool(), new bytes32[](0));
        (bool success,) = mellowStrategy.previewSupply(
            assets, address(mellowStrategy.getStrategyCallForwarderAddress(actor)), supplyParams
        );

        bytes memory data = abi.encode(supplyParams);
        if (!success) {
            vm.expectRevert(abi.encodeWithSelector(MellowStrategy.SupplyFailed.selector));
        }
        mellowStrategy.supply{value: ethValue}(address(0), assets, data);

        vm.stopPrank();
    }

    function transitionRandomWithdrawal() internal {
        uint256 withShares = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            address actor_ = actors[i];
            uint256 shares_ = mellowStrategy.sharesOf(actor_);
            if (shares_ == 0) continue;
            withShares++;
        }

        if (withShares == 0) return;

        uint256 index = rnd.randInt(withShares - 1);
        address actor;
        for (uint256 i = 0; i < actors.length; i++) {
            address actor_ = actors[i];
            uint256 shares_ = mellowStrategy.sharesOf(actor_);
            if (shares_ == 0) continue;
            if (index == 0) {
                actor = actor_;
                break;
            }
            index--;
        }

        uint256 shares = mellowStrategy.sharesOf(actor);

        shares = rnd.randBool() ? shares : rnd.randInt(1, shares);

        vm.startPrank(actor);

        bytes32 requestId = mellowStrategy.requestExitByShares(shares, new bytes(0));
        pendingWithdrawalRequests[actor].push(requestId);

        vm.stopPrank();
    }

    function transitionRandomClaim() internal {
        uint256[] memory claimableRequests = new uint256[](actors.length);
        uint256 counter = 0;
        for (uint256 i = 0; i < claimableRequests.length; i++) {
            address actor_ = actors[i];
            IRedeemQueue.Request[] memory requests_ =
                mellowStrategy.getRedeemQueueRequests(actor_, 0, type(uint256).max);
            for (uint256 j = 0; j < requests_.length; j++) {
                if (requests_[j].isClaimable) {
                    claimableRequests[i]++;
                }
            }
            if (claimableRequests[i] > 0) {
                counter++;
            }
        }
        if (counter == 0) return;

        uint256 index = rnd.randInt(counter);
        for (uint256 i = 0; i < claimableRequests.length; i++) {
            if (claimableRequests[i] == 0) continue;
            if (index == 0) {
                index = i;
                break;
            }
            index--;
        }

        uint256 numberOfRequestsToClaim = rnd.randInt(1, claimableRequests[index]);
        address actor = actors[index];
        IRedeemQueue.Request[] memory requests = mellowStrategy.getRedeemQueueRequests(actor, 0, type(uint256).max);

        vm.startPrank(actor);
        for (uint256 i = 0; i < requests.length; i++) {
            if (requests[i].isClaimable) {
                bytes32 requestId = bytes32(bytes20(asyncRedeemQueue)) | bytes32(uint256(requests[i].timestamp));
                mellowStrategy.finalizeRequestExit(requestId);
                numberOfRequestsToClaim--;
                if (numberOfRequestsToClaim == 0) break;
            }
        }
        vm.stopPrank();
    }

    function transitionRandomReport() internal {
        int256 deltaD6 = 0;
        if (rnd.randBool()) {
            if (rnd.randBool()) {
                deltaD6 += int256(rnd.randInt(1000));
            } else {
                deltaD6 -= int256(rnd.randInt(1000));
            }
        }

        _submitMellowReport(deltaD6);
        _handleBatches();
    }

    function transitionIncreaseBuffer() internal {
        uint256 percentage = rnd.randInt(10);
        core.increaseBufferedEther(steth.totalSupply() * percentage / 100);
    }

    function transitionSkip() internal {
        skip(1 seconds);
    }

    function transitionRandomBurnWsteth() internal {
        uint256 counter = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            if (mellowStrategy.wstethOf(actors[i]) != 0) counter++;
        }
        if (counter == 0) return;
        uint256 index = rnd.randInt(counter - 1);
        for (uint256 i = 0; i < actors.length; i++) {
            if (mellowStrategy.wstethOf(actors[i]) != 0) {
                if (index == 0) {
                    index = i;
                    break;
                }
                index--;
            }
        }

        address actor = actors[index];
        uint256 wstethUserBalance = mellowStrategy.wstethOf(actor);
        uint256 mintedStethShares = mellowStrategy.mintedStethSharesOf(actor);
        uint256 wstethToBurn = Math.min(mintedStethShares, wstethUserBalance);

        uint256 stETHAmount = steth.getPooledEthByShares(wstethToBurn);
        uint256 sharesAfterUnwrapping = steth.getSharesByPooledEth(stETHAmount);

        uint256 stethSharesToRebalance = 0;
        if (mintedStethShares > sharesAfterUnwrapping) {
            stethSharesToRebalance = mintedStethShares - sharesAfterUnwrapping;
        }

        uint256 stvToWithdraw = mellowStrategy.stvOf(actor);

        vm.startPrank(actor);
        mellowStrategy.burnWsteth(wstethToBurn);
        mellowStrategy.requestWithdrawalFromPool(actor, stvToWithdraw, stethSharesToRebalance);
        vm.stopPrank();
    }

    function transitionRandomLidoClaim() internal {
        uint256 counter = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            if (withdrawalQueue.withdrawalRequestsOf(actors[i]).length != 0) {
                counter++;
            }
        }
        if (counter == 0) return;
        uint256 index = rnd.randInt(counter - 1);
        for (uint256 i = 0; i < actors.length; i++) {
            if (withdrawalQueue.withdrawalRequestsOf(actors[i]).length != 0) {
                if (index == 0) {
                    index = i;
                    break;
                }
                index--;
            }
        }
        address actor = actors[index];
        uint256[] memory requestIds = withdrawalQueue.withdrawalRequestsOf(actor);

        vm.prank(actor);
        withdrawalQueue.claimWithdrawal(actor, requestIds[0]);
    }

    function()[8] transitions = [
        transitionRandomSupply,
        transitionRandomWithdrawal,
        transitionRandomClaim,
        transitionRandomReport,
        transitionIncreaseBuffer,
        transitionSkip,
        transitionRandomBurnWsteth,
        transitionRandomLidoClaim
    ];

    // Helpers

    function getRoleHolder(bytes32 role) internal view returns (address) {
        return IAccessControlEnumerable(address(STRETH)).getRoleMember(role, 0);
    }

    function isValidBlock() internal view returns (bool) {
        return block.chainid == 1 && block.number >= 24307000;
    }

    function _submitMellowReport(int256 deltaD6) internal {
        IOracle oracle = STRETH.oracle();
        IOracle.DetailedReport memory report = oracle.getReport(WSTETH);
        uint256 minTimestamp = report.timestamp + 1 seconds;
        if (block.timestamp < minTimestamp) {
            skip(minTimestamp - block.timestamp);
        }

        uint256 newPriceD18 = report.priceD18;
        if (deltaD6 < 0) {
            deltaD6 = -deltaD6;
            // price increment
            newPriceD18 += newPriceD18 * deltaD6.toUint256() / 1e6;
        } else {
            // price decrement
            newPriceD18 -= newPriceD18 * deltaD6.toUint256() / 1e6;
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

    function _finalizeWithdrawalQueue(uint256 maxRequests, uint256 vaultProfit) public {
        vm.deal(address(ctx.vault), 10 ether);
        vm.deal(address(pool.VAULT()), 1 ether);

        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(address(pool.VAULT()), pool.totalAssets(), 0, pool.DASHBOARD().liabilityShares(), 0);

        if (vaultProfit != 0) {
            vm.startPrank(NODE_OPERATOR);
            pool.DASHBOARD().fund{value: 10 ether}();
            vm.stopPrank();
        }

        vm.startPrank(NODE_OPERATOR);
        uint256 finalizedRequests = pool.WITHDRAWAL_QUEUE().finalize(maxRequests, address(0));
        vm.stopPrank();

        assertEq(finalizedRequests, maxRequests, "Invalid finalized requests");
    }
}
