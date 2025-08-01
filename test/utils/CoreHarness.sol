// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {ILidoLocator} from "lido-core/contracts/common/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";


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

contract CoreHarness is Test {
    ILidoLocator public locator;
    IDashboard public dashboard;
    ILido public steth;
    IVaultHub public vaultHub;
    IStakingVault public stakingVault;
    ILazyOracle public lazyOracle;

    uint256 public constant INITIAL_LIDO_SUBMISSION = 10_000 ether;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;
    uint256 public constant LIDO_TOTAL_BASIS_POINTS = 10000;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 1_00; // 1% in basis points

    address public agent;
    address public hashConsensus;

    constructor(string memory deployedJsonPath) {
        vm.deal(address(this), 10000000 ether);

        string memory deployedJson = vm.readFile(deployedJsonPath);
        locator = ILidoLocator(vm.parseJsonAddress(deployedJson, "$.lidoLocator.proxy.address"));
        vm.label(address(locator), "LidoLocator");

        agent = vm.parseJsonAddress(deployedJson, "$.['app:aragon-agent'].proxy.address");
        vm.label(agent, "Agent");

        IACL acl = IACL(vm.parseJsonAddress(deployedJson, "$.aragon-acl.proxy.address"));
        vm.label(address(acl), "ACL");

        // Get LazyOracle address from the deployed contracts
        lazyOracle = ILazyOracle(locator.lazyOracle());
        vm.label(address(lazyOracle), "LazyOracle");

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

        address vaultOwner = vaultHub.vaultConnection(address(stakingVault)).owner;
        console.log("vaultOwner", vaultOwner);

        vm.prank(vaultOwner);
        vaultHub.mock__setReportIsAlwaysFresh(true);

        applyVaultReport(0, 0, 0);
        dashboard.setNodeOperatorFeeRate(NODE_OPERATOR_FEE_RATE);
    }

    function grantWrapperRoles(address wrapper, address escrow) external {
        dashboard.grantRole(dashboard.FUND_ROLE(), wrapper);
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), wrapper);

        dashboard.grantRole(dashboard.MINT_ROLE(), escrow);
        dashboard.grantRole(dashboard.BURN_ROLE(), escrow);
    }

    function grantWithdrawalQueueRoles(address withdrawalQueue) external {
        dashboard.grantRole(dashboard.WITHDRAW_ROLE(), withdrawalQueue);
    }

    function applyVaultReport(uint256 _totalValue, uint256 _totalValueIncreaseBP, uint256 _cumulativeLidoFees) public {
        uint256 reportTimestamp = block.timestamp;
        uint256 refSlot = 0;
        bytes32 treeRoot = bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef);
        string memory reportCid = "dummy-cid";

        uint256 reportTotalValue = _totalValue + (_totalValue * _totalValueIncreaseBP) / 10000;
        int256 reportInOutDelta = int256((_totalValue * _totalValueIncreaseBP) / 10000);
        uint256 reportCumulativeLidoFees = _cumulativeLidoFees;
        uint256 reportLiabilityShares = 0;
        uint256 reportSlashingReserve = 0;

        vm.prank(locator.accountingOracle());
        lazyOracle.updateReportData(reportTimestamp, refSlot, treeRoot, reportCid);

        vm.prank(address(lazyOracle));
        vaultHub.applyVaultReport(
            address(stakingVault),
            reportTimestamp,
            reportTotalValue,
            reportInOutDelta,
            reportCumulativeLidoFees,
            reportLiabilityShares,
            reportSlashingReserve
        );
    }
}