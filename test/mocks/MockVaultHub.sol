// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockStETH} from "./MockStETH.sol";
import {IVaultHub} from "src/interfaces/IVaultHub.sol";
import {IStakingVault} from "../../src/interfaces/IStakingVault.sol";

contract MockVaultHub {
    // TODO: maybe inherit IVaultHub


    uint256 public immutable RESERVE_RATIO_BP = 25_00;
    uint256 internal immutable TOTAL_BASIS_POINTS = 100_00;
    MockStETH public immutable LIDO;

    mapping(address => uint256) public vaultBalances;
    mapping(address => uint256) public vaultLiabilityShares;
    mapping(address => bool) public vaultReportFreshness;

    constructor() {
        LIDO = new MockStETH();
    }

    receive() external payable {}

    function mintShares(address _vault, address _recipient, uint256 _amountOfShares) external {
        vaultLiabilityShares[_vault] += _amountOfShares;
        require(vaultLiabilityShares[_vault] <= maxLockableValue(_vault), "Vault liability exceeds max lockable value");

        // Mint stETH tokens to the recipient (simulating the vault minting stETH)
        LIDO.mock_mintExternalShares(_recipient, _amountOfShares);
    }

    function maxLockableValue(address _vault) public view returns (uint256) {
        return (vaultBalances[_vault] * (TOTAL_BASIS_POINTS - RESERVE_RATIO_BP)) / TOTAL_BASIS_POINTS;
    }

    function vaultConnection(address /* _vault */) external pure returns (IVaultHub.VaultConnection memory) {
        return IVaultHub.VaultConnection({
            owner: address(0),
            shareLimit: 0,
            vaultIndex: 0,
            disconnectInitiatedTs: type(uint48).max,
            reserveRatioBP: 0,
            forcedRebalanceThresholdBP: 0,
            infraFeeBP: 0,
            liquidityFeeBP: 0,
            reservationFeeBP: uint16(RESERVE_RATIO_BP),
            isBeaconDepositsManuallyPaused: false
        });
    }

    function burnShares(address from, uint256 amount) external {
        vaultLiabilityShares[from] -= amount;
    }

    event VaultHubFunded(address sender, address vault, uint256 amount);
    function fund(address _vault) external payable {
        emit VaultHubFunded(msg.sender, _vault, msg.value);
        vaultBalances[_vault] += msg.value;
        IStakingVault(_vault).fund{value: msg.value}();
    }

    function withdraw(address _vault, address _recipient, uint256 _amount) external {
        vaultBalances[_vault] -= _amount;
        IStakingVault(_vault).withdraw(_recipient, _amount);
    }

    function rebalance(address _vault, uint256 _shares) external {
        uint256 valueToRebalance = LIDO.getPooledEthBySharesRoundUp(_shares);
        vaultLiabilityShares[_vault] -= _shares;
        vaultBalances[_vault] -= valueToRebalance;
        IStakingVault(_vault).withdraw(address(this), valueToRebalance);
    }

    function totalValue(address _vault) external view returns (uint256) {
        return vaultBalances[_vault];
    }

    function withdrawableValue(address /* _vault */) external pure returns (uint256) {
        return 0; // Dummy implementation - returns 0 for testing
    }

    function liabilityShares(address _vault) external view returns (uint256) {
        return vaultLiabilityShares[_vault];
    }

    function requestValidatorExit(address /* _vault */, bytes calldata /* _pubkeys */) external {
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

    function mock_increaseLiability(address _vault, uint256 _amount) external {
        vaultLiabilityShares[_vault] += _amount;
    }

    function triggerValidatorWithdrawals(
        address /* _vault */,
        bytes calldata /* _pubkeys */,
        uint64[] calldata /* _amountsInGwei */,
        address /* _refundRecipient */
    ) external payable {
    //     // Mock implementation - simulate validator withdrawals
    //     // In real implementation, this would trigger EIP-7002 withdrawals

    //     // For testing, we can simulate that validators were exited and funds are now available
    //     uint256 totalWithdrawn = 0;
    //     for (uint256 i = 0; i < _amountsInGwei.length; i++) {
    //         if (_amountsInGwei[i] == 0) {
    //             // Full withdrawal (32 ETH per validator)
    //             totalWithdrawn += 32 ether;
    //         } else {
    //             totalWithdrawn += _amountsInGwei[i];
    //         }
    //     }

    //     // Add withdrawn funds to withdrawable balance
    //     vaultWithdrawableBalances[_vault] += totalWithdrawn;

    //     // Refund excess fee
    //     if (msg.value > 0 && _refundRecipient != address(0)) {
    //         payable(_refundRecipient).transfer(msg.value);
    //     }
    }

    /**
     * @notice Test-only function to simulate validator exits making funds withdrawable
     */
    function simulateValidatorExits(address /* _vault */, uint256 /* _amount */) external {
        // vaultWithdrawableBalances[_vault] += _amount;
        // // Also increase the contract's actual balance to allow for withdrawals
        // payable(address(this)).transfer(_amount);
    }

    function CONNECT_DEPOSIT() external pure returns (uint256) {
        return 1 ether;
    }

    function transferVaultOwnership(address /* _vault */, address /* _newOwner */) external pure {
        revert("Not implemented");
    }

    function isReportFresh(address _vault) external view returns (bool) {
        return vaultReportFreshness[_vault];
    }

    function mock_setVaultBalance(address _vault, uint256 _balance) external {
        vaultBalances[_vault] = _balance;
    }

    function mock_setReportFreshness(address _vault, bool _isFresh) external {
        vaultReportFreshness[_vault] = _isFresh;
    }
}
