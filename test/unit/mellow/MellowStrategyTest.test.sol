// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {AllowList} from "src/AllowList.sol";
import {StvStETHPool} from "src/StvStETHPool.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";

import {IStrategy} from "src/interfaces/IStrategy.sol";

import {IWstETH} from "src/interfaces/core/IWstETH.sol";

import {IDepositQueue} from "src/interfaces/mellow/IDepositQueue.sol";
import {IFeeManager} from "src/interfaces/mellow/IFeeManager.sol";
import {IOracle} from "src/interfaces/mellow/IOracle.sol";
import {IQueue} from "src/interfaces/mellow/IQueue.sol";
import {IRedeemQueue} from "src/interfaces/mellow/IRedeemQueue.sol";
import {IShareManager} from "src/interfaces/mellow/IShareManager.sol";
import {ISyncDepositQueue} from "src/interfaces/mellow/ISyncDepositQueue.sol";
import {IVault} from "src/interfaces/mellow/IVault.sol";
import {IVaultConfigurator} from "src/interfaces/mellow/IVaultConfigurator.sol";

import {GGVStrategy} from "src/strategy/GGVStrategy.sol";
import {MellowStrategy} from "src/strategy/MellowStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";
import {StrategyCallForwarderRegistry} from "src/strategy/StrategyCallForwarderRegistry.sol";

import {FeaturePausable} from "src/utils/FeaturePausable.sol";

import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockMellowQueue} from "test/mocks/MockMellowQueue.sol";
import {MockStETH} from "test/mocks/MockStETH.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {MockWstETH} from "test/mocks/MockWstETH.sol";

import {console} from "forge-std/console.sol";

