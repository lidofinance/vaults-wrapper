// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {DefiWrapper} from "test/utils/DefiWrapper.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {WrapperBase} from "src/WrapperBase.sol";
import {WrapperA} from "src/WrapperA.sol";
import {WrapperC} from "src/WrapperC.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {ExampleLoopStrategy, LenderMock} from "src/ExampleLoopStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract StrategyTest is Test {
    CoreHarness public core;
    DefiWrapper public dwWithStrategy;

    // Access to harness components for strategy wrapper
    WrapperC public wrapperC;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    ExampleLoopStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        
        // Setup wrapper with strategy
        dwWithStrategy = new DefiWrapper(address(core));
        wrapperC = dwWithStrategy.wrapper();
        withdrawalQueue = dwWithStrategy.withdrawalQueue();
        strategy = dwWithStrategy.strategy();
        dashboard = dwWithStrategy.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = dwWithStrategy.stakingVault();

        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);
        
        // Ensure LenderMock has sufficient ETH for borrowing
        vm.deal(address(strategy.LENDER_MOCK()), 10000 ether);

        assertEq(TOTAL_BP, core.LIDO_TOTAL_BASIS_POINTS(), "TOTAL_BP should be equal to LIDO_TOTAL_BASIS_POINTS");
    }

    // Tests opening a leveraged position with strategy execution for a single user
    // Verifies deposit → automatic strategy execution → stETH minting → leverage loop
    function test_depositWithStrategyExecution() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();
        uint256 initialVaultBalance = address(stakingVault).balance;

        // Setup: User deposits ETH which automatically triggers strategy execution
        vm.deal(user1, initialETH);

        uint256 reserveRatioBP = dashboard.reserveRatioBP();
        console.log("reserveRatioBP", reserveRatioBP);

        uint256 borrowRatio = lenderMock.BORROW_RATIO();
        console.log("borrowRatio", borrowRatio);

        // Deposit triggers automatic strategy execution since strategy is configured
        vm.prank(user1);
        uint256 user1StvShares = wrapperC.depositETH{value: initialETH}(user1);

        // Verify user received shares and strategy position was created
        assertEq(wrapperC.balanceOf(user1), user1StvShares, "user should have stvETH shares");
        
        // User should have a strategy position created
        uint256[] memory positions = wrapperC.getUserPositions(user1);
        assertEq(positions.length, 1, "user should have one strategy position");
        
        WrapperC.Position memory position = wrapperC.getPosition(positions[0]);
        assertEq(position.user, user1, "position should belong to user");
        assertTrue(position.isActive, "position should be active");
        assertFalse(position.isExiting, "position should not be exiting");
        
        // Verify strategy execution increased vault total assets
        uint256 totalAssetsAfterStrategy = wrapperC.totalAssets();
        assertTrue(totalAssetsAfterStrategy >= initialETH + initialVaultBalance, "totalAssets should be at least initial deposit + vault balance");
        
        assertTrue(user1StvShares >= initialETH - 1 && user1StvShares <= initialETH, "shares should be approximately equal to deposited amount");

        dwWithStrategy.logAllBalances("test_depositWithStrategyExecution", user1, user2);

        // Assert all logged balances
        uint256 totalBasisPoints = strategy.LENDER_MOCK().TOTAL_BASIS_POINTS(); // 10000

        uint256 mintedStETHShares0 = user1StvShares * (core.LIDO_TOTAL_BASIS_POINTS() - reserveRatioBP) / core.LIDO_TOTAL_BASIS_POINTS();
        uint256 borrowedEth0 = (mintedStETHShares0 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth0", borrowedEth0);

        uint256 user1StvShares1 = borrowedEth0;
        uint256 mintedStETHShares1 = user1StvShares1 * (core.LIDO_TOTAL_BASIS_POINTS() - reserveRatioBP) / core.LIDO_TOTAL_BASIS_POINTS();
        uint256 borrowedEth1 = (mintedStETHShares1 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth1", borrowedEth1);
    }


}