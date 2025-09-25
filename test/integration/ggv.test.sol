// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {WrapperCHarness} from "test/utils/WrapperCHarness.sol";

import {Factory} from "src/Factory.sol";
import {StrategyProxy} from "src/strategy/StrategyProxy.sol";
import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {WrapperC} from "src/WrapperC.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";

import {MockTeller} from "src/mock/ggv/MockTeller.sol";
import {MockBoringVault} from "src/mock/ggv/MockBoringVault.sol";
import {MockBoringOnChainQueue} from "src/mock/ggv/MockBoringOnChainQueue.sol";

import {ILazyOracleMocked} from "test/utils/CoreHarness.sol";
import {MockBoringSolver} from "../../src/mock/ggv/MockBoringSolver.sol";

import {TableUtils} from "../utils/format/TableUtils.sol";
import {GGVVaultMock, GGVMockTeller,GGVQueueMock} from "src/mock/GGVMock.sol";

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

contract GGVTest is WrapperCHarness {
    using TableUtils for TableUtils.Context;
    TableUtils.Context private _log;

    address public constant ADMIN = address(0x1337);

    uint8 public constant OWNER_ROLE = 8;
    uint8 public constant MULTISIG_ROLE = 9;
    uint8 public constant STRATEGIST_MULTISIG_ROLE = 10;
    uint8 public constant SOLVER_ORIGIN_ROLE = 33;

    // Use local mocks for teller/on-chain queue/solver in integration tests
//    ITellerWithMultiAssetSupport public teller;
//    IBoringOnChainQueue public boringOnChainQueue;
//    IBoringSolver public solver;

    ITellerWithMultiAssetSupport public teller ;
    IBoringOnChainQueue public boringOnChainQueue;
    IBoringSolver public solver;

    WrapperC public wrapper;
    ILazyOracleMocked public lazyOracle;
    WithdrawalQueue public withdrawalQueue;

    GGVStrategy public ggvStrategy;
    GGVVaultMock public boringVault;

    address WSTETH = address(0); // unused with mocks

    TableUtils.User[] public logUsers;

    WrapperContext public  ctx;

    address public user1StrategyProxy;
    address public user2StrategyProxy;

    //allowed
    //0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 wsteth
    //0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 steth
    //0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 WETH
    //0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE eth

    function setUp() public {
        _initializeCore();

        vm.deal(ADMIN, 100_000 ether);

        boringVault = new GGVVaultMock(ADMIN, address(steth));
        teller = GGVMockTeller(address(boringVault.TELLER()));
        boringOnChainQueue = GGVQueueMock(address(boringVault.BORING_QUEUE()));

        ctx = _deployWrapperC(false, address(strategy), 0, address(teller), address(boringOnChainQueue));
        wrapper = WrapperC(payable(ctx.wrapper));

        strategy = IStrategy(wrapper.STRATEGY());
        ggvStrategy = GGVStrategy(address(strategy));

        user1StrategyProxy = ggvStrategy.getStrategyProxyAddress(USER1);
        vm.label(user1StrategyProxy, "User1 strategy proxy");

        user2StrategyProxy = ggvStrategy.getStrategyProxyAddress(USER2);
        vm.label(user2StrategyProxy, "User2 strategy proxy");

        _log.init(
            address(wrapper),
            address(boringVault),
            address(steth),
            address(boringOnChainQueue),
            ggvStrategy.DISCOUNT()
        );

        vm.startPrank(ADMIN);
        steth.submit{value: 10 ether}(ADMIN);
        steth.approve(address(boringVault), type(uint256).max);
        vm.stopPrank();

        // Skip external GGV mainnet setup when using local mocks
//        _setupGGV();
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
        boringOnChainQueue.updateWithdrawAsset(
            address(core.steth()),
            0,
            604800,
            1,
            9,
            0
        );

        console.log("setup GGV finished\n");
    }

    function test_depositStrategy() public {
        vm.prank(USER1);
        wrapper.depositETH{value: 1 ether}(USER1);

        console.log(wrapper.totalAssets());
        uint256 user1StETHAmount = 0; // Would need to calculate separately

        console.log("user1StETHAmount", user1StETHAmount);
    }
    
    function test_happy_path() public {
        uint256 depositAmount = 1 ether;

        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(user1StrategyProxy, "user1_proxy"));
        logUsers.push(TableUtils.User(address(wrapper), "wrapper"));
        logUsers.push(TableUtils.User(address(wrapper.WITHDRAWAL_QUEUE()), "wq"));

        _log.printUsers("[USER] Before Deposit", logUsers);

        vm.prank(USER1);
        wrapper.depositETH{value: depositAmount}(USER1);

        _log.printUsers("[USER] After Deposit", logUsers);

        uint256 ggvShares = boringVault.balanceOf(user1StrategyProxy);
        assertEq(core.steth().balanceOf(USER1), 0, "Invalid steth balance");

        // ================= user request withdraw =================

        //share lock period is 1 day
        vm.warp(block.timestamp + 86400);

        _log.printUsers("[USER] Request withdraw", logUsers);

        // add 1 steth to ggv balance for rebase
//        vm.prank(ADMIN);
//        boringVault.rebase(1 ether);

        uint256 withdrawalStethAmount1 = boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT());
        console.log("boringVault.balanceOf(strategyProxy)", boringVault.balanceOf(user1StrategyProxy));
        console.log("withdrawalStethAmount1", withdrawalStethAmount1);

        uint256 withdrawalAmount = ggvStrategy.withdrawalAmount(USER1);
        console.log("withdrawalAmount", withdrawalAmount);

        uint256 withdrawalStethAmount = boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT());
        console.log("withdrawalStethAmount2", withdrawalStethAmount);

        uint256 totalStvShares = wrapper.balanceOf(user1StrategyProxy);
        uint256 userTotalEth = wrapper.previewRedeem(totalStvShares);
        uint256 totalGgvShares = boringVault.balanceOf(user1StrategyProxy);
        uint256 exitGgvShares = Math.mulDiv(totalGgvShares, withdrawalAmount, userTotalEth);

        uint96 queueNonce = boringOnChainQueue.nonce();

        vm.prank(USER1);
        uint256 requestId = wrapper.requestWithdrawalFromStrategy(withdrawalStethAmount);
        // bytes32 ggvRequestId = ggvStrategy.userPositions(USER1).exitRequestId;


        //
        // Solve requests
        //
        console.log("\n[GGV Solver]Step3. Solve requests");

        // ================= BoringSolver build request =================

        GGVStrategy.UserPosition memory position = ggvStrategy.getUserPosition(USER1);

        uint40 timeNow = uint40(block.timestamp);
        MockBoringOnChainQueue.WithdrawAsset memory _assetSteth = boringOnChainQueue.withdrawAssets(address(steth));
        uint24 secondsToMaturity = _assetSteth.secondsToMaturity;
        uint24 secondsToDeadline = type(uint24).max;
        uint128 assetsOut = uint128(boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT()));

        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = IBoringOnChainQueue.OnChainWithdraw({
            nonce: queueNonce,
            user: address(user1StrategyProxy),
            assetOut: address(steth),
            amountOfShares: uint128(exitGgvShares),
            amountOfAssets: assetsOut,
            creationTime: timeNow,
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });

        // ================= BoringSolver sends assets and solves =================

        vm.warp(block.timestamp + secondsToMaturity + 1);

        // Fund solver with enough stETH and approve queue to pull them
