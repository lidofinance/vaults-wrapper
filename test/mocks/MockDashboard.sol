// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {MockStETH} from "./MockStETH.sol";
import {MockVaultHub} from "./MockVaultHub.sol";
import {MockStakingVault} from "./MockStakingVault.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";
import {IVaultHub} from "../../src/interfaces/IVaultHub.sol";

contract MockDashboard is AccessControlEnumerable {
    MockStETH public immutable STETH;
    MockVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    event DashboardFunded(address sender, uint256 amount);

    uint256 public locked;

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    constructor(address _steth, address _vaultHub, address _stakingVault, address _admin) {
        STETH = MockStETH(_steth);
        VAULT_HUB = MockVaultHub(payable(_vaultHub));
        STAKING_VAULT = _stakingVault; // Mock staking vault address
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        // Set default report freshness to true
        VAULT_HUB.mock_setReportFreshness(STAKING_VAULT, true);
    }

    function fund() external payable {
        emit DashboardFunded(msg.sender, msg.value);
        VAULT_HUB.fund{value: msg.value}(STAKING_VAULT);
    }

    function withdrawableValue() external view returns (uint256) {
        return address(STAKING_VAULT).balance - locked;
    }

    function maxLockableValue() external view returns (uint256) {
        return VAULT_HUB.totalValue(STAKING_VAULT);
    }

    function withdraw(address recipient, uint256 etherAmount) external {
        VAULT_HUB.withdraw(STAKING_VAULT, recipient, etherAmount);
    }

    function vaultHub() external view returns (MockVaultHub) {
        return VAULT_HUB;
    }

    function stakingVault() external view returns (address) {
        return STAKING_VAULT;
    }

    function mock_setLocked(uint256 _locked) external {
        locked = _locked;
    }

    function mock_simulateRewards(int256 amount) external {
        VAULT_HUB.mock_simulateRewards(STAKING_VAULT, amount);
    }

    function mock_increaseLiability(uint256 amount) external {
        VAULT_HUB.mock_increaseLiability(STAKING_VAULT, amount);
    }

    function liabilityShares() external view returns (uint256) {
        return VAULT_HUB.vaultLiabilityShares(STAKING_VAULT);
    }

    // Mock implementation for minting stETH
    function mintShares(address to, uint256 amount) external {
        VAULT_HUB.mintShares(STAKING_VAULT, to, amount);
    }

    function burnShares(uint256 amount) external {
        STETH.transferSharesFrom(msg.sender, address(VAULT_HUB), amount);
        VAULT_HUB.burnShares(STAKING_VAULT, amount);
    }

    function remainingMintingCapacityShares(uint256 /* vaultId */) external pure returns (uint256) {
        return 1000 ether; // Mock large capacity
    }

    function totalMintingCapacityShares() external pure returns (uint256) {
        return 1000 ether; // Mock large capacity
    }

    function vaultConnection() external view returns (IVaultHub.VaultConnection memory) {
        return VAULT_HUB.vaultConnection(STAKING_VAULT);
    }

    function requestValidatorExit(bytes calldata pubkeys) external {
        // Mock implementation
    }

    function triggerValidatorWithdrawals(bytes calldata pubkeys, uint64[] calldata amountsInGwei, address refundRecipient)
        external
        payable
    {
        // Mock implementation
    }

    function rebalanceVaultWithShares(uint256 _shares) external {
        _rebalanceVault(_shares);
    }

    function rebalanceVaultWithEther(uint256 _ether) external payable {
        _rebalanceVault(STETH.getSharesByPooledEth(_ether));
        VAULT_HUB.fund{value: msg.value}(STAKING_VAULT);
    }

    function _rebalanceVault(uint256 _shares) internal {
        VAULT_HUB.rebalance(STAKING_VAULT, _shares);
    }

    function voluntaryDisconnect() external {
        // Mock implementation
    }

    receive() external payable {}
}

contract MockDashboardFactory {
    function createMockDashboard(address _owner) external returns (MockDashboard) {
        MockVaultHub vaultHub = new MockVaultHub();
        MockStakingVault stakingVault = new MockStakingVault();
        vaultHub.mock_setConnectionParameters(address(stakingVault), 10_00, 10_25); // 10% reserve, 10.25% forced rebalance

        MockStETH steth = MockStETH(vaultHub.LIDO());
        steth.mock_setTotalPooled(1000 ether, 800 * 10 ** 18);

        MockDashboard dashboard = new MockDashboard(address(steth), address(vaultHub), address(stakingVault), _owner);

        return dashboard;
    }
}
