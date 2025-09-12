// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";  
import {WrapperCHarness} from "test/utils/WrapperCHarness.sol";
import {WrapperBHarness} from "test/utils/WrapperBHarness.sol";

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

contract GGVTest is WrapperBHarness {

    uint8 public constant OWNER_ROLE = 8;
    uint8 public constant MULTISIG_ROLE = 9;
    uint8 public constant STRATEGIST_MULTISIG_ROLE = 10;
    uint8 public constant SOLVER_ORIGIN_ROLE = 33;

    ITellerWithMultiAssetSupport public teller = ITellerWithMultiAssetSupport(0x0baAb6db8d694E1511992b504476ef4073fe614B);
    IBoringOnChainQueue public boringOnChainQueue = IBoringOnChainQueue(0xe39682c3C44b73285A2556D4869041e674d1a6B7);
    IBoringSolver public solver = IBoringSolver(0xAC20dba743CDCd883f6E5309954C05b76d41e080);

    IStrategy public strategy;
    WrapperC public wrapperC;
    ILazyOracleMocked public lazyOracle;

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
        super._setUp(Factory.WrapperConfiguration.MINTING_AND_STRATEGY, address(0), false);
        _checkInitialState();

        wrapperC = WrapperC(payable(address(wrapper)));

        address strategyProxyImpl = address(new StrategyProxy());
        strategy = new GGVStrategy(
            strategyProxyImpl,
            address(core.steth()),
            address(wrapper),
            address(teller),
            address(boringOnChainQueue)
        );

        vm.prank(NODE_OPERATOR);
        wrapperC.setStrategy(address(strategy));

        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);

        _setupGGV();
    }

    function _assertUniversalInvariants(string memory _context) internal virtual override {}
    function _allPossibleStvHolders() internal view override returns (address[] memory) {}

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
    }

    function test_depositStrategy() public {
        vm.prank(user1);
        WrapperC(payable(address(wrapper))).depositETH{value: 1 ether}(user1);

        console.log(wrapperC.totalAssets());
        uint256 user1StETHAmount = 0; // Would need to calculate separately

        console.log("user1StETHAmount", user1StETHAmount);
    }

    function test_happy_path() public {
        GGVStrategy ggvStrategy = GGVStrategy(address(strategy));
        ERC20 boringVault = ERC20(ggvStrategy.TELLER().vault());

        uint256 depositAmount = 1 ether;

        console.log("\nStep1. Deposit");
        console.log("deposit amount: %s", depositAmount);

        vm.prank(user1);
        WrapperC(payable(address(wrapper))).depositETH{value: depositAmount}(user1);
        uint256 user1StETHAmount = core.steth().balanceOf(user1); // Would need to calculate separately

        address strategyProxy = ggvStrategy.getStrategyProxyAddress(user1);
        uint256 ggvShares = boringVault.balanceOf(strategyProxy);

        //share lock period is 1 day
        //
        //  Request withdraw
        //
        vm.warp(block.timestamp + 86400);

        console.log("\nStep2. Request withdraw");
        console.log("ggv shares: %s", ggvShares);

        vm.prank(user1);
        strategy.requestWithdraw(ggvShares);

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

        bytes32[] memory requestIds = boringOnChainQueue.getRequestIds();
        bytes memory solveData = abi.encode(IBoringSolver.SolveType.BORING_REDEEM);

        //
        // Solve requests
        //
        console.log("\nStep3. Solve requests");

        vm.warp(block.timestamp + secondsToMaturity + 1);
        solver.boringRedeemSolve(requests, address(teller), true);

        uint256 user1StethBalance = steth.balanceOf(strategyProxy);
        uint256 stethAmount = core.steth().getPooledEthByShares(user1StethBalance);

        assertEq(steth.balanceOf(user1), 0);
        assertEq(steth.balanceOf(strategyProxy), user1StethBalance);

        //
        // Claim stETH
        //

        console.log("\nStep4. Claim stETH");

        vm.startPrank(user1);
        uint256 stvToken = strategy.finalizeWithdrawal(user1StethBalance);
        vm.stopPrank();

        assertApproxEqAbs(steth.balanceOf(user1), user1StethBalance, 2);
        assertApproxEqAbs(steth.balanceOf(strategyProxy), 0, 2);

        GGVStrategy.UserPosition memory userPosition = ggvStrategy.getUserPosition(user1);
        console.log("userPosition stShares", userPosition.stShares);
        console.log("userPosition stvShares", userPosition.stvShares);

        console.log(wrapperC.balanceOf(user1));
        console.log(wrapperC.balanceOf(strategyProxy));
        console.log(stvToken);

        console.log("\nStep5. Request withdrawalQueue");

        vm.startPrank(user1);
        core.steth().approve(address(wrapperC), user1StethBalance);
        uint256 requestId = wrapperC.requestWithdrawal(stvToken);
        console.log("requestId", requestId);
        vm.stopPrank();

        _finalizeWQ();

        console.log("\nStep6. Claim request id");
        vm.startPrank(user1);
        wrapperC.claimWithdrawal(requestId, address(0));
        vm.stopPrank();
    }

    function _finalizeWQ() public {
        vm.startPrank(NODE_OPERATOR);
        vm.deal(address(wrapperC.STAKING_VAULT()), 1 ether);
        wrapperC.DASHBOARD().fund{value: 1 ether}();

        vm.warp(block.timestamp + 2 days);

        vm.mockCall(
            address(withdrawalQueue.LAZY_ORACLE()),
            abi.encodeWithSelector(ILazyOracle.latestReportTimestamp.selector),
            abi.encode(block.timestamp + 61 days)
        );
        vm.mockCall(
            address(vaultHub),
            abi.encodeWithSelector(IVaultHub.isReportFresh.selector, address(wrapperC.STAKING_VAULT())),
            abi.encode(true)
        );

        core.applyVaultReport(address(wrapperC.STAKING_VAULT()), 1 ether, 0, 0, 0, false);
        // withdrawalQueue.LAZY_ORACLE().mock__updateLatestReportTimestamp(block.timestamp);

        withdrawalQueue.finalize(1);
        vm.stopPrank();
    }
}