contract MellowStrategyTest is Test {
    struct DeployParams {
        bool allowList;
        bool withReport;
        bool withAsyncQueue;
        bool withSyncQueue;
    }

    // Assets
    address public eth = address(type(uint160).max / 0xf * 0xe);
    address public wsteth;

    // Lido contracts
    StvStETHPool public pool;
    MockDashboard public dashboard;
    MockVaultHub public vaultHub;
    address public withdrawalQueue = makeAddr("withdrawalQueue");

    // Mellow contracts
    MellowStrategy public strategyImplementation;
    MellowStrategy public strategy;
    address public vault;
    address public shareManager;

    address public asyncDepositEthQueue;
    address public syncDepositEthQueue;
    address public asyncRedeemEthQueue;
    address public asyncDepositWstethQueue;
    address public syncDepositWstethQueue;
    address public asyncRedeemWstethQueue;

    // Actors
    address public vaultAdmin = makeAddr("vaultAdmin");

    // Permissions
    bytes32 public constant SUBMIT_REPORTS_ROLE = keccak256("oracles.Oracle.SUBMIT_REPORTS_ROLE");
    bytes32 public constant ACCEPT_REPORT_ROLE = keccak256("oracles.Oracle.ACCEPT_REPORT_ROLE");
    bytes32 public constant SET_SECURITY_PARAMS_ROLE = keccak256("oracles.Oracle.SET_SECURITY_PARAMS_ROLE");
    bytes32 public constant SET_HOOK_ROLE = keccak256("modules.ShareModule.SET_HOOK_ROLE");
    bytes32 public constant CREATE_QUEUE_ROLE = keccak256("modules.ShareModule.CREATE_QUEUE_ROLE");
    bytes32 public constant SET_QUEUE_STATUS_ROLE = keccak256("modules.ShareModule.SET_QUEUE_STATUS_ROLE");
    bytes32 public constant SET_QUEUE_LIMIT_ROLE = keccak256("modules.ShareModule.SET_QUEUE_LIMIT_ROLE");
    bytes32 public constant REMOVE_QUEUE_ROLE = keccak256("modules.ShareModule.REMOVE_QUEUE_ROLE");

    // Constants
    uint256 public constant INITIAL_DEPOSIT = 1 ether;
    uint256 public constant RESERVE_RATIO_GAP_BP = 5_00; // 5%

    function _deployMellowVault(bool withReport) internal {
        if (block.chainid != 1 || block.number < 24307000) {
            vm.skip(true);
        }

        address[] memory assets = new address[](2);
        assets[0] = address(eth);
        assets[1] = address(wsteth);
        vm.startPrank(vaultAdmin);

        uint256 i = 0;
        IVault.RoleHolder[] memory holders = new IVault.RoleHolder[](15);
        holders[i++] = IVault.RoleHolder(SUBMIT_REPORTS_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(ACCEPT_REPORT_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(SET_SECURITY_PARAMS_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(SET_HOOK_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(CREATE_QUEUE_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(SET_QUEUE_STATUS_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(SET_QUEUE_LIMIT_ROLE, vaultAdmin);
        holders[i++] = IVault.RoleHolder(REMOVE_QUEUE_ROLE, vaultAdmin);
        assembly {
            mstore(holders, i)
        }

        IVaultConfigurator.InitParams memory initParams = IVaultConfigurator.InitParams({
            version: 0,
            proxyAdmin: vaultAdmin,
            vaultAdmin: vaultAdmin,
            shareManagerVersion: 0,
            shareManagerParams: abi.encode(bytes32(0), "TestVault", "tv"),
            feeManagerVersion: 0,
            feeManagerParams: abi.encode(vaultAdmin, vaultAdmin, uint24(0), uint24(0), uint24(0), uint24(0)),
            riskManagerVersion: 0,
            riskManagerParams: abi.encode(type(int256).max / 2),
            oracleVersion: 0,
            oracleParams: abi.encode(
                IOracle.SecurityParams({
                    maxAbsoluteDeviation: type(uint224).max,
                    suspiciousAbsoluteDeviation: type(uint224).max,
                    maxRelativeDeviationD18: 1 ether,
                    suspiciousRelativeDeviationD18: 1 ether,
                    timeout: 1,
                    depositInterval: 1,
                    redeemInterval: 1
                }),
                assets
            ),
            defaultDepositHook: address(0),
            defaultRedeemHook: address(0),
            queueLimit: 50,
            roleHolders: holders
        });

        address configurator = 0x000000028be48f9E62E13403480B60C4822C5aa5;
        (shareManager,,,, vault) = IVaultConfigurator(configurator).create(initParams);

        IVault(vault).createQueue(0, true, vaultAdmin, eth, "");
        asyncDepositEthQueue = IVault(vault).queueAt(eth, 0);
        IVault(vault).createQueue(0, true, vaultAdmin, wsteth, "");
        asyncDepositWstethQueue = IVault(vault).queueAt(wsteth, 0);

        IVault(vault).createQueue(2, true, vaultAdmin, eth, abi.encode(0, 24 hours));
        syncDepositEthQueue = IVault(vault).queueAt(eth, 1);
        IVault(vault).createQueue(2, true, vaultAdmin, wsteth, abi.encode(0, 24 hours));
        syncDepositWstethQueue = IVault(vault).queueAt(wsteth, 1);

        IVault(vault).createQueue(0, false, vaultAdmin, eth, "");
        asyncRedeemEthQueue = IVault(vault).queueAt(eth, 2);
        IVault(vault).createQueue(0, false, vaultAdmin, wsteth, "");
        asyncRedeemWstethQueue = IVault(vault).queueAt(wsteth, 2);

        if (withReport) {
            IOracle.Report[] memory reports = new IOracle.Report[](1);
            reports[0].asset = wsteth;
            reports[0].priceD18 = uint224(IWstETH(wsteth).getStETHByWstETH(1 ether));
            IVault(vault).oracle().submitReports(reports);
            IVault(vault).oracle().acceptReport(reports[0].asset, reports[0].priceD18, uint32(block.timestamp));
        }

        vm.stopPrank();
    }

    function _deployStrategy(DeployParams memory deployParams) internal {
        _deployMellowVault(deployParams.withReport);
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(vault),
            deployParams.withSyncQueue ? address(syncDepositWstethQueue) : address(0),
            deployParams.withAsyncQueue ? address(asyncDepositWstethQueue) : address(0),
            address(asyncRedeemWstethQueue),
            deployParams.allowList
        );

        strategy = MellowStrategy(
            payable(new TransparentUpgradeableProxy(address(strategyImplementation), address(0xdead), ""))
        );
        strategy.initialize(vaultAdmin, vaultAdmin);
    }

    function _deployMellowVault() internal {
        _deployMellowVault(true);
    }

    function _deployStrategy() internal {
        _deployStrategy(DeployParams({allowList: false, withReport: false, withSyncQueue: true, withAsyncQueue: true}));
    }

    function setUp() external {
        // mocks
        dashboard = new MockDashboardFactory().createMockDashboard(vaultAdmin);
        wsteth = address(dashboard.WSTETH());
        vaultHub = dashboard.VAULT_HUB();

        dashboard.fund{value: INITIAL_DEPOSIT}();
        StvStETHPool poolImpl = new StvStETHPool(
            address(dashboard), false, RESERVE_RATIO_GAP_BP, withdrawalQueue, address(0), keccak256("stv.steth.pool")
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), "");

        pool = StvStETHPool(payable(poolProxy));
        pool.initialize(vaultAdmin, "Test", "stvETH");
    }

    function testConstructor_ZeroStrategyId() external {
        vm.expectRevert(abi.encodeWithSignature("CallForwarderZeroArgument(string)", "_strategyId"));
        strategyImplementation = new MellowStrategy(
            bytes32(0), address(0), address(0), IVault(address(0)), address(0), address(0), address(0), false
        );
    }

    function testConstructor_ZeroCallForwarderImpl() external {
        vm.expectRevert(abi.encodeWithSignature("CallForwarderZeroArgument(string)", "_strategyCallForwarderImpl"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(0),
            address(0),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidPool() external {
        vm.expectRevert();
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(0),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );

        vm.expectRevert();
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(0xdead),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_ZeroVault() external {
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "vault"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_ZeroDepositQueues() external {
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "depositQueues"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(address(0x101)),
            address(0),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_AssetZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "syncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_HasQueueFalse() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "syncDeposit"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_IsDepositQueue_False() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "syncDeposit"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_NonWstethAsset() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(eth));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "syncDeposit"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_nameReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCallRevert(mockQueue, abi.encodeCall(ISyncDepositQueue.name, ()), abi.encode("asset() call revert"));
        vm.expectRevert(abi.encode("asset() call revert"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_SyncDepositQueue_nameMismatch() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCall(mockQueue, abi.encodeCall(ISyncDepositQueue.name, ()), abi.encode("NotASyncDepositQueueName"));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "syncDeposit"));
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_AssetZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_HasQueueFalse() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_IsDepositQueue_False() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_NonWstethAsset() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(eth));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_requestOfReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCallRevert(mockQueue, IDepositQueue.requestOf.selector, abi.encode("requestOf(any) call reverts"));
        vm.expectRevert(abi.encode("requestOf(any) call reverts"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_requestOfTimestampNonZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCall(mockQueue, IDepositQueue.requestOf.selector, abi.encode(1, 0));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_requestOfAssetsNonZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCall(mockQueue, IDepositQueue.requestOf.selector, abi.encode(0, 1));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncDeposit"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_AssetZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_HasQueueFalse() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_IsDepositQueue_True() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_NonWstethAsset() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(eth));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_requestsOfReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCallRevert(
            mockQueue, IRedeemQueue.requestsOf.selector, abi.encode("requestsOf(any, any, any) call reverts")
        );
        vm.expectRevert(abi.encode("requestsOf(any, any, any) call reverts"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_requestsOfNonZero() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(wsteth));
        vm.mockCall(mockQueue, IRedeemQueue.requestsOf.selector, abi.encode(new IRedeemQueue.Request[](1)));
        vm.expectRevert(abi.encodeWithSignature("InvalidQueue(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructorSuccess() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            true
        );
        assertEq(address(strategyImplementation.POOL()), address(pool));
        assertEq(address(strategyImplementation.WSTETH()), address(wsteth));
        assertEq(address(strategyImplementation.MELLOW_VAULT()), address(vault));
        assertEq(address(strategyImplementation.MELLOW_FEE_MANAGER()), address(IVault(vault).feeManager()));
        assertEq(address(strategyImplementation.MELLOW_ORACLE()), address(IVault(vault).oracle()));
        assertEq(address(strategyImplementation.MELLOW_SHARE_MANAGER()), address(IVault(vault).shareManager()));
        assertEq(address(strategyImplementation.MELLOW_SYNC_DEPOSIT_QUEUE()), address(syncDepositWstethQueue));
        assertEq(address(strategyImplementation.MELLOW_ASYNC_DEPOSIT_QUEUE()), address(asyncDepositWstethQueue));
        assertEq(address(strategyImplementation.MELLOW_ASYNC_REDEEM_QUEUE()), address(asyncRedeemWstethQueue));
        assertTrue(strategyImplementation.ALLOW_LIST_ENABLED());

        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            false
        );
        assertEq(address(strategyImplementation.POOL()), address(pool));
        assertEq(address(strategyImplementation.WSTETH()), address(wsteth));
        assertEq(address(strategyImplementation.MELLOW_VAULT()), address(vault));
        assertEq(address(strategyImplementation.MELLOW_FEE_MANAGER()), address(IVault(vault).feeManager()));
        assertEq(address(strategyImplementation.MELLOW_ORACLE()), address(IVault(vault).oracle()));
        assertEq(address(strategyImplementation.MELLOW_SHARE_MANAGER()), address(IVault(vault).shareManager()));
        assertEq(address(strategyImplementation.MELLOW_SYNC_DEPOSIT_QUEUE()), address(syncDepositWstethQueue));
        assertEq(address(strategyImplementation.MELLOW_ASYNC_DEPOSIT_QUEUE()), address(asyncDepositWstethQueue));
        assertEq(address(strategyImplementation.MELLOW_ASYNC_REDEEM_QUEUE()), address(asyncRedeemWstethQueue));
        assertFalse(strategyImplementation.ALLOW_LIST_ENABLED());
    }

    function testInitialize_Implementation_InvalidInitialization() external {
        _deployStrategy();

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        strategyImplementation.initialize(address(0), address(0));
    }

    function testInitialize_Proxy_ZeroArgument_admin() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            bytes32("MellowStrategyId"),
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            false
        );

        strategy =
            MellowStrategy(payable(new TransparentUpgradeableProxy(address(strategyImplementation), vaultAdmin, "")));

        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "_admin"));
        strategy.initialize(address(0), address(0));
    }

    function testInitialize_Proxy_Success() external {
        _deployMellowVault();
        strategyImplementation = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            false
        );

        strategy = MellowStrategy(
            payable(new TransparentUpgradeableProxy(address(strategyImplementation), address(0xdead), ""))
        );

        assertEq(strategy.getRoleMemberCount(strategy.DEFAULT_ADMIN_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.ALLOW_LIST_MANAGER_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.DEPOSIT_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_RESUME_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_RESUME_ROLE()), 0);

        assertFalse(strategy.hasRole(strategy.DEFAULT_ADMIN_ROLE(), vaultAdmin));
        assertFalse(strategy.hasRole(strategy.ALLOW_LIST_MANAGER_ROLE(), vaultAdmin));
        assertEq(strategy.getRoleAdmin(strategy.ALLOW_LIST_MANAGER_ROLE()), strategy.DEFAULT_ADMIN_ROLE());
        assertEq(strategy.getRoleAdmin(strategy.DEPOSIT_ROLE()), strategy.DEFAULT_ADMIN_ROLE());

        strategy.initialize(address(vaultAdmin), address(0));

        assertEq(strategy.getRoleMemberCount(strategy.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(strategy.getRoleMemberCount(strategy.ALLOW_LIST_MANAGER_ROLE()), 1);
        assertEq(strategy.getRoleMemberCount(strategy.DEPOSIT_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_RESUME_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_RESUME_ROLE()), 0);

        assertTrue(strategy.hasRole(strategy.DEFAULT_ADMIN_ROLE(), vaultAdmin));
        assertTrue(strategy.hasRole(strategy.ALLOW_LIST_MANAGER_ROLE(), vaultAdmin));
        assertEq(strategy.getRoleAdmin(strategy.ALLOW_LIST_MANAGER_ROLE()), strategy.DEFAULT_ADMIN_ROLE());
        assertEq(strategy.getRoleAdmin(strategy.DEPOSIT_ROLE()), strategy.ALLOW_LIST_MANAGER_ROLE());

        strategy = MellowStrategy(
            payable(new TransparentUpgradeableProxy(address(strategyImplementation), address(0xdead), ""))
        );

        assertEq(strategy.getRoleMemberCount(strategy.DEFAULT_ADMIN_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.ALLOW_LIST_MANAGER_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.DEPOSIT_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_RESUME_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_RESUME_ROLE()), 0);

        assertFalse(strategy.hasRole(strategy.DEFAULT_ADMIN_ROLE(), vaultAdmin));
        assertFalse(strategy.hasRole(strategy.ALLOW_LIST_MANAGER_ROLE(), vaultAdmin));
        assertEq(strategy.getRoleAdmin(strategy.ALLOW_LIST_MANAGER_ROLE()), strategy.DEFAULT_ADMIN_ROLE());
        assertEq(strategy.getRoleAdmin(strategy.DEPOSIT_ROLE()), strategy.DEFAULT_ADMIN_ROLE());

        address supplyPauser = makeAddr("supplyPauser");
        strategy.initialize(address(vaultAdmin), supplyPauser);

        assertEq(strategy.getRoleMemberCount(strategy.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(strategy.getRoleMemberCount(strategy.ALLOW_LIST_MANAGER_ROLE()), 1);
        assertEq(strategy.getRoleMemberCount(strategy.DEPOSIT_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_PAUSE_ROLE()), 1);
        assertEq(strategy.getRoleMemberCount(strategy.SUPPLY_RESUME_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_PAUSE_ROLE()), 0);
        assertEq(strategy.getRoleMemberCount(strategy.REDEEM_RESUME_ROLE()), 0);

        assertTrue(strategy.hasRole(strategy.DEFAULT_ADMIN_ROLE(), vaultAdmin));
        assertTrue(strategy.hasRole(strategy.ALLOW_LIST_MANAGER_ROLE(), vaultAdmin));
        assertEq(strategy.getRoleAdmin(strategy.ALLOW_LIST_MANAGER_ROLE()), strategy.DEFAULT_ADMIN_ROLE());
        assertEq(strategy.getRoleAdmin(strategy.DEPOSIT_ROLE()), strategy.ALLOW_LIST_MANAGER_ROLE());
    }

    function testPauseSupply_RevertsWithAccessControlUnauthorizedAccount() external {
        _deployStrategy();

        address caller = makeAddr("random-caller");

        vm.startPrank(caller);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", caller, strategy.SUPPLY_PAUSE_ROLE()
            )
        );
        strategy.pauseSupply();
    }

    function testPauseSupply_Success() external {
        _deployStrategy();

        address caller = makeAddr("random-caller");

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.SUPPLY_PAUSE_ROLE(), caller);
        vm.stopPrank();

        assertFalse(strategy.isFeaturePaused(strategy.SUPPLY_FEATURE()));

        vm.startPrank(caller);
        strategy.pauseSupply();

        assertTrue(strategy.isFeaturePaused(strategy.SUPPLY_FEATURE()));
    }

    function testResumeSupply_RevertsWithAccessControlUnauthorizedAccount() external {
        _deployStrategy();

        address caller = makeAddr("random-caller");

        vm.startPrank(caller);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", caller, strategy.SUPPLY_RESUME_ROLE()
            )
        );
        strategy.resumeSupply();
    }

    function testResumeSupply_Success() external {
        _deployStrategy();

        address caller = makeAddr("random-caller");

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.SUPPLY_PAUSE_ROLE(), vaultAdmin);
        strategy.grantRole(strategy.SUPPLY_RESUME_ROLE(), caller);
        strategy.pauseSupply();
        vm.stopPrank();

        assertTrue(strategy.isFeaturePaused(strategy.SUPPLY_FEATURE()));

        vm.startPrank(caller);
        strategy.resumeSupply();

        assertFalse(strategy.isFeaturePaused(strategy.SUPPLY_FEATURE()));
    }

    function testPauseRedeem_RevertsWithAccessControlUnauthorizedAccount() external {
        _deployStrategy();

        address caller = makeAddr("random-caller");

        vm.startPrank(caller);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", caller, strategy.REDEEM_PAUSE_ROLE()
            )
        );
        strategy.pauseRedeem();
    }

    function testPauseRedeem_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address caller = makeAddr("random-caller");

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.REDEEM_PAUSE_ROLE(), caller);
        vm.stopPrank();

        assertFalse(strategy.isFeaturePaused(strategy.REDEEM_FEATURE()));

        vm.startPrank(caller);
        strategy.pauseRedeem();

        assertTrue(strategy.isFeaturePaused(strategy.REDEEM_FEATURE()));
    }

    function testResumeRedeem_RevertsWithAccessControlUnauthorizedAccount() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address caller = makeAddr("random-caller");

        vm.startPrank(caller);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", caller, strategy.REDEEM_RESUME_ROLE()
            )
        );
        strategy.resumeRedeem();
    }

    function testResumeRedeem_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address caller = makeAddr("random-caller");

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.REDEEM_PAUSE_ROLE(), vaultAdmin);
        strategy.grantRole(strategy.REDEEM_RESUME_ROLE(), caller);
        strategy.pauseRedeem();
        vm.stopPrank();

        assertTrue(strategy.isFeaturePaused(strategy.REDEEM_FEATURE()));

        vm.startPrank(caller);
        strategy.resumeRedeem();

        assertFalse(strategy.isFeaturePaused(strategy.REDEEM_FEATURE()));
    }

    function testPreviewSupply_FeaturePaused() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.SUPPLY_PAUSE_ROLE(), vaultAdmin);
        strategy.pauseSupply();
        vm.stopPrank();

        address depositor = makeAddr("depositor");
        address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
        (bool success, uint256 shares) = strategy.previewSupply(
            1 ether,
            depositor,
            callForwarder,
            MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
        );

        assertFalse(success);
        assertEq(shares, 0);
    }

    function testPreviewSupply_NotAllowListed() external {
        _deployStrategy(DeployParams({allowList: true, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.ALLOW_LIST_MANAGER_ROLE(), vaultAdmin);
        address depositor = makeAddr("depositor");
        address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
        (bool success, uint256 shares) = strategy.previewSupply(
            1 ether,
            depositor,
            callForwarder,
            MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
        );

        assertFalse(success);
        assertEq(shares, 0);

        strategy.grantRole(strategy.DEPOSIT_ROLE(), depositor);
        (success, shares) = strategy.previewSupply(
            1 ether,
            depositor,
            callForwarder,
            MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
        );

        assertTrue(success);
        assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));

        vm.stopPrank();
    }

    function testPreviewSupply_ZeroQueue() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: false, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: false, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: false})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: false})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_PausedQueue() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(vault, abi.encodeCall(IVault.isPausedQueue, (syncDepositWstethQueue)), abi.encode(true));
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(vault, abi.encodeCall(IVault.isPausedQueue, (syncDepositWstethQueue)), abi.encode(false));
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_NoLongerValidQueue() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (syncDepositWstethQueue)), abi.encode(false));
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (syncDepositWstethQueue)), abi.encode(true));
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_IsDepositorWhitelisted() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            vm.mockCall(
                address(IVault(vault).shareManager()),
                abi.encodeCall(IShareManager.isDepositorWhitelisted, (callForwarder, new bytes32[](0))),
                abi.encode(false)
            );

            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            vm.mockCall(
                address(IVault(vault).shareManager()),
                abi.encodeCall(IShareManager.isDepositorWhitelisted, (callForwarder, new bytes32[](0))),
                abi.encode(true)
            );
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_SuspiciousReport() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({
                        isSuspicious: true,
                        priceD18: uint224(IWstETH(wsteth).getStETHByWstETH(1 ether)),
                        timestamp: uint32(block.timestamp)
                    })
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({
                        isSuspicious: false,
                        priceD18: uint224(IWstETH(wsteth).getStETHByWstETH(1 ether)),
                        timestamp: uint32(block.timestamp)
                    })
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_ZeroOraclePrice() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({isSuspicious: false, priceD18: 0, timestamp: uint32(block.timestamp)})
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({
                        isSuspicious: false,
                        priceD18: uint224(IWstETH(wsteth).getStETHByWstETH(1 ether)),
                        timestamp: uint32(block.timestamp)
                    })
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_NonZeroDepositFee() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            // 100% deposit fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.depositFeeD6, ()), abi.encode(1e6)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            // 10% deposit fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.depositFeeD6, ()), abi.encode(1e5)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * 9 / 10);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            // 1% deposit fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.depositFeeD6, ()), abi.encode(1e4)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * 99 / 100);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            // 0.1234% deposit fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.depositFeeD6, ()), abi.encode(1234)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * (1e6 - 1234) / 1e6);
        }
    }

    function testPreviewSupply_SyncDepositQueue_StaleReport() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({
                        isSuspicious: false,
                        priceD18: uint224(IWstETH(wsteth).getStETHByWstETH(1 ether)),
                        timestamp: uint32(block.timestamp - 24 hours - 1 seconds)
                    })
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            vm.mockCall(
                address(IVault(vault).oracle()),
                abi.encodeCall(IOracle.getReport, (wsteth)),
                abi.encode(
                    IOracle.DetailedReport({
                        isSuspicious: false,
                        priceD18: uint224(IWstETH(wsteth).getStETHByWstETH(1 ether)),
                        timestamp: uint32(block.timestamp - 24 hours)
                    })
                )
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_SyncDepositQueue_NonZeroPenalty() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                syncDepositWstethQueue, abi.encodeCall(ISyncDepositQueue.syncDepositParams, ()), abi.encode(5e5, 1)
            );

            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) / 2);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            vm.mockCall(
                syncDepositWstethQueue, abi.encodeCall(ISyncDepositQueue.syncDepositParams, ()), abi.encode(1e5, 1)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * 9 / 10);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            vm.mockCall(
                syncDepositWstethQueue, abi.encodeCall(ISyncDepositQueue.syncDepositParams, ()), abi.encode(1e4, 1)
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * 99 / 100);
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            vm.mockCall(
                syncDepositWstethQueue, abi.encodeCall(ISyncDepositQueue.syncDepositParams, ()), abi.encode(1234, 1)
            );

            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether) * (1e6 - 1234) / 1e6);
        }
    }

    function testPreviewSupply_AsyncDepositQueue_PendingRequest() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            vm.mockCall(
                asyncDepositWstethQueue,
                abi.encodeCall(IDepositQueue.requestOf, (callForwarder)),
                abi.encode(block.timestamp, 0)
            );
            vm.mockCall(
                asyncDepositWstethQueue, abi.encodeCall(IDepositQueue.claimableOf, (callForwarder)), abi.encode(0)
            );
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }
        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            vm.mockCall(
                asyncDepositWstethQueue,
                abi.encodeCall(IDepositQueue.requestOf, (callForwarder)),
                abi.encode(block.timestamp, 0)
            );
            vm.mockCall(
                asyncDepositWstethQueue, abi.encodeCall(IDepositQueue.claimableOf, (callForwarder)), abi.encode(1)
            );
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));
            vm.mockCall(
                asyncDepositWstethQueue, abi.encodeCall(IDepositQueue.requestOf, (callForwarder)), abi.encode(0, 0)
            );
            (bool success, uint256 shares) = strategy.previewSupply(
                1 ether,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
    }

    function testPreviewSupply_AsyncDepositQueue_ZeroShares() external {
        address depositor = makeAddr("depositor");

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));

            (bool success, uint256 shares) = strategy.previewSupply(
                0,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertFalse(success);
            assertEq(shares, 0);
        }
        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );
            address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));

            (bool success, uint256 shares) = strategy.previewSupply(
                1,
                depositor,
                callForwarder,
                MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)})
            );

            assertTrue(success);
            assertEq(shares, 1);
        }
    }
}
