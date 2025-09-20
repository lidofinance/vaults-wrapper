// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLocator} from "src/interfaces/ILidoLocator.sol";
import {ILido} from "src/interfaces/ILido.sol";
import {ILazyOracle} from "src/interfaces/ILazyOracle.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub as IVaultHubIntact} from "src/interfaces/IVaultHub.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {IWstETH} from "../../src/interfaces/IWstETH.sol";

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

interface ILazyOracleMocked is ILazyOracle {
        function mock__updateVaultData(
        address _vault,
        uint256 _totalValue,
        uint256 _cumulativeLidoFees,
        uint256 _liabilityShares,
        uint256 _maxLiabilityShares,
        uint256 _slashingReserve) external;
}

contract CoreHarness is Test {
    ILidoLocator public locator;
    IDashboard public dashboard;
    ILido public steth;
    IWstETH public wsteth;
    IVaultHub public vaultHub;
    ILazyOracleMocked public lazyOracle;

    uint256 public constant INITIAL_LIDO_SUBMISSION = 1_000_000 ether;
    uint256 public constant CONNECT_DEPOSIT = 1 ether;
    uint256 public constant LIDO_TOTAL_BASIS_POINTS = 10000;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 1_00; // 1% in basis points

    address public constant BEACON_CHAIN = address(0xbeac0);

    constructor(string memory _deployedJsonPath) {
        vm.deal(address(this), 10000000 ether);

        string memory deployedJson = vm.readFile(_deployedJsonPath);
        locator = ILidoLocator(vm.parseJsonAddress(deployedJson, "$.lidoLocator.proxy.address"));
        vm.label(address(locator), "LidoLocator");

        address agent = vm.parseJsonAddress(deployedJson, "$.['app:aragon-agent'].proxy.address");
        vm.label(agent, "Agent");

        IACL acl = IACL(vm.parseJsonAddress(deployedJson, "$.aragon-acl.proxy.address"));
        vm.label(address(acl), "ACL");

        // Get LazyOracle address from the deployed contracts
        lazyOracle = ILazyOracleMocked(locator.lazyOracle());
        vm.label(address(lazyOracle), "LazyOracle");

        address hashConsensus = vm.parseJsonAddress(deployedJson, "$.hashConsensusForAccountingOracle.address");
        vm.label(hashConsensus, "HashConsensusForAO");
        vm.prank(agent);
        IHashConsensus(hashConsensus).updateInitialEpoch(1);

        steth = ILido(locator.lido());
        vm.label(address(steth), "Lido");

        wsteth = IWstETH(locator.wstETH());
        vm.label(address(wsteth), "WstETH");

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

        dashboard = IDashboard(payable(address(0))); // Will be set by DefiWrapper
        vm.label(address(dashboard), "Dashboard");

    }

    function setDashboard(address _dashboard) external {
        dashboard = IDashboard(payable(_dashboard));
        vm.label(address(dashboard), "Dashboard");
    }

    function applyVaultReport(address _stakingVault, uint256 _totalValue, uint256 _cumulativeLidoFees, uint256 _liabilityShares, uint256 _slashingReserve, bool _onlyUpdateReportData) public {
        uint256 reportTimestamp = block.timestamp;
        uint256 refSlot = block.timestamp / 12; // Simulate a slot number based on timestamp (12 second slots)
        bytes32 treeRoot = bytes32(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef);
        string memory reportCid = "dummy-cid";

        // uint256 reportCumulativeLidoFees = _cumulativeLidoFees;
        // uint256 reportLiabilityShares = 0;
        // uint256 reportSlashingReserve = 0;

        // bool isFresh = vaultHub.isReportFresh(_stakingVault);
        // console.log("isFresh before", isFresh);

        vm.warp(block.timestamp + 1 minutes);

        // Update report data with current timestamp to make it fresh
        vm.prank(locator.accountingOracle());
        lazyOracle.updateReportData(reportTimestamp, refSlot, treeRoot, reportCid);

        // TODO: remove _onlyUpdateReportData flag
        if (!_onlyUpdateReportData) {
            uint256 maxLiabilityShares = vaultHub.vaultRecord(_stakingVault).maxLiabilityShares;
            console.log("Calling mock__updateVaultData with totalValue:", _totalValue);
            lazyOracle.mock__updateVaultData(_stakingVault, _totalValue, _cumulativeLidoFees, _liabilityShares, maxLiabilityShares, _slashingReserve);
            console.log("After mock__updateVaultData, totalValue from vaultHub:", vaultHub.totalValue(_stakingVault));
        }

        bool isFreshAfter = vaultHub.isReportFresh(_stakingVault);
        assert(isFreshAfter);
        // console.log("isFresh after", isFreshAfter);
    }

    /**
     * @dev Mock function to simulate validators receiving ETH from the staking vault
     * This replaces the manual beacon chain transfer simulation in tests
     */
    function mockValidatorsReceiveETH(address _stakingVault) external returns (uint256 transferredAmount) {
        transferredAmount = _stakingVault.balance;
        if (transferredAmount > 0) {
            vm.prank(_stakingVault);
            (bool sent, ) = BEACON_CHAIN.call{value: transferredAmount}("");
            require(sent, "ETH send to beacon chain failed");
        }
        return transferredAmount;
    }

    /**
     * @dev Mock function to simulate validator exits returning ETH to the staking vault
     * This replaces the manual ETH return simulation in tests
     */
    function mockValidatorExitReturnETH(address _stakingVault, uint256 _ethAmount) external {
        vm.prank(BEACON_CHAIN);
        (bool success, ) = _stakingVault.call{value: _ethAmount}("");
        require(success, "ETH return from beacon chain failed");
    }

    function setStethShareRatio(uint256 _shareRatioE18) external {
        uint256 totalSupply = steth.totalSupply();
        uint256 totalShares = steth.getTotalShares();

        uint256 a = Math.mulDiv(totalSupply, 1 ether, _shareRatioE18, Math.Rounding.Floor);
        int128 sharesDiff = int128(uint128(a)) - int128(uint128(totalShares));

        if (sharesDiff > 0) {
            vm.prank(locator.accounting());
            steth.mintShares(address(this), uint256(uint128(sharesDiff)));
        } else if (sharesDiff < 0) {
            uint256 sharesToBurn = uint256(uint128(-sharesDiff));
            steth.transferShares(locator.burner(), sharesToBurn);
            vm.prank(locator.burner());
            steth.burnShares(sharesToBurn);
        }

        require(steth.getPooledEthByShares(1 ether) == _shareRatioE18, "Failed to mock steth share ratio");

    }
}