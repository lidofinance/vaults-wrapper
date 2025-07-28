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
    function setReportIsAlwaysFreshFor(address _vault) external;
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

        // TODO: set setMaxExternalRatioBP here but LidoTemplate
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
        vaultHub.setReportIsAlwaysFreshFor(address(stakingVault));

        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));


        uint256 strategyLoops = 2;
        strategy = new ExampleStrategy(address(steth), address(wrapper), strategyLoops);

        escrow = new Escrow(address(wrapper), address(withdrawalQueue), address(strategy), address(steth));
        wrapper.setEscrowAddress(address(escrow));

        // TODO: make escrow mint
        dashboard.grantRole(dashboard.MINT_ROLE(), address(escrow));
        dashboard.grantRole(dashboard.MINT_ROLE(), address(wrapper));

        // Fund the LenderMock contract with ETH so it can lend
        vm.deal(address(strategy.LENDER_MOCK()), 1234 ether);

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);

        IACL acl = IACL(vm.parseJsonAddress(deployedJson, "$.aragon-acl.proxy.address"));
        vm.label(address(acl), "ACL");


    }

    function test_openClosePosition() public {
        uint256 initialETH = 10_000 wei;
        LenderMock lenderMock = strategy.LENDER_MOCK();

        // Setup: User deposits ETH and gets stvToken shares
        vm.deal(user1, initialETH);

        vm.prank(user1);
        uint256 user1StvShares = wrapper.depositETH{value: initialETH}();

        assertEq(wrapper.totalAssets(), initialETH + CONNECT_DEPOSIT, "wrapper totalAssets should equal initial deposit");
        assertEq(wrapper.totalSupply(), user1StvShares, "wrapper totalSupply should equal user1StvShares");
        assertEq(address(stakingVault).balance, initialETH + CONNECT_DEPOSIT, "stakingVault ETH balance should equal initial deposit");

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

    function logAllBalances(uint256 _context) public view {
        address stETH = address(strategy.STETH());
        address lenderMock = address(strategy.LENDER_MOCK());

        console.log("");
        console.log("=== Balances ===", _context);

        console.log(
            string.concat(
                "user1: ETH=", vm.toString(user1.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user1)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user1))
            )
        );

        console.log(
            string.concat(
                "wrapper: ETH=", vm.toString(address(wrapper).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(wrapper))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(wrapper)))
            )
        );

        console.log(
            string.concat(
                "strategy: ETH=", vm.toString(address(strategy).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(strategy))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(strategy)))
            )
        );

        console.log("stakingVault: ETH=", vm.toString(address(stakingVault).balance));
        console.log(
            string.concat(
                "LenderMock: ETH=", vm.toString(lenderMock.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(lenderMock)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(lenderMock))
            )
        );
    }

}