//        vm.startPrank(USER2);
//        steth.submit{value: 50 ether}(address(0));
//        uint256 u2StEth = steth.balanceOf(USER2);
//        steth.transfer(address(solver), u2StEth);
//        vm.stopPrank();
//
//        vm.prank(address(solver));
//        steth.approve(address(boringOnChainQueue), type(uint256).max);

//        solver.boringRedeemSolve(requests, address(teller), true);
        boringOnChainQueue.solveOnChainWithdraws(requests, new bytes(0), address(0));

        _log.printUsers("After Boring Solver", logUsers);

        // ================= Claim request =================

        console.log("\n[USER | NODE OPERATOR] Step4. Claim stv and steth, and probably others tokens");

        uint256[] memory requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 1, "Wrapper requests should be zero after finalize");

        vm.startPrank(USER1);
        for (uint256 i = 0; i < requestIds.length; i++) {
            wrapper.finalizeWithdrawal(requestIds[i]);
        }
        vm.stopPrank();

        requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 0, "Wrapper requests should be zero after finalize");

        _log.printUsers("After user finalize withdrawal", logUsers);


        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[NODE OPERATOR] Step5. Finalize withdrawal request in WQ");

        _finalizeWQ(1);

        _log.printUsers("After NO finalize withdrawal requests", logUsers);

        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[USER ACTION]Step6. Claim request id");

        uint256 user1BalanceBeforeClaim = USER1.balance;
        console.log("user balance before claim", user1BalanceBeforeClaim);

        vm.prank(USER1);
        wrapper.claimWithdrawal(1, address(0));

        _log.printUsers("[USER] Claim withdrawal request", logUsers);


    }

    function test_ggv_surplus() public {
        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(user1StrategyProxy, "user1_proxy"));
        logUsers.push(TableUtils.User(address(wrapper), "wrapper"));
        logUsers.push(TableUtils.User(address(wrapper.WITHDRAWAL_QUEUE()), "wq"));

        uint256 depositAmount = 1 ether;

        vm.prank(USER1);
        wrapper.depositETH{value: depositAmount}(USER1);

        vm.startPrank(ADMIN);
        boringVault.rebase(1 ether);
        vm.stopPrank();

        _log.printUsers("[USER] before request", logUsers);

        uint256 ggvShares = boringVault.balanceOf(user1StrategyProxy);
        uint256 withdrawalStethAmount = boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT());

        vm.prank(USER1);
        uint256 requestId = wrapper.requestWithdrawalFromStrategy(withdrawalStethAmount);
        bytes32 ggvRequestId = ggvStrategy.getUserPosition(USER1).exitRequestId;

        IBoringOnChainQueue.OnChainWithdraw memory req = GGVQueueMock(address(boringOnChainQueue)).mockGetRequestById(ggvRequestId);

        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = req;
        boringOnChainQueue.solveOnChainWithdraws(requests, new bytes(0), address(0));

        _log.printUsers("[USER] Solve request", logUsers);

        uint256[] memory requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 1, "Wrapper requests should be zero after finalize");

        vm.startPrank(USER1);
        for (uint256 i = 0; i < requestIds.length; i++) {
            wrapper.finalizeWithdrawal(requestIds[i]);
        }
        vm.stopPrank();

        _log.printUsers("[USER] Finalize requests", logUsers);

        uint256 _amountStethStrategyBefore = steth.balanceOf(user1StrategyProxy);
        uint256 _amountStethUserBefore = steth.balanceOf(USER1);
        assertEq(_amountStethUserBefore, 0);

        vm.prank(USER1);
        ggvStrategy.recoverERC20(address(steth), USER1, _amountStethStrategyBefore);

        uint256 _amountStethStrategyAfter = steth.balanceOf(user1StrategyProxy);
        uint256 _amountStethUserAfter = steth.balanceOf(USER1);
        assertEq(_amountStethStrategyAfter, 0);
        assertEq(_amountStethUserAfter, _amountStethStrategyBefore);

        _log.printUsers("[USER] Recovery ERC20", logUsers);
    }

    function test_rebase_scenario() public {
        // APR_Vault = 5%, APR_steth = 4%
        uint256 depositAmount = 1 ether;
        uint256 targetStethRate = 1.04 ether; // 4% rebase
        uint256 vaultProfit = depositAmount * 5 / 100; // 0.05 ether profit

        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(user1StrategyProxy, "user1_proxy"));
        logUsers.push(TableUtils.User(address(wrapper), "wrapper"));
        logUsers.push(TableUtils.User(address(wrapper.WITHDRAWAL_QUEUE()), "wq"));

        _log.printUsers("[SCENARIO] Initial State", logUsers);

        // 1. Initial Deposit
        vm.prank(USER1);
        wrapper.depositETH{value: depositAmount}(USER1);

        _log.printUsers("[SCENARIO] After Deposit (1 ETH)", logUsers);

        // 2. Simulate Rebases
        console.log("\n[SCENARIO] Simulating Rebases (Vault +5%, stETH +4%)");

        // a) Vault Rebase (simulated via mock report)
        uint256 currentLiabilityShares = wrapper.DASHBOARD().liabilityShares();
        uint256 currentTotalAssets = wrapper.totalAssets();

        core.applyVaultReport(
            address(ctx.vault),
            currentTotalAssets + vaultProfit,
            0,
            currentLiabilityShares,
            0,
            false
        );
        // Apply 4% increase to core (stETH share ratio)
        uint256 currentTotalEth = steth.totalSupply();
        uint256 ethProfit = currentTotalEth * 4 / 100;
        core.increaseBufferedEther(ethProfit);

        assertEq(steth.getPooledEthByShares(1e18) / 1e16, targetStethRate / 1e16, "stETH rate did not update to 1.04");

        _log.printUsers("[SCENARIO] After report", logUsers);

        // 3. Request withdrawal (full amount, based on appreciated value)
        uint256 totalGgvShares = boringVault.balanceOf(user1StrategyProxy);
        uint256 withdrawalStethAmount = boringOnChainQueue.previewAssetsOut(
            address(steth),
            uint128(totalGgvShares),
            ggvStrategy.DISCOUNT()
        );
        console.log("\n[SCENARIO] Requesting withdrawal based on new appreciated assets:", withdrawalStethAmount);

        vm.prank(USER1);
        uint256 requestId = wrapper.requestWithdrawalFromStrategy(withdrawalStethAmount);

        _log.printUsers("[SCENARIO] After Request Withdrawal", logUsers);

        // 4. Solve GGV requests (Simulate GGV Solver)
        console.log("\n[SCENARIO] Step 4. Solve GGV requests");

        GGVStrategy.UserPosition memory position = ggvStrategy.getUserPosition(USER1);
        bytes32 ggvRequestId = position.exitRequestId;

        IBoringOnChainQueue.OnChainWithdraw memory req = GGVQueueMock(address(boringOnChainQueue)).mockGetRequestById(ggvRequestId);
        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = req;

        vm.warp(block.timestamp + req.secondsToMaturity + 1); // Перематываем время
        boringOnChainQueue.solveOnChainWithdraws(requests, new bytes(0), address(0));

        _log.printUsers("After GGV Solver", logUsers);

        // 5. User Finalizes Withdrawal (Wrapper side)
        console.log("\n[SCENARIO] Step 5. Finalize Wrapper withdrawal");
        uint256[] memory requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 1, "Wrapper requests should be one before finalize");

        vm.startPrank(USER1);
        for (uint256 i = 0; i < requestIds.length; i++) {
            wrapper.finalizeWithdrawal(requestIds[i]);
        }
        vm.stopPrank();

        _log.printUsers("After User Finalizes Wrapper", logUsers);

        // 6. Node Operator Finalizes WQ (Node Operator side)
        console.log("\n[SCENARIO] Step 6. Finalize WQ (Node Operator)");
        // Добавляем ETH в StakingVault, чтобы WQ мог забрать средства
        vm.deal(address(ctx.vault), 10 ether);
        _finalizeWQ(1);

        _log.printUsers("After WQ Finalized", logUsers);

        // 7. User Claims ETH
        console.log("\n[SCENARIO] Step 7. Claim final ETH");
        uint256 userBalanceBeforeClaim = USER1.balance;

        vm.prank(USER1);
        wrapper.claimWithdrawal(1, address(0));

        uint256 ethClaimed = USER1.balance - userBalanceBeforeClaim;
        console.log("ETH Claimed:", ethClaimed);

        _log.printUsers("After User Claims ETH", logUsers);

        // 8. Recover Surplus stETH (если есть)
        uint256 surplusStETH = steth.balanceOf(user1StrategyProxy);
        if (surplusStETH > 0) {
            uint256 stethBalance = steth.sharesOf(user1StrategyProxy); // Баланс на прокси
            uint256 stethDebt = wrapper.getStethShares(user1StrategyProxy); // Долг перед Wrapper
            uint256 surplusInShares = stethBalance > stethDebt ? stethBalance - stethDebt : 0;
            uint256 maxAmount = steth.getPooledEthByShares(surplusInShares);

            console.log("\n[SCENARIO] Step 8. Recover Surplus stETH:", maxAmount);
            vm.prank(USER1);
            ggvStrategy.recoverERC20(address(steth), USER1, maxAmount);
        }

        _log.printUsers("After Recovery", logUsers);

    }

    function _finalizeWQ(uint256 _maxRequest) public {
        vm.deal(address(wrapper.STAKING_VAULT()), 1 ether);

        uint256 _maxLiabilityShares = wrapper.VAULT_HUB().vaultRecord(wrapper.STAKING_VAULT()).maxLiabilityShares;
        uint256 liabilityShares = wrapper.DASHBOARD().liabilityShares();
        core.applyVaultReport(address(wrapper.STAKING_VAULT()), wrapper.totalAssets(), 0, liabilityShares, 0, false);

        vm.startPrank(NODE_OPERATOR);
        wrapper.DASHBOARD().fund{value: 32 ether}();
        vm.stopPrank();

        vm.startPrank(NODE_OPERATOR);
        wrapper.WITHDRAWAL_QUEUE().finalize(_maxRequest);
        vm.stopPrank();
    }
}