// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import {MockVaultHub} from "./MockVaultHub.sol";
import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";

contract MockDashboard {
    MockVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;
    event DashboardFunded(address sender, uint256 amount);

    uint256 public locked;

    constructor(address _vaultHub, address _stakingVault) {
        VAULT_HUB = MockVaultHub(_vaultHub);
        STAKING_VAULT = _stakingVault; // Mock staking vault address
    }

    function fund() external payable {
        emit DashboardFunded(msg.sender, msg.value);
        VAULT_HUB.fund{value: msg.value}(STAKING_VAULT);
    }

    function withdrawableValue() external view returns (uint256) {
        return address(STAKING_VAULT).balance - locked;
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

    receive() external payable {}
}