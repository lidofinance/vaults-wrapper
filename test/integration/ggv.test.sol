    // SPDX-License-Identifier: MIT
    pragma solidity >=0.8.25;

    import {Test, console} from "forge-std/Test.sol";

    import {CoreHarness} from "test/utils/CoreHarness.sol";
    import {DefiWrapper} from "test/utils/DefiWrapper.sol";

    import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
    import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
    import {IBoringSolver} from "src/interfaces/ggv/IBoringSolver.sol";
    import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

    import {WrapperBase} from "src/WrapperBase.sol";
    import {WrapperC} from "src/WrapperC.sol";
    import {IDashboard} from "src/interfaces/IDashboard.sol";
    import {ILido} from "src/interfaces/ILido.sol";
    import {IVaultHub} from "src/interfaces/IVaultHub.sol";
    import {IStakingVault} from "src/interfaces/IStakingVault.sol";
    import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
    import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
    import {IStrategy} from "src/interfaces/IStrategy.sol";
    import {StrategyProxy} from "src/strategy/StrategyProxy.sol";

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

    contract GGVTest is Test {
        CoreHarness public core;
        DefiWrapper public dw;

        // Access to harness components
        WrapperBase public wrapper;
        IDashboard public dashboard;
        ILido public steth;
        IVaultHub public vaultHub;
        IStakingVault public stakingVault;
        WithdrawalQueue public withdrawalQueue;
        IStrategy public strategy;

        uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
        uint256 public constant TOTAL_BP = 100_00;

        uint8 public constant OWNER_ROLE = 8;
        uint8 public constant MULTISIG_ROLE = 9;
        uint8 public constant STRATEGIST_MULTISIG_ROLE = 10;
        uint8 public constant SOLVER_ORIGIN_ROLE = 33;

        address public ggvDeployer = 0x130CA661B9c0bcbCd1204adF9061A569D5e0Ca24; //can update asset data

        address public user1 = address(0x1001);
        address public user2 = address(0x1002);
        address public user3 = address(0x3);

        ITellerWithMultiAssetSupport public teller = ITellerWithMultiAssetSupport(0x0baAb6db8d694E1511992b504476ef4073fe614B);
        IBoringOnChainQueue public boringOnChainQueue = IBoringOnChainQueue(0xe39682c3C44b73285A2556D4869041e674d1a6B7);
        IBoringSolver public solver = IBoringSolver(0xAC20dba743CDCd883f6E5309954C05b76d41e080);

        function setUp() public {
            core = new CoreHarness("lido-core/deployed-local.json");

            //allowed
            //0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 wsteth
            //0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 steth
            //0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 WETH
            //0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE eth

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

            address strategyProxyImpl = address(new StrategyProxy());

            strategy = new GGVStrategy(
                strategyProxyImpl,
                address(core.steth()),
                address(teller),
                address(boringOnChainQueue)
            );
            dw = new DefiWrapper(address(core), address(strategy));

            wrapper = dw.wrapper();
            withdrawalQueue = dw.withdrawalQueue();
            strategy = dw.strategy();
            dashboard = dw.dashboard();
            steth = core.steth();
            vaultHub = core.vaultHub();
            stakingVault = dw.stakingVault();

            console.log("wrapper strategy", address(strategy));

            vm.deal(user1, 1000 ether);
            vm.deal(user2, 1000 ether);
            vm.deal(user3, 1000 ether);

            assertEq(TOTAL_BP, core.LIDO_TOTAL_BASIS_POINTS(), "TOTAL_BP should be equal to LIDO_TOTAL_BASIS_POINTS");
            console.log("--- setup done ---");
        }

        function test_depositStrategy() public {
            vm.prank(user1);
            uint256 user1StvShares = WrapperC(payable(address(wrapper))).depositETHToStrategy{value: 1 ether}(user1);
            uint256 user1StETHAmount = 0; // Would need to calculate separately

            console.log("user1StvShares", user1StvShares);
            console.log("user1StETHAmount", user1StETHAmount);
            dw.logAllBalances("after deposit", user1, address(wrapper));
        }

        function test_withdrawStrategy() public {
            console.log("\n--- test_withdrawStrategy ---");

            // strategy is already initialized in setUp()
            GGVStrategy ggvStrategy = GGVStrategy(address(strategy));
            ERC20 boringVault = ERC20(ggvStrategy.TELLER().vault());

            console.log("boringVault address", address(boringVault));
            console.log("boringVault totalSupply", boringVault.totalSupply());
            console.log("boringVault balance before deposit", boringVault.balanceOf(address(strategy)));
            console.log("ggv address", address(this));
            console.log("user1 address", user1);

            vm.prank(user1);
            uint256 user1StvShares = WrapperC(payable(address(wrapper))).depositETHToStrategy{value: 1 ether}(user1);
            uint256 user1StETHAmount = 0; // Would need to calculate separately

            address strategyProxy = ggvStrategy.getStrategyProxyAddress(user1);
            console.log("strategy proxy", strategyProxy);
            console.log("steth balance strategy proxy after", core.steth().balanceOf(strategyProxy));
            console.log("steth balance strategy", core.steth().balanceOf(address(strategy)));

            console.log("\nuser1StvShares", user1StvShares);
            console.log("user1StETHAmount", user1StETHAmount);

            uint256 ggvShares = boringVault.balanceOf(strategyProxy);

            console.log("user1 strategy proxy", strategyProxy);
            console.log("ggvShares", ggvShares);

            console.log("boringVault totalSupply", boringVault.totalSupply());
            console.log("boringVault balance before deposit", boringVault.balanceOf(address(strategy)));
            console.log("queue balance", boringVault.balanceOf(address(boringOnChainQueue)));

            //share lock period is 1 day
            vm.warp(block.timestamp + 86400);

            vm.prank(user1);
            strategy.requestWithdraw(ggvShares);

            console.log("boringVault totalSupply", boringVault.totalSupply());
            console.log("boringVault balance after deposit", boringVault.balanceOf(address(strategy)));
            console.log("queue balance", boringVault.balanceOf(address(boringOnChainQueue)));

            //solve the request
            uint40 timeNow = uint40(block.timestamp);
            uint24 secondsToMaturity = boringOnChainQueue.withdrawAssets(address(core.steth())).secondsToMaturity;
            uint24 secondsToDeadline = type(uint24).max;

            IBoringOnChainQueue.OnChainWithdraw[] memory requests = new IBoringOnChainQueue.OnChainWithdraw[](1);
            requests[0] = IBoringOnChainQueue.OnChainWithdraw({
                nonce: boringOnChainQueue.nonce()-1,
                user: address(strategyProxy),
                assetOut: address(core.steth()),
                amountOfShares: uint128(ggvShares),
                amountOfAssets: uint128(boringOnChainQueue.previewAssetsOut(address(core.steth()), uint128(ggvShares), 1)),
                creationTime: timeNow,
                secondsToMaturity: secondsToMaturity,
                secondsToDeadline: secondsToDeadline
            });

            bytes32[] memory requestIds = boringOnChainQueue.getRequestIds();
            console.logBytes32(requestIds[requestIds.length - 1]);

            bytes memory solveData = abi.encode(IBoringSolver.SolveType.BORING_REDEEM);

            solver.boringRedeemSolve(requests, address(teller), true);

            uint256 user1StethBalance = steth.balanceOf(strategyProxy);

            assertEq(steth.balanceOf(user1), 0);
            assertEq(steth.balanceOf(strategyProxy), user1StethBalance);

            vm.startPrank(user1);
            strategy.claim(address(core.steth()), user1StethBalance);
            vm.stopPrank();

            assertEq(steth.balanceOf(user1), user1StethBalance);
            assertEq(steth.balanceOf(strategyProxy), 0);
        }
    }