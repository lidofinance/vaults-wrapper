// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStakingVault {
    function fund() external payable;
}

contract MockVaultHub {

    mapping(address => uint256) public vaultBalances;
    mapping(address => uint256) public vaultLiabilityShares;
    
    constructor() {}
    
    function mintShares(address to, uint256 amount) external {
        vaultLiabilityShares[to] += amount;
    }
    
    function burnShares(address from, uint256 amount) external {
        vaultLiabilityShares[from] -= amount;
    }
    
    function fund(address _vault) external payable {
        vaultBalances[_vault] += msg.value;
        IStakingVault(_vault).fund{value: msg.value}();
    }

    function totalValue(address _vault) external view returns (uint256) {
        return vaultBalances[_vault];
    }

    function liabilityShares(address _vault) external view returns (uint256) {
        return vaultLiabilityShares[_vault];
    }

    function requestValidatorExit(address _vault, bytes calldata _pubkeys) external {
        // Mock implementation - just emit an event or do nothing
        // In real implementation, this would request node operators to exit validators
    }

    function mock_simulateRewards(address _vault, int256 _rewardAmount) external {
        if (_rewardAmount > 0) {
            vaultBalances[_vault] += uint256(_rewardAmount);
        } else {
            // Handle slashing (negative rewards)
            uint256 loss = uint256(-_rewardAmount);
            if (loss > vaultBalances[_vault]) {
                vaultBalances[_vault] = 0;
            } else {
                vaultBalances[_vault] -= loss;
            }
        }
    }

    // function triggerValidatorWithdrawals(
    //     address _vault,
    //     bytes calldata _pubkeys,
    //     uint64[] calldata _amounts,
    //     address _refundRecipient
    // ) external payable {
    //     // Mock implementation - simulate validator withdrawals
    //     // In real implementation, this would trigger EIP-7002 withdrawals
        
    //     // For testing, we can simulate that validators were exited and funds are now available
    //     uint256 totalWithdrawn = 0;
    //     for (uint256 i = 0; i < _amounts.length; i++) {
    //         if (_amounts[i] == 0) {
    //             // Full withdrawal (32 ETH per validator)
    //             totalWithdrawn += 32 ether;
    //         } else {
    //             totalWithdrawn += _amounts[i];
    //         }
    //     }
        
    //     // Add withdrawn funds to withdrawable balance
    //     vaultWithdrawableBalances[_vault] += totalWithdrawn;
        
    //     // Refund excess fee
    //     if (msg.value > 0 && _refundRecipient != address(0)) {
    //         payable(_refundRecipient).transfer(msg.value);
    //     }
    // }


    /**
     * @notice Test-only function to simulate validator exits making funds withdrawable
     */
    function simulateValidatorExits(address _vault, uint256 _amount) external {
        // vaultWithdrawableBalances[_vault] += _amount;
        // // Also increase the contract's actual balance to allow for withdrawals
        // payable(address(this)).transfer(_amount);
    }
} 