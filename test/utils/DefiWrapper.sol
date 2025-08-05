// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {Wrapper} from "src/Wrapper.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {ExampleStrategy, LenderMock} from "src/ExampleStrategy.sol";

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


// TODO: replace it partially by the factory
contract DefiWrapper is Test {
    Wrapper public wrapper;
    WithdrawalQueue public withdrawalQueue;
    ExampleStrategy public strategy;
    IStakingVault public vault;
    IDashboard public dashboard;
    CoreHarness public core;

    uint256 public constant STRATEGY_LOOPS = 2;
    uint256 public immutable CONNECT_DEPOSIT;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 1_00; // 1% in basis points
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    constructor(address _coreHarnessAddress) {
        core = CoreHarness(_coreHarnessAddress);

        CONNECT_DEPOSIT = core.vaultHub().CONNECT_DEPOSIT();

        // Fund this contract for vault creation
        vm.deal(address(this), 10 ether);

        // Create the staking vault using VaultFactory
        IVaultFactory vaultFactory = IVaultFactory(core.locator().vaultFactory());

        (address vaultAddress, address dashboardAddress) = vaultFactory.createVaultWithDashboard{value: CONNECT_DEPOSIT}(
            address(this),
            address(this),
            address(this),
            0,
            CONFIRM_EXPIRY,
            new IVaultFactory.RoleAssignment[](0)
        );

        dashboard = IDashboard(payable(dashboardAddress));
        vm.label(address(dashboard), "Dashboard");

        vault = IStakingVault(vaultAddress);
        vm.label(address(vault), "StakingVault");

        // Set the dashboard in CoreHarness
        core.setDashboard(address(dashboard));

        // Apply initial vault report and set fee rate
        core.applyVaultReport(address(vault), 0, 0, 0, true);
        dashboard.setNodeOperatorFeeRate(NODE_OPERATOR_FEE_RATE);

        strategy = new ExampleStrategy(address(core.steth()), address(0), STRATEGY_LOOPS);

        wrapper = new Wrapper(
            address(dashboard),
            address(this), // initial balance owner
            "Staked ETH Vault Wrapper",
            "stvETH",
            false, // whitelist disabled
            true, // minting allowed
            address(strategy)
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);
        withdrawalQueue.initialize(address(this));
        wrapper.setWithdrawalQueue(address(withdrawalQueue));
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), address(this));
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), address(this));
        withdrawalQueue.resume();

        address vaultOwner = core.vaultHub().vaultConnection(address(vault)).owner;
        console.log("vaultOwner", vaultOwner);

        // Update strategy's wrapper reference now that wrapper is deployed
        strategy = new ExampleStrategy(address(core.steth()), address(wrapper), STRATEGY_LOOPS);
        wrapper.setStrategy(address(strategy));

        // Fund the LenderMock contract with ETH so it can lend
        vm.deal(address(strategy.LENDER_MOCK()), 1234 ether);

        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.MINT_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.BURN_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));
    }

    function stakingVault() external view returns (IStakingVault) {
        return vault;
    }

    function logAllBalances(string memory _context, address _user1, address _user2) external view {
        address stETH = address(core.steth());
        address lenderMock = address(strategy.LENDER_MOCK());
        address user1 = _user1;
        address user2 = _user2;

        console.log("");
        console.log("=== Balances ===", _context);

        console.log(
            string.concat(
                "user1: ETH=", vm.toString(user1.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user1)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user1)),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(user1))
            )
        );

        console.log(
            string.concat(
                "user2: ETH=", vm.toString(user2.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(user2)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(user2)),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(user2))
            )
        );

        console.log(
            string.concat(
                "wrapper: ETH=", vm.toString(address(wrapper).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(wrapper))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(wrapper))),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(address(wrapper)))
            )
        );

        // Escrow functionality is now in wrapper, no separate escrow to log

        console.log(
            string.concat(
                "strategy: ETH=", vm.toString(address(strategy).balance),
                " stvETH=", vm.toString(wrapper.balanceOf(address(strategy))),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(address(strategy))),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(address(strategy)))
            )
        );

        console.log(
            string.concat(
                "stakingVault: ETH=", vm.toString(address(vault).balance),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(address(vault)))
            )
        );
        console.log(
            string.concat(
                "LenderMock: ETH=", vm.toString(lenderMock.balance),
                " stvETH=", vm.toString(wrapper.balanceOf(lenderMock)),
                " stETH=", vm.toString(IERC20(stETH).balanceOf(lenderMock)),
                " lockedStv=", vm.toString(wrapper.lockedStvSharesByUser(lenderMock))
            )
        );

        // Wrapper totals (previously Escrow totals)
        console.log(
            string.concat(
                "Wrapper totals: totalBorrowedAssets=", vm.toString(wrapper.totalBorrowedAssets()),
                " totalLockedStvShares=", vm.toString(wrapper.totalLockedStvShares())
            )
        );
    }
}
