// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {MockVaultHub} from "./MockVaultHub.sol";

contract MockDashboard {
    MockVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;
    
    constructor(address _vaultHub, address _stakingVault) {
        VAULT_HUB = MockVaultHub(_vaultHub);
        STAKING_VAULT = _stakingVault; // Mock staking vault address
    }
    
    function fund() external payable {
        VAULT_HUB.fund{value: msg.value}(STAKING_VAULT);
    }

    function withdrawableValue() external view returns (uint256) {
        // For testing, assume 50% of total value is withdrawable
        return VAULT_HUB.totalValue(STAKING_VAULT) / 2;
    }
    
    function withdraw(address recipient, uint256 etherAmount) external {
        // Mock withdrawal - just transfer ETH if available
        require(address(this).balance >= etherAmount, "Not enough ETH");
        (bool success, ) = recipient.call{value: etherAmount}("");
        require(success, "Transfer failed");
    }
    
    function vaultHub() external view returns (MockVaultHub) {
        return VAULT_HUB;
    }
    
    function stakingVault() external view returns (address) {
        return STAKING_VAULT;
    }
} 