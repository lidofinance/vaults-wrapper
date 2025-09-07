// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import {Test, console} from "forge-std/Test.sol";

import {CoreHarness} from "test/utils/CoreHarness.sol";
import {IDashboard} from "src/interfaces/IDashboard.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {ILido} from "src/interfaces/ILido.sol";

import {WrapperB} from "src/WrapperB.sol";
import {WithdrawalQueue} from "src/WithdrawalQueue.sol";
import {IVaultFactory} from "src/interfaces/IVaultFactory.sol";
import {Factory} from "src/Factory.sol";

/**
 * @title WrapperHarness
 * @notice Helper contract for integration tests that provides common setup for wrapper system
 */
contract WrapperHarness is Test {
    CoreHarness public core;

    WrapperB public wrapper_;
    WithdrawalQueue public withdrawalQueue;

    IDashboard public dashboard;
    IStakingVault public vault;

    // Core contracts
    ILido public steth;
    IVaultHub public vaultHub;

    // Test users
    address public constant USER1 = address(0x1001);
    address public constant USER2 = address(0x1002);
    address public constant USER3 = address(0x1003);

    address public constant NODE_OPERATOR = address(0x1004);

    // Test constants
    uint256 public constant WEI_ROUNDING_TOLERANCE = 1;
    uint256 public CONNECT_DEPOSIT;
    uint256 public constant NODE_OPERATOR_FEE_RATE = 0; // 0%
    uint256 public constant CONFIRM_EXPIRY = 1 hours;

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;
    uint256 public constant RESERVE_RATIO_BP = 20_00; // not configurable
    uint256 public immutable EXTRA_BASE = 10 ** (27 - 18); // not configurable

    function _setUp(
        Factory.WrapperConfiguration configuration,
        address strategy,
        bool enableAllowlist
    ) internal {
        core = new CoreHarness("lido-core/deployed-local.json");
        steth = core.steth();
        vaultHub = core.vaultHub();

        address vaultFactory = core.locator().vaultFactory();
        CONNECT_DEPOSIT = vaultHub.CONNECT_DEPOSIT();

        vm.deal(NODE_OPERATOR, 1000 ether);

        Factory factory = new Factory(vaultFactory, address(steth));

        vm.startPrank(NODE_OPERATOR);
        (address vault_, address dashboard_, address payable wrapper, address withdrawalQueue_) = factory.createVaultWithWrapper{value: CONNECT_DEPOSIT}(
            NODE_OPERATOR, NODE_OPERATOR, NODE_OPERATOR_FEE_RATE, CONFIRM_EXPIRY, configuration, strategy, enableAllowlist
        );
        vm.stopPrank();

        wrapper_ = WrapperB(payable(wrapper));
        withdrawalQueue = WithdrawalQueue(payable(withdrawalQueue_));

        vault = IStakingVault(vault_);
        dashboard = IDashboard(payable(dashboard_));

        core.setStethShareRatio(1 ether + 10 ** 17); // 1.1 ETH

        core.applyVaultReport(address(vault), 0, 0, 0, 0, true);

        vm.deal(USER1, 100_000 ether);
        vm.deal(USER2, 100_000 ether);
        vm.deal(USER3, 100_000 ether);

        // Perform initial state checks that were previously in test_initial_state
        _checkInitialState();
    }

    function _checkInitialState() internal {
        console.log("=== Initial State ===");
        assertEq(dashboard.reserveRatioBP(), RESERVE_RATIO_BP, "Reserve ratio should match RESERVE_RATIO_BP constant");
        assertEq(wrapper_.EXTRA_DECIMALS_BASE(), EXTRA_BASE, "EXTRA_DECIMALS_BASE should match EXTRA_DECIMALS_BASE constant");

        assertEq(wrapper_.totalSupply(), CONNECT_DEPOSIT * EXTRA_BASE, "Total stvETH supply should be equal to CONNECT_DEPOSIT");
        assertEq(wrapper_.balanceOf(address(wrapper_)), CONNECT_DEPOSIT * EXTRA_BASE, "Wrapper stvETH balance should be equal to CONNECT_DEPOSIT");

        assertEq(wrapper_.balanceOf(NODE_OPERATOR), 0, "stvETH balance of NODE_OPERATOR should be zero");
        assertEq(steth.balanceOf(NODE_OPERATOR), 0, "stETH balance of node operator should be zero");

        assertEq(dashboard.locked(), CONNECT_DEPOSIT, "Vault's locked should be zero");
        assertEq(dashboard.maxLockableValue(), CONNECT_DEPOSIT, "Vault's total value should be CONNECT_DEPOSIT");
        assertEq(dashboard.withdrawableValue(), 0, "Vault's withdrawable value should be zero");
        assertEq(dashboard.liabilityShares(), 0, "Vault's liability shares should be zero");
        assertEq(dashboard.remainingMintingCapacityShares(0), 0, "Remaining minting capacity should be zero");
        assertEq(dashboard.totalMintingCapacityShares(), 0, "Total minting capacity should be zero");

        assertEq(steth.getPooledEthByShares(1 ether), 1 ether + 10 ** 17, "ETH for 1e18 stETH shares should be 1.1 ETH");

        console.log("Reserve ratio:", dashboard.reserveRatioBP());
        console.log("ETH for 1e18 stETH shares: ", steth.getPooledEthByShares(1 ether));

        // Initially, the vault has no minting capacity, so _calcMaxMintableStShares should return 0
        assertEq(wrapper_._calcYetMintableStShares(USER1), 0, "Yet mintable stETH shares should be 0 when vault has no minting capacity");

        // The calculation itself would return 7272 shares if there was capacity
        // (10000 - 2000 reserve) * shares ratio = 8000 / 1.1 = 7272 shares

        _assertUniversalInvariants("Initial state");
    }

    function _assertUniversalInvariants(string memory _context) internal {

        assertEq(
            wrapper_.previewRedeem(wrapper_.totalSupply()),
            wrapper_.totalAssets(),
            _contextMsg(_context, "previewRedeem(totalSupply) should equal totalAssets")
        );

        address[] memory holders = new address[](5);
        holders[0] = USER1;
        holders[1] = USER2;
        holders[2] = USER3;
        holders[3] = address(wrapper_);
        holders[4] = address(withdrawalQueue);

        {
            uint256 totalBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalBalance += wrapper_.balanceOf(holders[i]);
            }
            assertEq(
                totalBalance,
                wrapper_.totalSupply(),
                _contextMsg(_context, "Sum of all holders' balances should equal totalSupply")
            );
        }

        {   // TODO: what's about 1 wei accuracy?
            uint256 totalPreviewRedeem = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalPreviewRedeem += wrapper_.previewRedeem(wrapper_.balanceOf(holders[i]));
            }
            uint256 totalAssets = wrapper_.totalAssets();
            uint256 diff = totalPreviewRedeem > totalAssets
                ? totalPreviewRedeem - totalAssets
                : totalAssets - totalPreviewRedeem;
            assertTrue(
                diff <= 1,
                _contextMsg(_context, "Sum of previewRedeem of all holders should equal totalAssets (within 1 wei accuracy)")
            );
        }

        {
            // The sum of all stETH balances (users + wrapper) should approximately equal the stETH minted for all liability shares
            uint256 totalStethBalance = 0;
            for (uint256 i = 0; i < holders.length; i++) {
                totalStethBalance += steth.balanceOf(holders[i]);
            }

            uint256 totalMintedSteth = steth.getPooledEthByShares(dashboard.liabilityShares());
            assertApproxEqAbs(
                totalStethBalance,
                totalMintedSteth,
                holders.length * WEI_ROUNDING_TOLERANCE, // TODO: think about proper rounding error tolerance
                _contextMsg(_context, "Sum of all stETH balances (users + wrapper) should approximately equal stETH minted for liability shares")
            );
        }

        {   // Check none can mint beyond mintableStShares
            for (uint256 i = 0; i < holders.length; i++) {
                address holder = holders[i];
                uint256 mintableStShares = wrapper_.mintableStShares(holder);
                vm.startPrank(holder);
                vm.expectRevert("InsufficientMintableStShares()");
                wrapper_.mintStShares(mintableStShares + 1);
                vm.stopPrank();
            }
        }

        // TODO: Check that the reserve ratio is maintained

    }

    function _contextMsg(string memory _context, string memory _msg) internal pure returns (string memory) {
        return string(abi.encodePacked(_context, ": ", _msg));
    }
}