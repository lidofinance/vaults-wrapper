// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

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
import {MockStETH} from "test/mocks/MockStETH.sol";
import {MockVaultHub} from "test/mocks/MockVaultHub.sol";
import {MockWstETH} from "test/mocks/MockWstETH.sol";

contract MellowStrategyTest is Test {
    // Lido contracts
    StvStETHPool public pool;
    MockDashboard public dashboard;
    MockVaultHub public vaultHub;

    address public steth;
    address public wsteth;
    address public eth = address(type(uint160).max / 0xf * 0xe);

    // Mellow contracts
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
    address public owner = makeAddr("owner");
    address public userAlice = makeAddr("userAlice");
    address public userBob = makeAddr("userBob");
    address public withdrawalQueue = makeAddr("withdrawalQueue");
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

    function deployMellowVault() internal {
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

        vm.stopPrank();
    }

    function setUp() external {
        // mocks
        dashboard = new MockDashboardFactory().createMockDashboard(owner);
        steth = address(dashboard.STETH());
        wsteth = address(dashboard.WSTETH());
        vaultHub = dashboard.VAULT_HUB();

        dashboard.fund{value: INITIAL_DEPOSIT}();
        StvStETHPool poolImpl = new StvStETHPool(
            address(dashboard), false, RESERVE_RATIO_GAP_BP, withdrawalQueue, address(0), keccak256("stv.steth.pool")
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), "");

        pool = StvStETHPool(payable(poolProxy));
        pool.initialize(owner, "Test", "stvETH");
    }

    function testConstructorZeroStrategyId() external {
        vm.expectRevert(abi.encodeWithSignature("CallForwarderZeroArgument(string)", "_strategyId"));
        strategy = new MellowStrategy(
            bytes32(0), address(0), address(0), IVault(address(0)), address(0), address(0), address(0), false
        );
    }

    function testConstructorZeroCallForwarderImpl() external {
        vm.expectRevert(abi.encodeWithSignature("CallForwarderZeroArgument(string)", "_strategyCallForwarderImpl"));
        strategy = new MellowStrategy(
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

    function testConstructorInvalidPool() external {
        vm.expectRevert();
        strategy = new MellowStrategy(
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
        strategy = new MellowStrategy(
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

    function testConstructorZeroVault() external {
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "vault"));
        strategy = new MellowStrategy(
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

    function testConstructorZeroDepositQueues() external {
        vm.expectRevert(abi.encodeWithSignature("ZeroArgument(string)", "depositQueues"));
        strategy = new MellowStrategy(
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

    function testConstructorInvalidQueue() external {
        deployMellowVault();

        vm.expectRevert();
        strategy = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(vault),
            address(0xdead),
            address(0),
            address(0),
            false
        );

        vm.expectRevert();
        strategy = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(vault),
            address(0),
            address(0xdead),
            address(0),
            false
        );
    }

    function testConstructorSuccess() external {
        deployMellowVault();

        strategy = new MellowStrategy(
            bytes32("MellowStrategyId"),
            address(new StrategyCallForwarder()),
            address(pool),
            IVault(vault),
            address(syncDepositWstethQueue),
            address(asyncDepositWstethQueue),
            address(asyncRedeemWstethQueue),
            true
        );

        assertEq(address(strategy.POOL()), address(pool));
        assertEq(address(strategy.WSTETH()), address(wsteth));
        assertEq(address(strategy.MELLOW_VAULT()), address(vault));
        assertEq(address(strategy.MELLOW_FEE_MANAGER()), address(IVault(vault).feeManager()));
        assertEq(address(strategy.MELLOW_ORACLE()), address(IVault(vault).oracle()));
        assertEq(address(strategy.MELLOW_SHARE_MANAGER()), address(IVault(vault).shareManager()));
        assertEq(address(strategy.MELLOW_SYNC_DEPOSIT_QUEUE()), address(syncDepositWstethQueue));
        assertEq(address(strategy.MELLOW_ASYNC_DEPOSIT_QUEUE()), address(asyncDepositWstethQueue));
        assertEq(address(strategy.MELLOW_ASYNC_REDEEM_QUEUE()), address(asyncRedeemWstethQueue));
        assertTrue(strategy.ALLOW_LIST_ENABLED());
    }
}
