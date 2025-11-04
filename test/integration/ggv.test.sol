// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {console} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";

import {StvStrategyPoolHarness} from "test/utils/StvStrategyPoolHarness.sol";

import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";

import {TableUtils} from "../utils/format/TableUtils.sol";
import {GGVVaultMock} from "src/mock/ggv/GGVVaultMock.sol";
import {GGVMockTeller} from "src/mock/ggv/GGVMockTeller.sol";
import {GGVQueueMock} from "src/mock/ggv/GGVQueueMock.sol";
import {AllowList} from "src/AllowList.sol";

interface IAuthority {
    function setUserRole(address user, uint8 role, bool enabled) external;
    function setRoleCapability(uint8 role, address code, bytes4 sig, bool enabled) external;
    function owner() external view returns (address);
    function canCall(address caller, address code, bytes4 sig) external view returns (bool);
    function doesRoleHaveCapability(uint8 role, address code, bytes4 sig) external view returns (bool);
    function doesUserHaveRole(address user, uint8 role) external view returns (bool);
    function getUserRoles(address user) external view returns (bytes32);
    function getRolesWithCapability(address code, bytes4 sig) external view returns (bytes32);
}

interface IAccountant {
    function setRateProviderData(ERC20 asset, bool isPeggedToBase, address rateProvider) external;
}

