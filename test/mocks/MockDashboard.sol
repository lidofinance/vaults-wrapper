// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {MockVaultHub} from "./MockVaultHub.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";

contract MockDashboard is AccessControlEnumerable {
    MockVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    event DashboardFunded(address sender, uint256 amount);

    uint256 public locked;

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant FUND_ROLE = keccak256("FUND_ROLE");
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");

    constructor(address _vaultHub, address _stakingVault, address _admin) {
        VAULT_HUB = MockVaultHub(_vaultHub);
        STAKING_VAULT = _stakingVault; // Mock staking vault address
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
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

    // Mock implementation for minting stETH
    function mintShares(address to, uint256 amount) external {
        // Mock implementation - just emit an event or do nothing
    }

    function burnShares(uint256 amount) external {
        // Mock implementation
    }

    function remainingMintingCapacityShares(uint256 vaultId) external pure returns (uint256) {
        return 1000 ether; // Mock large capacity
    }

    function totalMintingCapacityShares() external pure returns (uint256) {
        return 1000 ether; // Mock large capacity
    }

    function reserveRatioBP() external pure returns (uint256) {
        return 500; // 5% reserve ratio for testing
    }

    function requestValidatorExit(bytes calldata pubkeys) external {
        // Mock implementation
    }

    function triggerValidatorWithdrawals(bytes calldata pubkeys, uint64[] calldata amounts, address refundRecipient)
        external
        payable
    {
        // Mock implementation
    }

    function voluntaryDisconnect() external {
        // Mock implementation
    }

    receive() external payable {}
}
