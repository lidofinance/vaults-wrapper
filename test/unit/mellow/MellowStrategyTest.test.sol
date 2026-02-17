// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StvStETHPool} from "src/StvStETHPool.sol";

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

import {MellowStrategy} from "src/strategy/MellowStrategy.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";
import {StrategyCallForwarder} from "src/strategy/StrategyCallForwarder.sol";

import {MockDashboard, MockDashboardFactory} from "test/mocks/MockDashboard.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {MockWithdrawalQueue} from "test/mocks/MockWithdrawalQueue.sol";

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
    address public withdrawalQueue;

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
    bytes32 public constant REMOVE_SUPPORTED_ASSETS_ROLE = keccak256("oracles.Oracle.REMOVE_SUPPORTED_ASSETS_ROLE");

    // Constants
    uint256 public constant INITIAL_DEPOSIT = 1 ether;
    uint256 public constant RESERVE_RATIO_GAP_BP = 5_00; // 5%

    bytes32 public constant STRATEGY_ID = "MellowStrategyId";

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
            STRATEGY_ID,
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

    function _submitReport() internal {
        vm.startPrank(vaultAdmin);

        IOracle.Report[] memory reports = new IOracle.Report[](1);
        reports[0].asset = wsteth;
        reports[0].priceD18 = uint224(IWstETH(wsteth).getStETHByWstETH(1 ether));

        IVault(vault).oracle().submitReports(reports);
        vm.stopPrank();
    }

    function setUp() external {
        // mocks

        dashboard = new MockDashboardFactory().createMockDashboard(vaultAdmin);
        wsteth = address(dashboard.WSTETH());
        vaultHub = dashboard.VAULT_HUB();

        dashboard.fund{value: INITIAL_DEPOSIT}();
        withdrawalQueue = address(new MockWithdrawalQueue());
        StvStETHPool poolImpl = new StvStETHPool(
            address(dashboard), false, RESERVE_RATIO_GAP_BP, withdrawalQueue, address(0), keccak256("stv.steth.pool")
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), "");

        pool = StvStETHPool(payable(poolProxy));
        pool.initialize(vaultAdmin, "Test", "stvETH");
        MockWithdrawalQueue(withdrawalQueue).setPool(address(pool));
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
            STRATEGY_ID, address(0), address(0), IVault(address(0)), address(0), address(0), address(0), false
        );
    }

    function testConstructor_InvalidPool() external {
        address strategyCallForwarder = address(new StrategyCallForwarder());

        vm.expectRevert();
        strategyImplementation = new MellowStrategy(
            STRATEGY_ID,
            strategyCallForwarder,
            address(0),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );

        vm.expectRevert();
        strategyImplementation = new MellowStrategy(
            STRATEGY_ID,
            strategyCallForwarder,
            address(0xdead),
            IVault(address(0)),
            address(0),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_ZeroVault() external {
        address strategyCallForwarder = address(new StrategyCallForwarder());
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "vault"));
        strategyImplementation = new MellowStrategy(
            STRATEGY_ID,
            strategyCallForwarder,
            address(pool),
            IVault(address(0)),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            false
        );
    }

    function testConstructor_ZeroDepositQueues() external {
        address strategyCallForwarder = address(new StrategyCallForwarder());
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "depositQueues"));
        strategyImplementation = new MellowStrategy(
            STRATEGY_ID,
            strategyCallForwarder,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(mockQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_HasQueueReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCallRevert(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode("revert-call"));
        vm.expectRevert(abi.encode("revert-call"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_IsDepositQueueReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCallRevert(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode("revert-call"));
        vm.expectRevert(abi.encode("revert-call"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncDepositQueue_AssetReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(true));
        vm.mockCallRevert(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode("revert-call"));
        vm.expectRevert(abi.encode("revert-call"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(0),
            address(mockQueue),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_ZeroQueue() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode(address(0)));
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "asyncRedeem"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(0),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_HasQueueReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCallRevert(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode("revert-call"));
        vm.expectRevert(abi.encode("revert-call"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_InvalidQueue_AsyncRedeemQueue_AssetReverts() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        address mockQueue = makeAddr("mockQueue");
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (mockQueue)), abi.encode(true));
        vm.mockCall(vault, abi.encodeCall(IVault.isDepositQueue, (mockQueue)), abi.encode(false));
        vm.mockCallRevert(mockQueue, abi.encodeCall(IQueue.asset, ()), abi.encode("revert-call"));
        vm.expectRevert(abi.encode("revert-call"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
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
            STRATEGY_ID,
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
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(0),
            address(mockQueue),
            false
        );
    }

    function testConstructor_Success() external {
        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
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
            STRATEGY_ID,
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

    function testConstructor_DisableInitializersRevert() external {
        // Practically unreachable state, kept to ensure full test coverage

        _deployMellowVault();
        address strategyForwarder = address(new StrategyCallForwarder());

        address expectedAddress = Create2.computeAddress(
            bytes32(0),
            keccak256(
                abi.encodePacked(
                    type(MellowStrategy).creationCode,
                    abi.encode(
                        STRATEGY_ID,
                        strategyForwarder,
                        address(pool),
                        IVault(vault),
                        address(syncDepositWstethQueue),
                        address(asyncDepositWstethQueue),
                        address(asyncRedeemWstethQueue),
                        true
                    )
                )
            )
        );

        vm.store(
            expectedAddress,
            bytes32(0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00),
            bytes32(type(uint256).max)
        );

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        strategyImplementation = new MellowStrategy{salt: bytes32(0)}(
            STRATEGY_ID,
            strategyForwarder,
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            true
        );
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
            STRATEGY_ID,
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
            STRATEGY_ID,
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

        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true})
            );

            vm.mockCall(
                syncDepositWstethQueue,
                abi.encodeCall(ISyncDepositQueue.syncDepositParams, ()),
                abi.encode(type(uint256).max, type(uint32).max)
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
            MellowStrategy.MellowSupplyParams memory params =
                MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)});

            vm.expectRevert(abi.encode("panic: arithmetic underflow or overflow (0x11)"));
            strategy.previewSupply(1 ether, depositor, callForwarder, params);
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

            assertTrue(success);
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

    function testSupply_SupplyFailed() external {
        address depositor = makeAddr("depositor");
        {
            _deployStrategy(
                DeployParams({allowList: false, withReport: true, withSyncQueue: false, withAsyncQueue: true})
            );

            vm.startPrank(depositor);
            bytes memory data =
                abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

            vm.expectRevert(abi.encodeWithSignature("SupplyFailed()"));
            strategy.supply(address(0), 1 ether, data);
            vm.stopPrank();
        }
    }

    function testSupply_NonZeroMsgValue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address depositor = makeAddr("depositor");
        vm.startPrank(depositor);
        deal(depositor, 1 ether);
        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        assertEq(strategy.stvOf(depositor), 0);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        assertEq(strategy.stvOf(depositor), 1e9 ether); // 27 decimals

        vm.stopPrank();
    }

    function testSupply_ZeroMsgValue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address depositor = makeAddr("depositor");
        vm.startPrank(depositor);
        deal(depositor, 1 ether);
        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        assertEq(strategy.stvOf(depositor), 0);
        strategy.supply{value: 1 ether}(address(0), 0.1 ether, data);

        assertEq(strategy.stvOf(depositor), 1e9 ether); // 27 decimals

        strategy.supply{value: 0}(address(0), 0.5 ether, data);

        assertEq(strategy.stvOf(depositor), 1e9 ether); // 27 decimals

        vm.stopPrank();
    }

    function testSupply_SyncDeposit() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address depositor = makeAddr("depositor");
        vm.startPrank(depositor);
        deal(depositor, 1 ether);
        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        assertEq(strategy.sharesOf(depositor), 0);

        vm.recordLogs();
        strategy.supply{value: 1 ether}(address(0), 0.5 ether, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs[20].emitter, syncDepositWstethQueue);
        assertEq(logs[20].topics[0], keccak256("Deposited(address,address,uint224,uint256,uint256)"));
        assertEq(strategy.sharesOf(depositor), IWstETH(wsteth).getStETHByWstETH(0.5 ether));

        vm.stopPrank();
    }

    function testSupply_AsyncDeposit() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address depositor = makeAddr("depositor");
        vm.startPrank(depositor);
        deal(depositor, 1 ether);
        bytes memory data =
            abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));

        assertEq(strategy.sharesOf(depositor), 0);

        skip(10 seconds);

        vm.recordLogs();
        strategy.supply{value: 1 ether}(address(0), 0.5 ether, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs[15].emitter, asyncDepositWstethQueue);
        assertEq(logs[15].topics[0], keccak256("DepositRequested(address,address,uint224,uint32)"));

        skip(10 seconds);
        assertEq(strategy.sharesOf(depositor), 0);
        (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositWstethQueue)
            .requestOf(address(strategy.getStrategyCallForwarderAddress(depositor)));
        assertEq(timestamp + 10 seconds, block.timestamp);
        assertEq(assets, 0.5 ether);
        vm.stopPrank();
    }

    function testClaimShares_NoAsyncDepositQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: false}));

        vm.expectRevert(abi.encodeWithSignature("NoAsyncDepositQueue()"));
        strategy.claimShares();
    }

    function testClaimShares_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address depositor = makeAddr("depositor");
        deal(depositor, 1 ether);
        bytes memory data =
            abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));
        address callForwarder = address(strategy.getStrategyCallForwarderAddress(depositor));

        {
            (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositWstethQueue).requestOf(callForwarder);
            assertEq(timestamp, 0);
            assertEq(assets, 0);
            assertEq(IDepositQueue(asyncDepositWstethQueue).claimableOf(callForwarder), 0);
            assertEq(IVault(vault).shareManager().sharesOf(callForwarder), 0);
        }

        vm.startPrank(depositor);
        strategy.supply{value: 1 ether}(address(0), 0.5 ether, data);
        vm.stopPrank();

        uint256 expectedShares = IWstETH(wsteth).getStETHByWstETH(0.5 ether);

        {
            (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositWstethQueue).requestOf(callForwarder);
            assertEq(timestamp, block.timestamp);
            assertEq(assets, 0.5 ether);
            assertEq(IDepositQueue(asyncDepositWstethQueue).claimableOf(callForwarder), 0);
            assertEq(IVault(vault).shareManager().sharesOf(callForwarder), 0);
        }

        skip(1 hours);
        _submitReport();

        {
            (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositWstethQueue).requestOf(callForwarder);
            assertEq(timestamp, block.timestamp - 1 hours);
            assertEq(assets, 0.5 ether);
            assertEq(IDepositQueue(asyncDepositWstethQueue).claimableOf(callForwarder), expectedShares);
            assertEq(IVault(vault).shareManager().sharesOf(callForwarder), expectedShares);
            assertEq(IERC20(address(IVault(vault).shareManager())).balanceOf(callForwarder), 0);
        }

        vm.startPrank(depositor);
        strategy.claimShares();
        vm.stopPrank();

        {
            (uint256 timestamp, uint256 assets) = IDepositQueue(asyncDepositWstethQueue).requestOf(callForwarder);
            assertEq(timestamp, 0);
            assertEq(assets, 0);
            assertEq(IDepositQueue(asyncDepositWstethQueue).claimableOf(callForwarder), 0);
            assertEq(IVault(vault).shareManager().sharesOf(callForwarder), expectedShares);
            assertEq(IERC20(address(IVault(vault).shareManager())).balanceOf(callForwarder), expectedShares);
        }
    }

    function testPreviewWithdraw_FeaturePaused() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.REDEEM_PAUSE_ROLE(), vaultAdmin);
        strategy.pauseRedeem();
        vm.stopPrank();

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_PausedQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        vm.mockCall(vault, abi.encodeCall(IVault.isPausedQueue, (asyncRedeemWstethQueue)), abi.encode(true));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_NoLongerValidQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (asyncRedeemWstethQueue)), abi.encode(false));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_SuspiciousReport() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

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

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_ZeroPrice() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        vm.mockCall(
            address(IVault(vault).oracle()),
            abi.encodeCall(IOracle.getReport, (wsteth)),
            abi.encode(
                IOracle.DetailedReport({isSuspicious: false, priceD18: uint224(0), timestamp: uint32(block.timestamp)})
            )
        );

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_NonZeroRedeemFee() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            // 0% redeem fee
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        {
            // 100% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e6)
            );

            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            // 10% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e5)
            );

            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, Math.mulDiv(IWstETH(wsteth).getStETHByWstETH(1 ether), 10, 9, Math.Rounding.Ceil));
        }

        {
            // 1% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e4)
            );

            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, Math.mulDiv(IWstETH(wsteth).getStETHByWstETH(1 ether), 100, 99, Math.Rounding.Ceil));
        }

        {
            // 0.1234% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1234)
            );

            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(
                shares, Math.mulDiv(IWstETH(wsteth).getStETHByWstETH(1 ether), 1e6, 1e6 - 1234, Math.Rounding.Ceil)
            );
        }
    }

    function testPreviewWithdraw_ZeroShares() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1);
            assertTrue(success);
            assertEq(shares, 2);
        }

        {
            (bool success, uint256 shares) = strategy.previewWithdraw(0);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewWithdraw_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        {
            (bool success, uint256 shares) = strategy.previewWithdraw(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(1 ether));
        }
        {
            (bool success, uint256 shares) = strategy.previewWithdraw(10 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(10 ether));
        }
        {
            (bool success, uint256 shares) = strategy.previewWithdraw(100);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(100));
        }
        {
            (bool success, uint256 shares) = strategy.previewWithdraw(99);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getStETHByWstETH(99) + 1); // rounding up
        }
    }

    //////

    function testPreviewRedeem_FeaturePaused() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        vm.startPrank(vaultAdmin);
        strategy.grantRole(strategy.REDEEM_PAUSE_ROLE(), vaultAdmin);
        strategy.pauseRedeem();
        vm.stopPrank();

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_PausedQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        vm.mockCall(vault, abi.encodeCall(IVault.isPausedQueue, (asyncRedeemWstethQueue)), abi.encode(true));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_NoLongerValidQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (asyncRedeemWstethQueue)), abi.encode(false));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_SuspiciousReport() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

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

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_ZeroPrice() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        vm.mockCall(
            address(IVault(vault).oracle()),
            abi.encodeCall(IOracle.getReport, (wsteth)),
            abi.encode(
                IOracle.DetailedReport({isSuspicious: false, priceD18: uint224(0), timestamp: uint32(block.timestamp)})
            )
        );

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_NonZeroRedeemFee() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            // 0% redeem fee
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        {
            // 100% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e6)
            );

            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            // 10% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e5)
            );

            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 9, 10));
        }

        {
            // 1% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1e4)
            );

            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 99, 100));
        }

        {
            // 0.1234% redeem fee
            vm.mockCall(
                address(IVault(vault).feeManager()), abi.encodeCall(IFeeManager.redeemFeeD6, ()), abi.encode(1234)
            );

            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e6 - 1234, 1e6));
        }
    }

    function testPreviewRedeem_ZeroShares() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }

        {
            (bool success, uint256 shares) = strategy.previewRedeem(1);
            assertFalse(success);
            assertEq(shares, 0);
        }

        {
            (bool success, uint256 shares) = strategy.previewRedeem(0);
            assertFalse(success);
            assertEq(shares, 0);
        }
    }

    function testPreviewRedeem_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        {
            (bool success, uint256 shares) = strategy.previewRedeem(1 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(1 ether));
        }
        {
            (bool success, uint256 shares) = strategy.previewRedeem(10 ether);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(10 ether));
        }
        {
            (bool success, uint256 shares) = strategy.previewRedeem(100);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(100));
        }
        {
            (bool success, uint256 shares) = strategy.previewRedeem(99);
            assertTrue(success);
            assertEq(shares, IWstETH(wsteth).getWstETHByStETH(99));
        }
    }

    function testRequestExitByShares_ZeroShares() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "shares"));
        strategy.requestExitByShares(0, "");
    }

    function testRequestExitByShares_RedeemFailed() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (asyncRedeemWstethQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("RedeemFailed()"));
        strategy.requestExitByShares(1 ether, "");
    }

    function testRequestExitByShares_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        address account = makeAddr("account");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        strategy.requestExitByShares(shares, "");
    }

    function testRequestExitByWstETH_ZeroAssets() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "assets"));
        strategy.requestExitByWsteth(0, "");
    }

    function testRequestExitByWstETH_WithdrawFailed() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        vm.mockCall(vault, abi.encodeCall(IVault.hasQueue, (asyncRedeemWstethQueue)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSignature("WithdrawalFailed()"));
        strategy.requestExitByWsteth(1 ether, "");
    }

    function testRequestExitByWstETH_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        address account = makeAddr("account");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        strategy.requestExitByWsteth(0.6 ether, "");
    }

    function testRequestExit_InsufficientMellowShares() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);

        vm.expectRevert(abi.encodeWithSignature("InsufficientMellowShares()"));
        strategy.requestExitByShares(1 ether, "");

        vm.stopPrank();
    }

    function testRequestExit_SingleRequest() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        vm.expectRevert(abi.encodeWithSignature("InsufficientMellowShares()"));
        strategy.requestExitByShares(shares + 1, "");

        address callForwarder = address(strategy.getStrategyCallForwarderAddress(account));
        IRedeemQueue.Request[] memory requests =
            IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 0);

        strategy.requestExitByShares(shares, "");

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);
        assertEq(strategy.sharesOf(account), 0);
        assertEq(requests[0].timestamp, block.timestamp);
        assertEq(requests[0].shares, shares);
        assertFalse(requests[0].isClaimable);
        assertEq(requests[0].assets, 0);

        vm.stopPrank();
    }

    function testRequestExit_MultipleRequestSingleTimestamp() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        vm.expectRevert(abi.encodeWithSignature("InsufficientMellowShares()"));
        strategy.requestExitByShares(shares + 1, "");

        address callForwarder = address(strategy.getStrategyCallForwarderAddress(account));
        IRedeemQueue.Request[] memory requests =
            IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 0);

        assertEq(uint256(strategy.requestExitByShares(shares / 2, "")), block.timestamp);

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);

        assertEq(strategy.sharesOf(account), shares - shares / 2);
        assertEq(requests[0].timestamp, block.timestamp);
        assertEq(requests[0].shares, shares / 2);
        assertFalse(requests[0].isClaimable);
        assertEq(requests[0].assets, 0);

        assertEq(uint256(strategy.requestExitByShares(shares - shares / 2, "")), block.timestamp);

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);

        assertEq(strategy.sharesOf(account), 0);
        assertEq(requests[0].timestamp, block.timestamp);
        assertEq(requests[0].shares, shares);
        assertFalse(requests[0].isClaimable);
        assertEq(requests[0].assets, 0);

        vm.stopPrank();
    }

    function testRequestExit_MultipleRequestDifferentTimestamps() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        vm.expectRevert(abi.encodeWithSignature("InsufficientMellowShares()"));
        strategy.requestExitByShares(shares + 1, "");

        address callForwarder = address(strategy.getStrategyCallForwarderAddress(account));
        IRedeemQueue.Request[] memory requests =
            IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 0);

        assertEq(uint256(strategy.requestExitByShares(shares / 2, "")), block.timestamp);

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);

        assertEq(strategy.sharesOf(account), shares - shares / 2);
        assertEq(requests[0].timestamp, block.timestamp);
        assertEq(requests[0].shares, shares / 2);
        assertFalse(requests[0].isClaimable);
        assertEq(requests[0].assets, 0);

        skip(1 seconds);

        assertEq(uint256(strategy.requestExitByShares(shares - shares / 2, "")), block.timestamp);

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 2);

        assertEq(strategy.sharesOf(account), 0);
        assertEq(requests[0].timestamp, block.timestamp - 1);
        assertEq(requests[0].shares, shares / 2);
        assertFalse(requests[0].isClaimable);
        assertEq(requests[0].assets, 0);

        assertEq(requests[1].timestamp, block.timestamp);
        assertEq(requests[1].shares, shares - shares / 2);
        assertFalse(requests[1].isClaimable);
        assertEq(requests[1].assets, 0);

        vm.stopPrank();
    }

    function testFinalizeRequestExit_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);
        uint256 shares = IWstETH(wsteth).getStETHByWstETH(0.6 ether);
        assertEq(strategy.sharesOf(account), shares);

        bytes32 requestId = strategy.requestExitByShares(shares, "");
        vm.stopPrank();

        address callForwarder = address(strategy.getStrategyCallForwarderAddress(account));
        IRedeemQueue.Request[] memory requests =
            IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0);
        assertEq(requests[0].isClaimable, false);

        skip(24 hours);

        _submitReport();

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0.6 ether);
        assertEq(requests[0].isClaimable, false);

        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0.6 ether);
        assertEq(requests[0].isClaimable, true);

        assertEq(IERC20(wsteth).balanceOf(account), 0);
        assertEq(IERC20(wsteth).balanceOf(callForwarder), 0);
        vm.startPrank(account);

        strategy.finalizeRequestExit(requestId);

        vm.stopPrank();
        requests = IRedeemQueue(asyncRedeemWstethQueue).requestsOf(callForwarder, 0, type(uint256).max);

        assertEq(requests.length, 0);
        assertEq(IERC20(wsteth).balanceOf(account), 0);
        assertEq(IERC20(wsteth).balanceOf(callForwarder), 0.6 ether);
    }

    function testMintedStethSharesOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        assertEq(strategy.mintedStethSharesOf(account), 0);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.1 ether, data);

        assertEq(strategy.mintedStethSharesOf(account), 0.1 ether);
        strategy.supply(address(0), 0.1 ether, data);

        assertEq(strategy.mintedStethSharesOf(account), 0.2 ether);
        strategy.supply(address(0), 0.1 ether, data);

        assertEq(strategy.mintedStethSharesOf(account), 0.3 ether);

        strategy.supply(address(0), 0.1 ether, data);
        assertEq(strategy.mintedStethSharesOf(account), 0.4 ether);

        strategy.supply(address(0), 0.1 ether, data);
        assertEq(strategy.mintedStethSharesOf(account), 0.5 ether);

        bytes32 requestId = strategy.requestExitByShares(strategy.sharesOf(account), "");
        skip(24 hours);
        vm.stopPrank();

        _submitReport();
        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        vm.startPrank(account);
        strategy.finalizeRequestExit(requestId);

        assertEq(strategy.mintedStethSharesOf(account), 0.5 ether);

        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.mintedStethSharesOf(account), 0.4 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.mintedStethSharesOf(account), 0.3 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.mintedStethSharesOf(account), 0.2 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.mintedStethSharesOf(account), 0.1 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.mintedStethSharesOf(account), 0 ether);

        vm.stopPrank();
    }

    function testRemainingMintingCapacitySharesOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        uint256 poolBP = pool.poolReserveRatioBP();

        assertEq(strategy.remainingMintingCapacitySharesOf(account, 0), 0);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 1 ether),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4)
        );

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.1 ether, data);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.1 ether
        );

        strategy.supply(address(0), 0.1 ether, data);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.2 ether
        );

        strategy.supply(address(0), 0.1 ether, data);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.3 ether
        );
        strategy.supply(address(0), 0.1 ether, data);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.4 ether
        );
        strategy.supply(address(0), 0.1 ether, data);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.5 ether
        );

        bytes32 requestId = strategy.requestExitByShares(strategy.sharesOf(account), "");
        skip(24 hours);
        vm.stopPrank();

        _submitReport();
        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        vm.startPrank(account);
        strategy.finalizeRequestExit(requestId);

        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.5 ether
        );

        strategy.burnWsteth(0.1 ether);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.4 ether
        );
        strategy.burnWsteth(0.1 ether);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.3 ether
        );
        strategy.burnWsteth(0.1 ether);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.2 ether
        );
        strategy.burnWsteth(0.1 ether);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4) - 0.1 ether
        );
        strategy.burnWsteth(0.1 ether);
        assertEq(
            strategy.remainingMintingCapacitySharesOf(account, 0),
            Math.mulDiv(IWstETH(wsteth).getWstETHByStETH(1 ether), 1e4 - poolBP, 1e4)
        );

        vm.stopPrank();
    }

    function testWstethOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);
        deal(account, 1 ether);

        assertEq(strategy.wstethOf(account), 0);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.wstethOf(account), 0);

        bytes32 requestId = strategy.requestExitByShares(strategy.sharesOf(account), "");
        skip(24 hours);
        vm.stopPrank();

        assertEq(strategy.wstethOf(account), 0);

        _submitReport();
        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        assertEq(strategy.wstethOf(account), 0);

        vm.startPrank(account);
        strategy.finalizeRequestExit(requestId);

        assertEq(strategy.wstethOf(account), 0.6 ether);

        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0.5 ether);

        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0.4 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0.3 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0.2 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0.1 ether);
        strategy.burnWsteth(0.1 ether);
        assertEq(strategy.wstethOf(account), 0 ether);

        vm.stopPrank();
    }

    function testStvOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account = makeAddr("user");

        vm.startPrank(account);

        assertEq(strategy.stvOf(account), 0);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        deal(account, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.stvOf(account), 1e9 ether);

        deal(account, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.stvOf(account), 2e9 ether);

        bytes32 requestId = strategy.requestExitByShares(strategy.sharesOf(account), "");
        skip(24 hours);
        vm.stopPrank();

        _submitReport();
        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        vm.startPrank(account);
        strategy.finalizeRequestExit(requestId);
        strategy.burnWsteth(strategy.wstethOf(account));

        assertEq(strategy.stvOf(account), 2e9 ether);

        // transfer from account to a random address
        strategy.safeTransferERC20(address(pool), address(0xdead), 1e9 ether);
        assertEq(strategy.stvOf(account), 1e9 ether);

        strategy.requestWithdrawalFromPool(account, 1e9 ether, 0);
        assertEq(strategy.stvOf(account), 0 ether);

        vm.stopPrank();
    }

    function testSharesOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account1 = makeAddr("account1");
        address account2 = makeAddr("account2");

        vm.startPrank(account1);

        assertEq(strategy.sharesOf(account1), 0);
        assertEq(strategy.sharesOf(account2), 0);
        assertEq(IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account1))), 0);
        assertEq(IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.sharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether));
        assertEq(strategy.sharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether)
        );
        assertEq(IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0);

        strategy.safeTransferERC20(shareManager, address(strategy.getStrategyCallForwarderAddress(account2)), 0.1 ether);

        assertEq(strategy.sharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether) - 0.1 ether);
        assertEq(strategy.sharesOf(account2), 0.1 ether);
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether) - 0.1 ether
        );
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0.1 ether
        );

        data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.5 ether, data);

        assertEq(strategy.sharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether) - 0.1 ether);
        assertEq(strategy.sharesOf(account2), 0.1 ether);
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether) - 0.1 ether
        );
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0.1 ether
        );

        vm.stopPrank();

        skip(1 hours);
        _submitReport();

        assertEq(strategy.sharesOf(account1), IWstETH(wsteth).getStETHByWstETH(1.1 ether) - 0.1 ether);
        assertEq(strategy.sharesOf(account2), 0.1 ether);
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(1.1 ether) - 0.1 ether
        );
        assertEq(
            IShareManager(shareManager).sharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0.1 ether
        );
    }

    function testClaimableSharesOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account1 = makeAddr("account1");
        address account2 = makeAddr("account2");

        vm.startPrank(account1);

        assertEq(strategy.claimableSharesOf(account1), 0);
        assertEq(strategy.claimableSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            0
        );
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0
        );

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.claimableSharesOf(account1), 0);
        assertEq(strategy.claimableSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            0
        );
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0
        );

        data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.claimableSharesOf(account1), 0);
        assertEq(strategy.claimableSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            0
        );
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0
        );

        vm.stopPrank();

        skip(1 hours);
        _submitReport();

        vm.startPrank(account1);

        assertEq(strategy.claimableSharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether));
        assertEq(strategy.claimableSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether)
        );
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0
        );

        // instantly claims all available shares
        strategy.safeTransferERC20(shareManager, address(strategy.getStrategyCallForwarderAddress(account2)), 0.1 ether);

        assertEq(strategy.claimableSharesOf(account1), 0);
        assertEq(strategy.claimableSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            0
        );
        assertEq(
            IShareManager(shareManager).claimableSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0
        );
    }

    function testActiveSharesOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account1 = makeAddr("account1");
        address account2 = makeAddr("account2");

        vm.startPrank(account1);

        assertEq(strategy.activeSharesOf(account1), 0);
        assertEq(strategy.activeSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))), 0
        );
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0
        );

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.activeSharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether));
        assertEq(strategy.activeSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether)
        );
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0
        );

        data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.activeSharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether));
        assertEq(strategy.activeSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether)
        );
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0
        );

        vm.stopPrank();

        skip(1 hours);
        _submitReport();

        vm.startPrank(account1);

        assertEq(strategy.activeSharesOf(account1), IWstETH(wsteth).getStETHByWstETH(0.6 ether));
        assertEq(strategy.activeSharesOf(account2), 0);
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(0.6 ether)
        );
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))), 0
        );

        strategy.safeTransferERC20(shareManager, address(strategy.getStrategyCallForwarderAddress(account2)), 0.1 ether);

        assertEq(strategy.activeSharesOf(account1), IWstETH(wsteth).getStETHByWstETH(1.2 ether) - 0.1 ether);
        assertEq(strategy.activeSharesOf(account2), 0.1 ether);
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account1))),
            IWstETH(wsteth).getStETHByWstETH(1.2 ether) - 0.1 ether
        );
        assertEq(
            IShareManager(shareManager).activeSharesOf(address(strategy.getStrategyCallForwarderAddress(account2))),
            0.1 ether
        );
    }

    function testGetDepositRequestOf_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account1 = makeAddr("account1");

        vm.startPrank(account1);

        {
            (uint256 assets, uint256 timestamp, bool isClaimable) = strategy.getDepositRequestOf(account1);
            assertEq(assets, 0);
            assertEq(timestamp, 0);
            assertFalse(isClaimable);
        }

        bytes memory data =
            abi.encode(MellowStrategy.MellowSupplyParams({isSync: false, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        {
            (uint256 assets, uint256 timestamp, bool isClaimable) = strategy.getDepositRequestOf(account1);
            assertEq(assets, 0.6 ether);
            assertEq(timestamp, block.timestamp);
            assertFalse(isClaimable);
        }

        vm.stopPrank();

        skip(1 seconds);
        _submitReport();

        vm.startPrank(account1);

        {
            (uint256 assets, uint256 timestamp, bool isClaimable) = strategy.getDepositRequestOf(account1);
            assertEq(assets, 0.6 ether);
            assertEq(timestamp, block.timestamp - 1);
            assertTrue(isClaimable);
        }

        strategy.claimShares();

        {
            (uint256 assets, uint256 timestamp, bool isClaimable) = strategy.getDepositRequestOf(account1);
            assertEq(assets, 0);
            assertEq(timestamp, 0);
            assertFalse(isClaimable);
        }
    }

    function testGetDepositRequestOf_ZeroQueue() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: false}));

        address account1 = makeAddr("account1");
        {
            (uint256 assets, uint256 timestamp, bool isClaimable) = strategy.getDepositRequestOf(account1);
            assertEq(assets, 0);
            assertEq(timestamp, 0);
            assertFalse(isClaimable);
        }
    }

    function testGetUncheckedWstethReport_revertsUnsupportedAsset() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        {
            (bool isSuspicious, uint256 priceD18, uint32 timestamp) = strategy.getUncheckedWstETHReport();
            assertFalse(isSuspicious);
            assertEq(priceD18, IWstETH(wsteth).getStETHByWstETH(1 ether));
            assertEq(uint256(timestamp), block.timestamp);
        }

        vm.startPrank(vaultAdmin);
        {
            IVault(vault).grantRole(REMOVE_SUPPORTED_ASSETS_ROLE, vaultAdmin);
            address[] memory assets = new address[](1);
            assets[0] = wsteth;
            vm.mockCall(vault, abi.encodeCall(IVault.getQueueCount, (wsteth)), abi.encode(0));
            IVault(vault).oracle().removeSupportedAssets(assets);
        }
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("UnsupportedAsset(address)", wsteth));
        strategy.getUncheckedWstETHReport();
    }

    function testGetUncheckedWstethReport_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));
        // https://www.getfoundry.sh/guides/stack-too-deep#cheatcode-compatibility
        uint256 initTimestamp = vm.getBlockTimestamp();
        uint256 initRate = IWstETH(wsteth).getStETHByWstETH(1 ether);
        {
            (bool isSuspicious, uint256 priceD18, uint32 timestamp) = strategy.getUncheckedWstETHReport();
            assertFalse(isSuspicious);
            assertEq(priceD18, initRate);
            assertEq(uint256(timestamp), initTimestamp);
        }

        {
            vm.mockCall(wsteth, abi.encodeCall(IWstETH.getStETHByWstETH, (1 ether)), abi.encode(initRate + 1 gwei));
            vm.warp(initTimestamp + 1);
            _submitReport();
        }

        {
            (bool isSuspicious, uint256 priceD18, uint32 timestamp) = strategy.getUncheckedWstETHReport();
            assertFalse(isSuspicious);
            assertEq(priceD18, initRate + 1 gwei);
            assertEq(uint256(timestamp), initTimestamp + 1);
        }

        {
            vm.mockCall(wsteth, abi.encodeCall(IWstETH.getStETHByWstETH, (1 ether)), abi.encode(initRate - 1 gwei));
            vm.warp(initTimestamp + 2);
            _submitReport();
        }

        {
            (bool isSuspicious, uint256 priceD18, uint32 timestamp) = strategy.getUncheckedWstETHReport();
            assertFalse(isSuspicious);
            assertEq(priceD18, initRate - 1 gwei);
            assertEq(uint256(timestamp), initTimestamp + 2);
        }
    }

    function testGetRedeemQueueRequests_Success() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        address account1 = makeAddr("account1");
        vm.startPrank(account1);
        assertEq(strategy.getRedeemQueueRequests(account1, 0, type(uint256).max).length, 0);

        bytes memory data = abi.encode(MellowStrategy.MellowSupplyParams({isSync: true, merkleProof: new bytes32[](0)}));

        deal(account1, 1 ether);
        strategy.supply{value: 1 ether}(address(0), 0.6 ether, data);

        assertEq(strategy.getRedeemQueueRequests(account1, 0, type(uint256).max).length, 0);

        uint256 shares = strategy.sharesOf(account1);

        bytes32 requestId = strategy.requestExitByShares(shares / 2, "");
        assertEq(requestId, strategy.requestExitByShares(shares - shares / 2, ""));

        IRedeemQueue.Request[] memory requests = strategy.getRedeemQueueRequests(account1, 0, type(uint256).max);
        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0);
        assertEq(requests[0].isClaimable, false);
        assertEq(requests[0].timestamp, vm.getBlockTimestamp());

        vm.stopPrank();

        skip(1);
        _submitReport();

        vm.startPrank(account1);
        requests = strategy.getRedeemQueueRequests(account1, 0, type(uint256).max);
        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0.6 ether);
        assertEq(requests[0].isClaimable, false);
        assertEq(requests[0].timestamp, vm.getBlockTimestamp() - 1);

        IRedeemQueue(asyncRedeemWstethQueue).handleBatches(1);

        requests = strategy.getRedeemQueueRequests(account1, 0, type(uint256).max);
        assertEq(requests.length, 1);
        assertEq(requests[0].shares, shares);
        assertEq(requests[0].assets, 0.6 ether);
        assertEq(requests[0].isClaimable, true);
        assertEq(requests[0].timestamp, vm.getBlockTimestamp() - 1);

        strategy.finalizeRequestExit(requestId);

        requests = strategy.getRedeemQueueRequests(account1, 0, type(uint256).max);
        assertEq(requests.length, 0);

        vm.stopPrank();
    }

    function testSafeTransferERC20_ZeroToken() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "_token"));
        strategy.safeTransferERC20(address(0), address(0), 0);
    }

    function testSafeTransferERC20_ZeroRecipient() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "_recipient"));
        strategy.safeTransferERC20(address(1), address(0), 0);
    }

    function testSafeTransferERC20_ZeroAmount() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "_amount"));
        strategy.safeTransferERC20(address(1), address(1), 0);
    }

    function testSafeTransferERC20_TransferReverts() external {
        _deployStrategy(DeployParams({allowList: false, withReport: true, withSyncQueue: true, withAsyncQueue: true}));

        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(1)));
        strategy.safeTransferERC20(address(1), address(1), 1);
    }
}