contract GGVTest is StvStrategyPoolHarness {
    using TableUtils for TableUtils.Context;

    TableUtils.Context private _log;

    address public constant ADMIN = address(0x1337);
    address public constant SOLVER = address(0x1338);

    uint8 public constant OWNER_ROLE = 8;
    uint8 public constant MULTISIG_ROLE = 9;
    uint8 public constant STRATEGIST_MULTISIG_ROLE = 10;
    uint8 public constant SOLVER_ORIGIN_ROLE = 33;

    // Use local mocks for teller/on-chain queue/solver in integration tests
    //    ITellerWithMultiAssetSupport public teller;
    //    IBoringOnChainQueue public boringOnChainQueue;
    //    IBoringSolver public solver;

    ITellerWithMultiAssetSupport public teller;
    IBoringOnChainQueue public boringOnChainQueue;
    IBoringSolver public solver;

    StvStETHPool public pool;
    WithdrawalQueue public withdrawalQueue;

    GGVStrategy public ggvStrategy;
    GGVVaultMock public boringVault;

    address WSTETH = address(0); // unused with mocks

    TableUtils.User[] public logUsers;

    WrapperContext public ctx;

    address public user1StrategyCallForwarder;
    address public user2StrategyCallForwarder;

    function setUp() public {
        _initializeCore();

        vm.deal(ADMIN, 100_000 ether);
        vm.deal(SOLVER, 100_000 ether);

        boringVault = new GGVVaultMock(ADMIN, address(steth), address(wsteth));
        teller = GGVMockTeller(address(boringVault.TELLER()));
        boringOnChainQueue = GGVQueueMock(address(boringVault.BORING_QUEUE()));

        ctx = _deployStvStETHPool(true, 0, 0, address(teller), address(boringOnChainQueue));
        pool = StvStETHPool(payable(ctx.pool));
        vm.label(address(pool), "WrapperProxy");

        strategy = IStrategy(ctx.strategy);
        ggvStrategy = GGVStrategy(address(strategy));

        user1StrategyCallForwarder = ggvStrategy.getStrategyCallForwarderAddress(USER1);
        vm.label(user1StrategyCallForwarder, "User1StrategyCallForwarder");

        user2StrategyCallForwarder = ggvStrategy.getStrategyCallForwarderAddress(USER2);
        vm.label(user2StrategyCallForwarder, "User2StrategyCallForwarder");

        _log.init(
            address(pool),
            address(boringVault),
            address(steth),
            address(wsteth),
            address(boringOnChainQueue)
        );

        vm.startPrank(ADMIN);
        steth.submit{value: 10 ether}(ADMIN);
        steth.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(SOLVER);
        uint256 solverSteth = steth.submit{value: 1 ether}(SOLVER);
        steth.approve(address(wsteth), type(uint256).max);
        uint256 solverWsteth = wsteth.wrap(solverSteth);
        wsteth.transfer(address(boringVault), solverWsteth);
        vm.stopPrank();

        withdrawalQueue = pool.WITHDRAWAL_QUEUE();

        // Skip external GGV mainnet setup when using local mocks
        // _setupGGV();
    }

    function _setupGGV() public {
        address tellerAuthority = teller.authority();

        IAuthority authority = IAuthority(tellerAuthority);
        address authorityOwner = authority.owner();

        IAccountant accountant = IAccountant(teller.accountant());

        vm.startPrank(authorityOwner);
        authority.setUserRole(address(this), OWNER_ROLE, true);
        authority.setUserRole(address(this), STRATEGIST_MULTISIG_ROLE, true);
        authority.setUserRole(address(this), MULTISIG_ROLE, true);
        authority.setUserRole(address(this), SOLVER_ORIGIN_ROLE, true);
        vm.stopPrank();

        teller.updateAssetData(ERC20(address(core.steth())), true, true, 0);
        accountant.setRateProviderData(ERC20(address(core.steth())), true, address(0));
        boringOnChainQueue.updateWithdrawAsset(address(core.steth()), 0, 604800, 1, 9, 0);

        console.log("setup GGV finished\n");
    }

    function test_rebase_scenario() public {
        uint256 stethIncrease = 0;
        uint256 vaultIncrease = 0;
        uint256 ggvDiscount = 1;

        uint256 depositAmount = 1 ether;
        uint256 vaultProfit = depositAmount * vaultIncrease / 100; // 0.05 ether profit

        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(user1StrategyCallForwarder, "user1_call_forwarder"));
        logUsers.push(TableUtils.User(address(pool), "pool"));
        logUsers.push(TableUtils.User(address(pool.WITHDRAWAL_QUEUE()), "wq"));
        logUsers.push(TableUtils.User(address(boringVault), "boringVault"));
        logUsers.push(TableUtils.User(address(boringOnChainQueue), "boringVaultQueue"));

        // Apply 1% increase to core (stETH share ratio)
        core.increaseBufferedEther(steth.totalSupply() * stethIncrease / 100);
        console.log("INITIAL share rate %s", steth.getPooledEthByShares(1e18));

        // _log.printUsers("[SCENARIO] Initial State", logUsers, ggvDiscount);

        // Check that user is not allowed to deposit directly
        vm.prank(USER1);
        vm.expectRevert(abi.encodeWithSelector(AllowList.NotAllowListed.selector, USER1));
        pool.depositETH{value: depositAmount}(USER1, address(0));

        // 1. Initial Deposit
        vm.prank(USER1);
        ggvStrategy.supply{value: depositAmount}(address(0), abi.encode(GGVStrategy.GGVParams(0, 0, 0)));

        // _log.printUsers("[SCENARIO] After Deposit (1 ETH)", logUsers, ggvDiscount);

        // 2. Simulate Rebases
        console.log("\n[SCENARIO] Simulating Rebases (Vault +5%, stETH +4%)");

        // a) Vault Rebase (simulated via mock report)
        // uint256 currentLiabilityShares = pool.DASHBOARD().liabilityShares();
        // uint256 currentTotalAssets = pool.totalAssets();

        // core.applyVaultReport(address(ctx.vault), currentTotalAssets + vaultProfit, 0, currentLiabilityShares, 0, false);

        // _log.printUsers("[SCENARIO] After report (increase vault balance)", logUsers, ggvDiscount);

//         3. Request withdrawal (full amount, based on appreciated value)
        uint256 totalGgvShares = boringVault.balanceOf(user1StrategyCallForwarder);
        uint256 withdrawalStethAmount =
            boringOnChainQueue.previewAssetsOut(address(steth), uint128(totalGgvShares), uint16(ggvDiscount));

        console.log("\n[SCENARIO] Requesting withdrawal based on new appreciated assets:", withdrawalStethAmount);

        GGVStrategy.GGVParams memory params = GGVStrategy.GGVParams({
            discount: uint16(ggvDiscount),
            minimumMint: 0,
            secondsToDeadline: type(uint24).max
        });

        vm.prank(USER1);
        bytes32 requestId = ggvStrategy.requestExitByStETH(withdrawalStethAmount, abi.encode(params));
        assertNotEq(requestId, 0);

        // Apply 1% increase to core (stETH share ratio)
        core.increaseBufferedEther(steth.totalSupply() * 1 / 100);
        uint256 shareRate3 = steth.getPooledEthByShares(1e18);

        console.log("\n[SCENARIO] apply new stETH rebase shareRate after request, before ggv solve:", shareRate3);

        _log.printUsers("[SCENARIO] After Request Withdrawal", logUsers, ggvDiscount);

        // 4. Solve GGV requests (Simulate GGV Solver)
        console.log("\n[SCENARIO] Step 4. Solve GGV requests");

        IBoringOnChainQueue.OnChainWithdraw memory req =
            GGVQueueMock(address(boringOnChainQueue)).mockGetRequestById(requestId);
        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = req;

        vm.warp(block.timestamp + req.secondsToMaturity + 1);
        boringOnChainQueue.solveOnChainWithdraws(requests, new bytes(0), address(0));

        _log.printUsers("After GGV Solver", logUsers, ggvDiscount);

        // 5. User Finalizes Withdrawal (Wrapper side)
        console.log("\n[SCENARIO] Step 5. Finalize Wrapper withdrawal");

        uint256 _stethSharesToBurn = ggvStrategy.proxyStethSharesOf(USER1);
        uint256 _stethSharesToRebalance = ggvStrategy.proxyStethSharesToRebalance(USER1);
        uint256 _stvToWithdraw = ggvStrategy.proxyUnlockedStvOf(USER1, _stethSharesToRebalance + _stethSharesToBurn);

        vm.startPrank(USER1);
        ggvStrategy.requestWithdrawal(_stvToWithdraw, _stethSharesToBurn, _stethSharesToRebalance, USER1);
        vm.stopPrank();

        _log.printUsers("After User Finalizes Wrapper", logUsers, ggvDiscount);

        // 6. Node Operator Finalizes WQ (Node Operator side)
        console.log("\n[SCENARIO] Step 6. Finalize WQ (Node Operator)");

        vm.deal(address(ctx.vault), 10 ether);
        _finalizeWQ(1, vaultProfit);

        _log.printUsers("After WQ Finalized", logUsers, ggvDiscount);

        // 7. User Claims ETH
        console.log("\n[SCENARIO] Step 7. Claim final ETH");
        uint256 userBalanceBeforeClaim = USER1.balance;

        uint256[] memory wqRequestIds = withdrawalQueue.withdrawalRequestsOf(USER1);

        //  console.log("requestIds length", wqRequestIds[0]);

        vm.prank(USER1);
        withdrawalQueue.claimWithdrawal(USER1, wqRequestIds[0]);

        uint256 ethClaimed = USER1.balance - userBalanceBeforeClaim;
        console.log("ETH Claimed:", ethClaimed);

        _log.printUsers("After User Claims ETH", logUsers, ggvDiscount);

//         // 8. Recover Surplus stETH (если есть)
//         uint256 surplusStETH = steth.balanceOf(user1StrategyCallForwarder);
//         if (surplusStETH > 0) {
//             uint256 stethBalance = steth.sharesOf(user1StrategyCallForwarder);
//             uint256 stethDebt = pool.mintedStethSharesOf(user1StrategyCallForwarder);
//             uint256 surplusInShares = stethBalance > stethDebt ? stethBalance - stethDebt : 0;
//             uint256 maxAmount = steth.getPooledEthByShares(surplusInShares);

//             console.log("\n[SCENARIO] Step 8. Recover Surplus stETH:", maxAmount);
//             vm.prank(USER1);
//             ggvStrategy.recoverERC20(address(steth), USER1, maxAmount);
//         }

//         _log.printUsers("After Recovery", logUsers);
    }

    function _finalizeWQ(uint256 _maxRequest, uint256 vaultProfit) public {
        vm.deal(address(pool.STAKING_VAULT()), 1 ether);

        vm.warp(block.timestamp + 1 days);
        core.applyVaultReport(
            address(pool.STAKING_VAULT()),
            pool.totalAssets(),
            0,
            pool.DASHBOARD().liabilityShares(),
            0
        );

        if (vaultProfit != 0) {
            vm.startPrank(NODE_OPERATOR);
            pool.DASHBOARD().fund{value: 10 ether}();
            vm.stopPrank();
        }

        vm.startPrank(NODE_OPERATOR);
        uint256 finalizedRequests = pool.WITHDRAWAL_QUEUE().finalize(_maxRequest);
        vm.stopPrank();

        assertEq(finalizedRequests, _maxRequest, "Invalid finalized requests");
    }
}
