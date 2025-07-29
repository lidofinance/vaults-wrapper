// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ILidoLocator} from "lido-core/contracts/common/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";

import {Wrapper} from "src/Wrapper.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {Escrow} from "src/Escrow.sol";
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IHashConsensus {
    function updateInitialEpoch(uint256 initialEpoch) external;
}

interface IACL {
    function grantPermission(address _entity, address _app, bytes32 _role) external;
    function grantRole(bytes32 role, address account) external;
    function createPermission(address _entity, address _app, bytes32 _role, address _manager) external;
    function setPermissionManager(address _newManager, address _app, bytes32 _role) external;
}

interface IVaultHub is IVaultHubIntact {
    function mock__setReportIsAlwaysFresh(bool _reportIsAlwaysFresh) external;
}

contract StVaultWrapperV3Test is Test {
    ILidoLocator public locator;
    Wrapper public wrapper;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    WithdrawalQueue public withdrawalQueue;
    Escrow public escrow;
    ExampleStrategy public strategy;

    // uint256 public constant THE_STONE = 10 wei;
    uint256 public constant INITIAL_LIDO_SUBMISSION = 10_000 ether;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;
    uint256 public constant LIDO_TOTAL_BASIS_POINTS = 10000;

    address public agent;
    address public hashConsensus;

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    event VaultFunded(uint256 amount);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);

    function setUp() public {
        vm.deal(address(this), 10000000 ether);

        string memory deployedJson = vm.readFile("lido-core/deployed-local.json");
        locator = ILidoLocator(vm.parseJsonAddress(deployedJson, "$.lidoLocator.proxy.address"));
        vm.label(address(locator), "LidoLocator");

        agent = vm.parseJsonAddress(deployedJson, "$.['app:aragon-agent'].proxy.address");
        vm.label(agent, "Agent");

        hashConsensus = vm.parseJsonAddress(deployedJson, "$.hashConsensusForAccountingOracle.address");
        vm.label(hashConsensus, "HashConsensusForAO");
        vm.prank(agent);
        IHashConsensus(hashConsensus).updateInitialEpoch(1);

        steth = ILido(locator.lido());
        vm.label(address(steth), "Lido");

        vm.prank(agent);
        steth.setMaxExternalRatioBP(LIDO_TOTAL_BASIS_POINTS);

        vm.prank(agent);
        steth.resume();

        // Need some ether in Lido to pass ShareLimitTooHigh check upon vault creation/connection
        steth.submit{value: INITIAL_LIDO_SUBMISSION}(address(this));

        vaultHub = IVaultHub(locator.vaultHub());
        vm.label(address(vaultHub), "VaultHub");

        IVaultFactory vaultFactory = IVaultFactory(locator.vaultFactory());
        vm.label(address(vaultFactory), "VaultFactory");

        assertEq(vaultHub.CONNECT_DEPOSIT(), CONNECT_DEPOSIT, "CONNECT_DEPOSIT wrong constant");

        uint256 confirmExpiry = 1 hours;
        (address vaultAddress, address dashboardAddress) = vaultFactory.createVaultWithDashboard{value: CONNECT_DEPOSIT}(
            address(this),
            address(this),
            address(this),
            0,
            confirmExpiry,
            new IVaultFactory.RoleAssignment[](0)
        );

        dashboard = IDashboard(payable(dashboardAddress));
        vm.label(address(dashboard), "Dashboard");

        stakingVault = IStakingVault(vaultAddress);
        vm.label(address(stakingVault), "StakingVault");

        wrapper = new Wrapper{value: 0 wei}(
            address(dashboard),
            address(0), // placeholder for escrow
            "Staked ETH Vault Wrapper",
            "stvETH"
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);

        wrapper.setWithdrawalQueue(address(withdrawalQueue));

        address vaultOwner = vaultHub.vaultConnection(address(stakingVault)).owner;
        console.log("vaultOwner", vaultOwner);

        vm.prank(vaultOwner);
        vaultHub.mock__setReportIsAlwaysFresh(true);

        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));


        uint256 strategyLoops = 2;
        strategy = new ExampleStrategy(address(steth), address(wrapper), strategyLoops);

        escrow = new Escrow(address(wrapper), address(withdrawalQueue), address(strategy), address(steth));
        wrapper.setEscrowAddress(address(escrow));

        // TODO: make escrow mint
        dashboard.grantRole(dashboard.MINT_ROLE(), address(escrow));

        // Fund the LenderMock contract with ETH so it can lend
        vm.deal(address(strategy.LENDER_MOCK()), 1234 ether);

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);

        IACL acl = IACL(vm.parseJsonAddress(deployedJson, "$.aragon-acl.proxy.address"));
        vm.label(address(acl), "ACL");

    }

    function test_deposit() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 15_000 wei;
        uint256 initialVaultBalance = wrapper.INITIAL_VAULT_BALANCE();
        assertEq(initialVaultBalance, CONNECT_DEPOSIT, "initialVaultBalance should be equal to CONNECT_DEPOSIT");

        // Setup: User1 deposits ETH and gets stvToken shares
        vm.deal(user1, user1InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        uint256 ethAfterFirstDeposit = user1InitialETH; // CONNECT_DEPOSIT is ignored in totalAssets

        // Main invariants for user1 deposit
        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit, "wrapper totalAssets should match deposited ETH");
        assertEq(address(stakingVault).balance, ethAfterFirstDeposit + initialVaultBalance, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares, "wrapper totalSupply should equal user shares");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should have no shares initially");
        assertEq(user1StvShares, user1InitialETH, "shares should equal deposited amount (1:1 ratio)");
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked initially");

        // Setup: User2 deposits different amount of ETH
        vm.deal(user2, user2InitialETH);

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        uint256 ethAfterBothDeposits = totalDeposits;

        // Main invariants for multi-user deposits
        assertEq(user2.balance, 0, "user2 ETH balance should be zero after deposit");
        assertEq(wrapper.totalLockedStvShares(), 0, "no shares should be locked with multiple users");
        assertEq(wrapper.totalAssets(), ethAfterBothDeposits, "wrapper totalAssets should match both deposits");
        assertEq(address(stakingVault).balance, ethAfterBothDeposits + initialVaultBalance, "stakingVault balance should match total assets");
        assertEq(wrapper.totalSupply(), user1StvShares + user2StvShares, "wrapper totalSupply should equal sum of user shares");
        assertEq(wrapper.balanceOf(user1), user1StvShares, "user1 balance should remain unchanged");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should equal returned shares");
        assertEq(wrapper.balanceOf(address(escrow)), 0, "escrow should still have no shares");

        // For ERC4626, shares = assets * totalSupply / totalAssets
        // After first deposit: totalSupply = user1InitialETH, totalAssets = ethAfterFirstDeposit
        // User2's shares = user2InitialETH * user1StvShares / ethAfterFirstDeposit
        uint256 expectedUser2Shares = user2InitialETH * user1StvShares / ethAfterFirstDeposit;
        assertEq(user2StvShares, expectedUser2Shares, "user2 shares should follow ERC4626 formula");

        // Verify share-to-asset conversion works correctly for both users
        assertEq(wrapper.convertToAssets(user1StvShares), user1InitialETH, "user1 assets should be equal to its initial deposit");
        assertEq(wrapper.convertToAssets(user2StvShares), user2InitialETH, "user2 assets should be equal to its initial deposit");
        assertEq(wrapper.convertToAssets(user1StvShares + user2StvShares), user1InitialETH + user2InitialETH, "sum of user assets should be equal to sum of initial deposits");
        assertEq(wrapper.convertToAssets(user1StvShares) + wrapper.convertToAssets(user2StvShares), user1InitialETH + user2InitialETH, "sum of user assets should be equal to sum of initial deposits");

        // Setup: User1 makes a second deposit
        uint256 user1SecondDeposit = 1_000 wei;
        vm.deal(user1, user1SecondDeposit);

        uint256 totalSupplyBeforeSecond = wrapper.totalSupply();
        uint256 totalAssetsBeforeSecond = wrapper.totalAssets();

        vm.prank(user1);
        uint256 user1SecondShares = wrapper.depositETH{value: user1SecondDeposit}();

        uint256 totalDepositsAfterSecond = totalDeposits + user1SecondDeposit;
        uint256 user1TotalShares = user1StvShares + user1SecondShares;

        // Main invariants after user1's second deposit
        assertEq(user1.balance, 0, "user1 ETH balance should be zero after second deposit");
        assertEq(wrapper.totalAssets(), totalDepositsAfterSecond, "wrapper totalAssets should include second deposit");
        assertEq(address(stakingVault).balance, totalDepositsAfterSecond + initialVaultBalance, "stakingVault balance should include second deposit");
        assertEq(wrapper.totalSupply(), totalSupplyBeforeSecond + user1SecondShares, "totalSupply should increase by second shares");
        assertEq(wrapper.balanceOf(user1), user1TotalShares, "user1 balance should be sum of both deposits' shares");
        assertEq(wrapper.balanceOf(user2), user2StvShares, "user2 balance should remain unchanged");

        // ERC4626 calculation for user1's second deposit
        uint256 expectedUser1SecondShares = user1SecondDeposit * totalSupplyBeforeSecond / totalAssetsBeforeSecond;
        assertEq(user1SecondShares, expectedUser1SecondShares, "user1 second shares should follow ERC4626 formula");

        // Verify final share-to-asset conversions
        uint256 user1ExpectedAssets = user1InitialETH + user1SecondDeposit;
        assertEq(wrapper.convertToAssets(user1TotalShares), user1ExpectedAssets, "user1 total assets should equal both deposits");
        assertEq(wrapper.convertToAssets(user2StvShares), user2InitialETH, "user2 assets should remain unchanged");
        assertEq(wrapper.convertToAssets(wrapper.totalSupply()), totalDepositsAfterSecond, "total assets should equal all deposits");
    }

    function test_openClosePositionSingleUser() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();

        // Setup: User deposits ETH and gets stvToken shares
        vm.deal(user1, initialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: initialETH}();

        uint256 ethAfterFirstDeposit = initialETH;

        assertEq(wrapper.totalAssets(), ethAfterFirstDeposit);
        assertEq(address(stakingVault).balance - wrapper.INITIAL_VAULT_BALANCE(), ethAfterFirstDeposit);
        assertEq(wrapper.totalSupply(), user1StvShares);
        assertEq(wrapper.balanceOf(user1), user1StvShares);
        assertEq(wrapper.balanceOf(address(escrow)), 0);
        assertEq(user1StvShares, initialETH);

        uint256 reserveRatioBP = dashboard.reserveRatioBP();
        console.log("reserveRatioBP", reserveRatioBP);

        uint256 borrowRatio = lenderMock.BORROW_RATIO();
        console.log("borrowRatio", borrowRatio);

        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        escrow.openPosition(user1StvShares);
        vm.stopPrank();

        logAllBalances(4);

        // Assert all logged balances
        uint256 totalBasisPoints = strategy.LENDER_MOCK().TOTAL_BASIS_POINTS(); // 10000

        uint256 mintedStETHShares0 = user1StvShares * (LIDO_TOTAL_BASIS_POINTS - reserveRatioBP) / LIDO_TOTAL_BASIS_POINTS;
        uint256 borrowedEth0 = (mintedStETHShares0 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth0", borrowedEth0);

        uint256 user1StvShares1 = borrowedEth0;
        uint256 mintedStETHShares1 = user1StvShares1 * (LIDO_TOTAL_BASIS_POINTS - reserveRatioBP) / LIDO_TOTAL_BASIS_POINTS;
        uint256 borrowedEth1 = (mintedStETHShares1 * borrowRatio) / totalBasisPoints;
        console.log("borrowedEth1", borrowedEth1);
    }

    function xtest_openClosePositionTwoUsers() public {
        uint256 user1InitialETH = 10_000 wei;
        uint256 user2InitialETH = 15_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();

        // Setup: Both users deposit different amounts of ETH and get stvToken shares
        vm.deal(user1, user1InitialETH);
        vm.deal(user2, user2InitialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: user1InitialETH}();

        vm.prank(user2);
        uint256 user2StvShares = wrapper.depositETH{value: user2InitialETH}();

        uint256 totalDeposits = user1InitialETH + user2InitialETH;
        assertEq(wrapper.totalAssets(), totalDeposits + CONNECT_DEPOSIT, "wrapper totalAssets should equal both deposits");
        assertEq(wrapper.totalSupply(), user1StvShares + user2StvShares, "wrapper totalSupply should equal both users' shares");
        assertEq(address(stakingVault).balance, totalDeposits + CONNECT_DEPOSIT, "stakingVault ETH balance should equal both deposits");

        uint256 reserveRatioBP = dashboard.reserveRatioBP();
        console.log("reserveRatioBP", reserveRatioBP);

        uint256 borrowRatio = lenderMock.BORROW_RATIO();
        console.log("borrowRatio", borrowRatio);

        // User1 opens position
        vm.startPrank(user1);
        wrapper.approve(address(escrow), user1StvShares);
        escrow.openPosition(user1StvShares);
        vm.stopPrank();

        logAllBalances(1);

        // User2 opens position
        vm.startPrank(user2);
        wrapper.approve(address(escrow), user2StvShares);
        escrow.openPosition(user2StvShares);
        vm.stopPrank();

        logAllBalances(2);

        // Assert both users have locked shares
        assertGt(escrow.lockedStvSharesByUser(user1), 0, "user1 should have locked shares");
        assertGt(escrow.lockedStvSharesByUser(user2), 0, "user2 should have locked shares");

        // Verify total locked shares equals sum of individual locked shares
        uint256 totalLocked = wrapper.totalLockedStvShares();
        uint256 user1Locked = escrow.lockedStvSharesByUser(user1);
        uint256 user2Locked = escrow.lockedStvSharesByUser(user2);
        assertEq(totalLocked, user1Locked + user2Locked, "total locked should equal sum of user locked shares");
    }

    function logAllBalances(uint256 _context) public view {
        address stETH = address(strategy.STETH());
        address lenderMock = address(strategy.LENDER_MOCK());

        console.log("");
        console.log("=== Balances ===", _context);

        console.log(
            string.concat(
                "user1: ETH=", vm.toString(user1.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user1)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user1)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(user1))
            )
        );

        console.log(
            string.concat(
                "user2: ETH=", vm.toString(user2.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user2)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user2)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(user2))
            )
        );

        console.log(
            string.concat(
                "wrapper: ETH=", vm.toString(address(wrapper).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(wrapper))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(wrapper))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(wrapper)))
            )
        );

        console.log(
            string.concat(
                "escrow: ETH=", vm.toString(address(escrow).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(escrow))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(escrow))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(escrow)))
            )
        );

        console.log(
            string.concat(
                "strategy: ETH=", vm.toString(address(strategy).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(strategy))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(strategy))),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(strategy)))
            )
        );

        console.log(
            string.concat(
                "stakingVault: ETH=", vm.toString(address(stakingVault).balance),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(address(stakingVault)))
            )
        );
        console.log(
            string.concat(
                "LenderMock: ETH=", vm.toString(lenderMock.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(lenderMock)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(lenderMock)),
                " lockedStv=", vm.toString(escrow.lockedStvSharesByUser(lenderMock))
            )
        );

        // Escrow totals
        console.log(
            string.concat(
                "Escrow totals: totalBorrowedAssets=", vm.toString(escrow.totalBorrowedAssets()),
                " totalLockedStvShares=", vm.toString(wrapper.totalLockedStvShares())
            )
        );
    }

}