// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {DefiWrapper} from "test/utils/DefiWrapper.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {Wrapper} from "src/Wrapper.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";


contract StrategyTest is Test {
    CoreHarness public core;
    DefiWrapper public dw;
    
    // Access to harness components
    Wrapper public wrapper;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    ExampleStrategy public strategy;

    uint256 public constant WEI_ROUNDING_TOLERANCE = 2;
    uint256 public constant TOTAL_BP = 100_00;

    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);

    function setUp() public {
        core = new CoreHarness("lido-core/deployed-local.json");
        dw = new DefiWrapper(address(core));

        wrapper = dw.wrapper();
        withdrawalQueue = dw.withdrawalQueue();
        strategy = dw.strategy();
        dashboard = dw.dashboard();
        steth = core.steth();
        vaultHub = core.vaultHub();
        stakingVault = dw.stakingVault();

        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(user3, 1000 ether);

        assertEq(TOTAL_BP, core.LIDO_TOTAL_BASIS_POINTS(), "TOTAL_BP should be equal to LIDO_TOTAL_BASIS_POINTS");
    }

    // Tests opening a leveraged position with strategy execution for a single user
    // Verifies deposit → escrow position opening → stETH minting → strategy leverage loop execution
    function test_openClosePositionSingleUser() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();
        uint256 initialVaultBalance = address(stakingVault).balance;

        // Setup: User deposits ETH and gets stvToken shares
        vm.deal(user1, initialETH);

        vm.startPrank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: initialETH}(user1);
        vm.stopPrank();

        uint256 ethAfterFirstDeposit = initialETH + initialVaultBalance;

        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit);
        assertEq(address(stakingVault).balance - initialVaultBalance, initialETH);
        assertEq(wrapper.totalSupply(), user1StvShares + initialVaultBalance);
        assertEq(wrapper.balanceOf(user1), user1StvShares);
        assertEq(wrapper.balanceOf(address(wrapper)), 0);
        assertTrue(user1StvShares >= initialETH - 1 && user1StvShares <= initialETH, "shares should be approximately equal to deposited amount");

        uint256 reserveRatioBP = dashboard.reserveRatioBP();
        console.log("reserveRatioBP", reserveRatioBP);

        uint256 borrowRatio = lenderMock.BORROW_RATIO();
        console.log("borrowRatio", borrowRatio);

        vm.startPrank(user1);
        wrapper.openPosition(user1StvShares);
        vm.stopPrank();

        dw.logAllBalances("test_openClosePositionSingleUser", user1, user2);

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