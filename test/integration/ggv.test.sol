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

        WrapperContext memory ctx = _deployWrapperC(false, address(strategy), 0, address(teller), address(boringOnChainQueue));
        wrapper = WrapperC(payable(ctx.wrapper));

        strategy = IStrategy(wrapper.STRATEGY());

        console.log("wrapper", address(wrapper));
        console.log("strategy", address(strategy));
        console.log("wrapper setup finished");

        ggvStrategy = GGVStrategy(address(strategy));

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
        
        address strategyProxy = ggvStrategy.getStrategyProxyAddress(USER1);
        vm.label(strategyProxy, "User strategy proxy");

        address strategyProxy2 = ggvStrategy.getStrategyProxyAddress(USER2);
        vm.label(strategyProxy2, "User strategy proxy");

        uint256 depositAmount = 1 ether;

        logUsers.push(TableUtils.User(USER1, "user1"));
        logUsers.push(TableUtils.User(strategyProxy, "user1_proxy"));
//        logUsers.push(TableUtils.User(USER2, "user2"));
//        logUsers.push(TableUtils.User(strategyProxy2, "user2_proxy"));
        logUsers.push(TableUtils.User(address(wrapper), "wrapper"));
        logUsers.push(TableUtils.User(address(wrapper.WITHDRAWAL_QUEUE()), "wq"));

        _log.printHeader("[USER] Before Deposit");
        _log.printUsers(logUsers);

        vm.prank(USER1);
        wrapper.depositETH{value: depositAmount}(USER1);

//        vm.prank(USER2);
//        wrapper.depositETH{value: depositAmount}(USER2);

        vm.startPrank(ADMIN);
//        boringVault.rebase(1 ether);
        vm.stopPrank();

        _log.printHeader("[USER] After Deposit");
        _log.printUsers(logUsers);

        uint256 ggvShares = boringVault.balanceOf(strategyProxy);
        assertEq(core.steth().balanceOf(USER1), 0, "Invalid steth balance");

        // ================= user request withdraw =================

        //share lock period is 1 day
        vm.warp(block.timestamp + 86400);

        _log.printHeader("[USER] Request withdraw");
        _log.printUsers(logUsers);

        // add 1 steth to ggv balance for rebase
//        vm.prank(ADMIN);
//        boringVault.rebase(1 ether);

        uint256 withdrawalStethAmount1 = boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT());
        console.log("boringVault.balanceOf(strategyProxy)", boringVault.balanceOf(strategyProxy));
        console.log("withdrawalStethAmount1", withdrawalStethAmount1);

        uint256 withdrawalAmount = ggvStrategy.withdrawalAmount(USER1);
        console.log("withdrawalAmount", withdrawalAmount);

        uint256 withdrawalStethAmount = boringOnChainQueue.previewAssetsOut(address(steth), uint128(ggvShares), ggvStrategy.DISCOUNT());
        console.log("withdrawalStethAmount2", withdrawalStethAmount);

        uint256 totalStvShares = wrapper.balanceOf(strategyProxy);
        uint256 userTotalEth = wrapper.previewRedeem(totalStvShares);
        uint256 totalGgvShares = boringVault.balanceOf(strategyProxy);
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
            user: address(strategyProxy),
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

        _log.printHeader("After Boring Solver");
        _log.printUsers(logUsers);

        // ================= Claim request =================

        console.log("\n[USER | NODE OPERATOR] Step4. Claim stv and steth, and probably others tokens");

        uint256[] memory requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 1, "Wrapper requests should be zero after finalize");

        vm.startPrank(USER1);
        for (uint256 i = 0; i < requestIds.length; i++) {
            GGVStrategy.UserPosition memory userPosition = ggvStrategy.getUserPosition(USER1);

            uint256 proxyStethSharesBefore = steth.sharesOf(strategyProxy);
            uint256 userStethSharesBefore = steth.sharesOf(USER1);

            uint256 proxyWrapperBalanceBefore = wrapper.balanceOf(strategyProxy);
            uint256 userWrapperBalanceBefore = wrapper.balanceOf(USER1);

            wrapper.finalizeWithdrawal(requestIds[i]);
        }
        vm.stopPrank();

        requestIds = wrapper.getWithdrawalRequests(USER1);
        assertEq(requestIds.length, 0, "Wrapper requests should be zero after finalize");

        _log.printHeader("After user finalize withdrawal");
        _log.printUsers(logUsers);


        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[NODE OPERATOR] Step5. Finalize withdrawal request in WQ");

        _finalizeWQ(1);

        _log.printHeader("After NO finalize withdrawal requests");
        _log.printUsers(logUsers);

        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[USER ACTION]Step6. Claim request id");

        uint256 user1BalanceBeforeClaim = USER1.balance;
        console.log("user balance before claim", user1BalanceBeforeClaim);

        vm.prank(USER1);
        wrapper.claimWithdrawal(1, address(0));

        _log.printHeader("[USER] Claim withdrawal request");
        _log.printUsers(logUsers);

        uint256 surplus = steth.balanceOf(strategyProxy);
        vm.prank(USER1);
        ggvStrategy.recoverERC20(address(steth), USER1, surplus);

        _log.printHeader("[USER] Recovery ERC20");
        _log.printUsers(logUsers);
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