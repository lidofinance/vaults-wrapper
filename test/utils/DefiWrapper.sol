// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

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
import {Escrow} from "src/Escrow.sol";
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
    Escrow public escrow;
    ExampleStrategy public strategy;
    IStakingVault public stakingVault;
    IDashboard public dashboard;

    uint256 public constant STRATEGY_LOOPS = 2;
    uint256 public immutable CONNECT_DEPOSIT;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 1_00; // 1% in basis points
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    constructor(address _coreHarnessAddress) {
        CoreHarness core = CoreHarness(_coreHarnessAddress);

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

        stakingVault = IStakingVault(vaultAddress);
        vm.label(address(stakingVault), "StakingVault");

        // Set the dashboard in CoreHarness
        core.setDashboard(address(dashboard));

        // Apply initial vault report and set fee rate
        core.applyVaultReport(address(stakingVault), 0, 0, 0, true);
        dashboard.setNodeOperatorFeeRate(NODE_OPERATOR_FEE_RATE);

        wrapper = new Wrapper{value: 0 wei}(
            address(dashboard),
            address(0), // placeholder for escrow
            address(this), // initial balance owner
            "Staked ETH Vault Wrapper",
            "stvETH"
        );

        withdrawalQueue = new WithdrawalQueue(wrapper);
        withdrawalQueue.initialize(address(this));
        wrapper.setWithdrawalQueue(address(withdrawalQueue));
        withdrawalQueue.grantRole(withdrawalQueue.FINALIZE_ROLE(), address(this));
        withdrawalQueue.grantRole(withdrawalQueue.RESUME_ROLE(), address(this));
        withdrawalQueue.resume();

        address vaultOwner = core.vaultHub().vaultConnection(address(stakingVault)).owner;
        console.log("vaultOwner", vaultOwner);

        strategy = new ExampleStrategy(address(core.steth()), address(wrapper), STRATEGY_LOOPS);
        escrow = new Escrow(address(wrapper), address(strategy), address(core.steth()));
        wrapper.setEscrowAddress(address(escrow));
        // Fund the LenderMock contract with ETH so it can lend
        vm.deal(address(strategy.LENDER_MOCK()), 1234 ether);

        dashboard.grantRole(dashboard.FUND_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(wrapper));
        dashboard.grantRole(dashboard.MINT_ROLE(), address(escrow));
        dashboard.grantRole(dashboard.BURN_ROLE(), address(escrow));
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), address(withdrawalQueue));
    }

}