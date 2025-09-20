// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

import {console} from "forge-std/console.sol";

import {ILazyOracleMocked} from "test/utils/CoreHarness.sol";
import {MockBoringSolver} from "../../src/mock/ggv/MockBoringSolver.sol";

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

    uint8 public constant OWNER_ROLE = 8;
    uint8 public constant MULTISIG_ROLE = 9;
    uint8 public constant STRATEGIST_MULTISIG_ROLE = 10;
    uint8 public constant SOLVER_ORIGIN_ROLE = 33;

    // ggv mainnet
    ITellerWithMultiAssetSupport public teller = ITellerWithMultiAssetSupport(0x0baAb6db8d694E1511992b504476ef4073fe614B);
    IBoringOnChainQueue public boringOnChainQueue = IBoringOnChainQueue(0xe39682c3C44b73285A2556D4869041e674d1a6B7);
    IBoringSolver public solver = IBoringSolver(0xAC20dba743CDCd883f6E5309954C05b76d41e080);

//    ITellerWithMultiAssetSupport public teller;
//    MockBoringOnChainQueue public boringOnChainQueue;
//    IBoringSolver public solver;

    WrapperC public wrapper;
    ILazyOracleMocked public lazyOracle;
    WithdrawalQueue public withdrawalQueue;

    address public user1 = address(0x1001);
    address public user2 = address(0x1002);
    address public user3 = address(0x3);

    address WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    //allowed
    //0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 wsteth
    //0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 steth
    //0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 WETH
    //0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE eth

    function setUp() public {
        _initializeCore();

//        address boringVault = address(new MockBoringVault());
//        teller = ITellerWithMultiAssetSupport(address(new MockTeller(boringVault)));
//        boringOnChainQueue = new MockBoringOnChainQueue(boringVault);
//        boringOnChainQueue.updateWithdrawAsset(address(core.steth()),
//            0,
//            604800,
//            1,
//            9,
//            0);
//        solver = new MockBoringSolver(boringVault, address(boringOnChainQueue));

        WrapperContext memory ctx = _deployWrapperC(false, address(strategy), 0, address(teller), address(boringOnChainQueue));
        wrapper = WrapperC(payable(ctx.wrapper));

        strategy = IStrategy(wrapper.STRATEGY());

        console.log("wrapper", address(wrapper));
        console.log("strategy", address(strategy));

        console.log("wrapper setup finished");

        _setupGGV();
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

        teller.updateAssetData(ERC20(address(core.wsteth())), true, true, 0);
        accountant.setRateProviderData(ERC20(address(core.wsteth())), true, address(0));
        boringOnChainQueue.updateWithdrawAsset(
            address(core.wsteth()),
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
        GGVStrategy ggvStrategy = GGVStrategy(address(strategy));
        ERC20 boringVault = ERC20(ggvStrategy.TELLER().vault());

        uint256 depositAmount = 1 ether;

        console.log("\n[USER] Step1. Deposit");
        console.log("deposit amount: %s", depositAmount);

        vm.prank(USER1);
        wrapper.depositETH{value: depositAmount}(USER1);
        uint256 user1StETHAmount = core.steth().balanceOf(USER1); // Would need to calculate separately
        address strategyProxy = ggvStrategy.getStrategyProxyAddress(USER1);
        uint256 ggvShares = boringVault.balanceOf(strategyProxy);

        //share lock period is 1 day
        //
        //  Request withdraw
        //
        vm.warp(block.timestamp + 86400);
        console.log("\n[USER] Step2. Request withdraw");
        console.log("ggv shares: %s", ggvShares);

        uint256 withdrawableEth = wrapper.getWithdrawableAmount(USER1);
        console.log("user1 can withdraw eth", withdrawableEth);

        console.log("USER1", USER1);
        vm.prank(USER1);
        uint256 requestId = wrapper.requestWithdrawalFromStrategy(withdrawableEth);
        // bytes32 ggvRequestId = ggvStrategy.userPositions(USER1).exitRequestId;
        console.log("requestId", requestId);
        console.log("ggvShares", ggvShares);
        // console.log("ggvRequestId", ggvRequestId);
        // console.log("requestType", uint256(request.requestType));

        //
        // Solve requests
        //
        console.log("\n[GGV Solver]Step3. Solve requests");

        // ================= BoringSolver build request =================

        GGVStrategy.UserPosition memory position = ggvStrategy.getUserPosition(USER1);

        uint40 timeNow = uint40(block.timestamp);
        MockBoringOnChainQueue.WithdrawAsset memory _assetSteth = boringOnChainQueue.withdrawAssets(address(core.steth()));
        uint24 secondsToMaturity = _assetSteth.secondsToMaturity;
        uint24 secondsToDeadline = type(uint24).max;
        uint128 assetsOut = uint128(boringOnChainQueue.previewAssetsOut(address(core.steth()), uint128(ggvShares), 1));

        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = IBoringOnChainQueue.OnChainWithdraw({
            nonce: boringOnChainQueue.nonce()-1,
            user: address(strategyProxy),
            assetOut: address(core.steth()),
            amountOfShares: position.exitGgvShares,
            amountOfAssets: position.exitAmountOfAssets128,
            creationTime: timeNow,
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });
        console.log("requests[0]");
        console.logBytes32(keccak256(abi.encode(requests[0])));

        // ================= BoringSolver sent request =================

        vm.warp(block.timestamp + secondsToMaturity + 1);

//        vm.startPrank(USER2);
//        steth.submit{value: 20 ether}(address(0));
//        steth.approve(address(core.wsteth()), type(uint256).max);
//        uint256 wstETHAmount = core.wsteth().wrap(10 ether);
////        core.wsteth().approve(address(solver), wstETHAmount);
//        core.wsteth().transfer(address(solver), wstETHAmount);
//        vm.stopPrank();



        solver.boringRedeemSolve(requests, address(teller), true);

        uint256 user1WstethBalance = core.wsteth().balanceOf(strategyProxy);
        uint256 stethAmount = core.wsteth().getStETHByWstETH(user1WstethBalance);

        assertEq(core.wsteth().balanceOf(user1), 0);
        assertEq(core.wsteth().balanceOf(strategyProxy), user1WstethBalance);

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

        // ================= [USER] Step5. Create withdrawal request in WQ =================
        console.log("\n[USER] Step5. Create withdrawal request in WQ");

        vm.startPrank(USER1);
        uint256 withdrawableStv = wrapper.withdrawableStv(USER1, steth.sharesOf(USER1));

        console.log("withdrawableStv", withdrawableStv);
        console.log("wrapper balance", wrapper.balanceOf(USER1));
        console.log("steth shares", steth.sharesOf(USER1));
        console.log("strategyProxy wrapper shares", wrapper.balanceOf(strategyProxy));
        console.log("strategyProxy wrapper shares", wrapper.balanceOf(strategyProxy));


        vm.expectRevert("ALLOWANCE_EXCEEDED");
        wrapper.requestWithdrawal(withdrawableStv);

        steth.approve(address(wrapper), withdrawableStv);
        requestId = wrapper.requestWithdrawal(withdrawableStv);
        vm.stopPrank();

        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[NODE OPERATOR] Step5. Finalize withdrawal request in WQ");

        _finalizeWQ(1);

        // ================= [NODE OPERATOR] Step5. Finalize withdrawal request in WQ =================
        console.log("\n[USER ACTION]Step6. Claim request id");

        uint256 user1BalanceBeforeClaim = USER1.balance;
        console.log("user balance before claim", user1BalanceBeforeClaim);

        vm.prank(USER1);
        wrapper.claimWithdrawal(requestId, address(0));

        console.log("user balance after claim", USER1.balance);
    }

    function _finalizeWQ(uint256 _maxRequest) public {
        vm.deal(address(wrapper.STAKING_VAULT()), 1 ether);

        uint256 _maxLiabilityShares = wrapper.VAULT_HUB().vaultRecord(wrapper.STAKING_VAULT()).maxLiabilityShares;
        uint256 liabilityShares = wrapper.DASHBOARD().liabilityShares();
        core.applyVaultReport(address(wrapper.STAKING_VAULT()), 1 ether, 0, liabilityShares, 0, false);

        vm.startPrank(NODE_OPERATOR);
        wrapper.DASHBOARD().fund{value: 32 ether}();
        vm.stopPrank();

        vm.startPrank(NODE_OPERATOR);
        wrapper.WITHDRAWAL_QUEUE().finalize(_maxRequest);
        vm.stopPrank();
    }
}