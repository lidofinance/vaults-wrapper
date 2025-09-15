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

import {console} from "forge-std/console.sol";

import {MockLazyOracle} from "test/mocks/MockLazyOracle.sol";
import {ILazyOracleMocked} from "test/utils/CoreHarness.sol";

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

    ITellerWithMultiAssetSupport public teller = ITellerWithMultiAssetSupport(0x0baAb6db8d694E1511992b504476ef4073fe614B);
    IBoringOnChainQueue public boringOnChainQueue = IBoringOnChainQueue(0xe39682c3C44b73285A2556D4869041e674d1a6B7);
    IBoringSolver public solver = IBoringSolver(0xAC20dba743CDCd883f6E5309954C05b76d41e080);

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

        address strategyProxyImpl = address(new StrategyProxy());
        strategy = new GGVStrategy(
            strategyProxyImpl,
            address(core.steth()),
            address(teller),
            address(boringOnChainQueue)
        );

        WrapperContext memory ctx = _deployWrapperC(false, address(strategy), 0);
        wrapper = wrapperC(ctx);

        _setupGGV();
    }

//    function setUp() public {
//        super._setUp(Factory.WrapperConfiguration.MINTING_AND_STRATEGY, address(0), false);
//        _checkInitialState();
//
//        wrapperC = WrapperC(payable(address(wrapperC)));
//
//        address strategyProxyImpl = address(new StrategyProxy());
//        strategy = new GGVStrategy(
//            strategyProxyImpl,
//            address(core.steth()),
//            address(wrapperC),
//            address(teller),
//            address(boringOnChainQueue)
//        );
//
//        vm.prank(NODE_OPERATOR);
//        wrapperC.setStrategy(address(strategy));
//
//        vm.deal(user1, 1000 ether);
//        vm.deal(user2, 1000 ether);
//        vm.deal(user3, 1000 ether);
//
//        _setupGGV();
//    }


    function _setupGGV() public {
        address tellerAuthority = teller.authority();
        console.log("teller authority", tellerAuthority);

        IAuthority authority = IAuthority(tellerAuthority);
        address authorityOwner = authority.owner();
        console.log("authority owner", authorityOwner);

        IAccountant accountant = IAccountant(teller.accountant());
        console.log("accountant", address(accountant));

        bytes4 updateAssetDataSig = bytes4(keccak256("updateAssetData(address,bool,bool,uint16)"));
        bytes4 setRateProviderDataSig = bytes4(keccak256("setRateProviderData(address,bool,address)"));
        bytes4 setWithdrawCapacitySig = IBoringOnChainQueue.updateWithdrawAsset.selector;
        bytes4 boringRedeemSolveSig = IBoringSolver.boringRedeemSolve.selector;

        vm.startPrank(authorityOwner);
        authority.setUserRole(address(this), OWNER_ROLE, true);
        authority.setUserRole(address(this), STRATEGIST_MULTISIG_ROLE, true);
        authority.setUserRole(address(this), MULTISIG_ROLE, true);
        authority.setUserRole(address(this), SOLVER_ORIGIN_ROLE, true);
        // authority.setRoleCapability(STRATEGIST_MULTISIG_ROLE, address(this), updateAssetDataSig, true);
        // authority.setRoleCapability(STRATEGIST_MULTISIG_ROLE, address(this), setRateProviderDataSig, true);
        // authority.setRoleCapability(STRATEGIST_MULTISIG_ROLE, address(this), setWithdrawCapacitySig, true);
        // authority.setRoleCapability(STRATEGIST_MULTISIG_ROLE, address(this), boringRedeemSolveSig, true);
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

        uint256 withdrawCapacity;

        withdrawCapacity = boringOnChainQueue.withdrawAssets(address(core.steth())).withdrawCapacity;
        console.log("withdrawCapacity", withdrawCapacity);
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

        console.log("\n[USER ACTION] Step1. Deposit");
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

        console.log("\n[USER ACTION] Step2. Request withdraw");
        console.log("ggv shares: %s", ggvShares);

        vm.prank(USER1);
        WrapperC.WithdrawalRequest memory request = wrapper.requestWithdrawal(ggvShares);
        console.log("requestId", request.requestId);
        console.log("requestType", uint256(request.requestType));

        uint40 timeNow = uint40(block.timestamp);
        uint24 secondsToMaturity = boringOnChainQueue.withdrawAssets(address(core.steth())).secondsToMaturity;
        uint24 secondsToDeadline = type(uint24).max;
        uint128 assetsOut = uint128(boringOnChainQueue.previewAssetsOut(address(core.steth()), uint128(ggvShares), 1));
        uint128 assetsOutWsteth = uint128(boringOnChainQueue.previewAssetsOut(WSTETH, uint128(ggvShares), 1));

        IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
        requests[0] = IBoringOnChainQueue.OnChainWithdraw({
            nonce: boringOnChainQueue.nonce()-1,
            user: address(strategyProxy),
            assetOut: address(core.steth()),
            amountOfShares: uint128(ggvShares),
            amountOfAssets: assetsOut,
            creationTime: timeNow,
            secondsToMaturity: secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });

        //
        // Solve requests
        //
        console.log("\n[GGV Solver]Step3. Solve requests");

        vm.warp(block.timestamp + secondsToMaturity + 1);
        solver.boringRedeemSolve(requests, address(teller), true);

        uint256 user1StethBalance = steth.balanceOf(strategyProxy);
        uint256 stethAmount = core.steth().getPooledEthByShares(user1StethBalance);

        assertEq(steth.balanceOf(user1), 0);
        assertEq(steth.balanceOf(strategyProxy), user1StethBalance);

        //
        // Claim stETH
        //

        console.log("\n[NODE OPERATOR] Step4. Claim stETH and create withdrawal request in WQ");

        //NO gets all unfinalized strategy requestsIds
        uint256 strategyWRLengthBefore = wrapper.getWithdrawalRequestsLength(address(wrapper.STRATEGY()));
        console.log("strategy requests length before", strategyWRLengthBefore);

        uint256 user1WRLengthBefore = wrapper.getWithdrawalRequestsLength(USER1);
        console.log("user1 requests length before", user1WRLengthBefore);
        
        uint256[] memory requestIds = wrapper.getWithdrawalRequests(address(wrapper.STRATEGY()));


        vm.startPrank(NODE_OPERATOR);
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 user1stethShares = steth.sharesOf(strategyProxy);
            console.log("user1stethShares", user1stethShares);

            console.log("strategy requestId", requestIds[i]);
            wrapper.finalizeWithdrawal(requestIds[i], user1stethShares);
        }    
        vm.stopPrank();

        uint256 strategyWRafterLength = wrapper.getWithdrawalRequestsLength(address(wrapper.STRATEGY()));
        console.log("strategy requests length after", strategyWRafterLength);

        uint256 user1WRLengthAfter = wrapper.getWithdrawalRequestsLength(USER1);
        console.log("user1 requests length after", user1WRLengthAfter);

        WrapperC.WithdrawalRequest memory request2 = wrapper.getRequestStatus(request.requestId);

        console.log("stv balance", wrapper.balanceOf(strategyProxy));
 
        // assertApproxEqAbs(steth.balanceOf(user1), user1StethBalance, 2);
        // assertApproxEqAbs(steth.balanceOf(strategyProxy), 0, 2);

        GGVStrategy.UserPosition memory userPosition = ggvStrategy.getUserPosition(USER1);
        console.log("userPosition stShares", userPosition.stShares);
        console.log("userPosition stvShares", userPosition.stvShares);

        console.log("\n[NODE OPERATOR] Step5. Finalize withdrawal request in WQ");

        uint256 requestId = 1;

        _finalizeWQ(1);

        console.log("user balance before claim", USER1.balance);

        console.log("\n[USER ACTION]Step6. Claim request id");
        vm.prank(USER1);
        wrapper.claimWithdrawal(requestId, address(0));

        console.log("user balance after claim", USER1.balance);
    }

    function _finalizeWQ(uint256 _maxRequest) public {
        vm.deal(address(wrapper.STAKING_VAULT()), 1 ether);

        uint256 _maxLiabilityShares = wrapper.VAULT_HUB().vaultRecord(wrapper.STAKING_VAULT()).maxLiabilityShares;
        uint256 liabilityShares = wrapper.DASHBOARD().liabilityShares();
        core.applyVaultReport(address(wrapper.STAKING_VAULT()), 1 ether, 0, liabilityShares, _maxLiabilityShares, 0, false);

        vm.startPrank(NODE_OPERATOR);
        wrapper.DASHBOARD().fund{value: 32 ether}();
        vm.stopPrank();

        vm.startPrank(NODE_OPERATOR);
        wrapper.withdrawalQueue().finalize(_maxRequest);
        vm.stopPrank();
    }
}