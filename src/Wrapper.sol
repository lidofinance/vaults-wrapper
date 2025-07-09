// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Escrow} from "./Escrow.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";


contract Wrapper is ERC4626 {

    uint256 public constant E27_PRECISION_BASE = 1e27;

    IDashboard public immutable dashboard;
    IVaultHub public immutable vaultHub;
    address public immutable stakingVault;
    WithdrawalQueue public immutable withdrawalQueue;
    Escrow public immutable escrow;

    bool public autoLeverageEnabled = true;

    event VaultFunded(uint256 amount);
    event AutoLeverageExecuted(address indexed user, uint256 shares);
    event DefaultStrategyUpdated(address indexed strategy);
    event AutoLeverageToggled(bool enabled);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);
    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 shares, uint256 assets);
    event ImmediateWithdrawal(address indexed user, uint256 shares, uint256 assets);

    constructor(
        address _dashboard,
        address _withdrawalQueue,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        // The asset is native ETH. We pass address(0) as a placeholder for the ERC20 asset token.
        // This is safe because we override all functions that would interact with the asset
        // (totalAssets, deposit, withdraw, redeem) to use our own ETH-based logic.
        ERC4626(ERC20(address(0)))
    {
        dashboard = IDashboard(_dashboard);
        vaultHub = dashboard.vaultHub();
        stakingVault = dashboard.stakingVault();
        withdrawalQueue = WithdrawalQueue(_withdrawalQueue);
    }

    // =================================================================================
    // ERC4626 OVERRIDES FOR NATIVE ETH
    // =================================================================================

    function totalAssets() public view override returns (uint256) {
        return vaultHub.totalValue(stakingVault);
    }

    /**
     * @notice Standard ERC4626 deposit function - DISABLED for this ETH wrapper
     * @dev This function is overridden to revert, as this wrapper only accepts native ETH
     */
    function deposit(uint256 /*assets*/, address /*receiver*/) public pure override returns (uint256 /*shares*/) {
        revert("Use depositETH() for native ETH deposits");
    }

    /**
     * @notice Deposit native ETH and receive stvToken shares
     * @param receiver Address to receive the minted shares
     * @return shares Number of shares minted
     */
    function depositETH(address receiver) public payable returns (uint256 shares) {
        require(msg.value > 0, "Zero deposit");
        require(receiver != address(0), "Invalid receiver");

        // Calculate shares to be minted based on the assets value BEFORE this deposit.
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard. This increases the totalAssets value.
        dashboard.fund{value: msg.value}();
        // NB: emit no VaultFunded event cause it is emitted in Vault contract

        // Mint the pre-calculated shares to the receiver.
        _mint(receiver, shares);

        // // Auto-leverage
        // // if (autoLeverageEnabled && address(defaultStrategy) != address(0) && address(escrow) != address(0)) {
        // //     _autoExecuteLeverage(receiver, shares);
        // // }
        emit Deposit(msg.sender, receiver, msg.value, shares);
        return shares;
    }

    /**
     * @notice Convenience function to deposit ETH to msg.sender
     */
    function depositETH() public payable returns (uint256) {
        return depositETH(msg.sender);
    }

    // =================================================================================
    // WITHDRAWAL SYSTEM WITH EXTERNAL QUEUE
    // =================================================================================

    function calculateShareRate() public view returns (uint256) {
        uint256 _vaultTotalAssets = totalAssets();
        uint256 _totalSupply = totalSupply();
        uint256 totalBorrowedAssets = escrow.getTotalBorrowedAssets();

        uint256 userTotalAssets = _vaultTotalAssets - totalBorrowedAssets;

        if (_totalSupply == 0) return E27_PRECISION_BASE; // 1.0

        return (userTotalAssets * E27_PRECISION_BASE) / _totalSupply;
    }

    function withdraw(uint256 shares) external returns (uint256 requestId) {
        require(shares <= maxWithdraw(msg.sender), "ERC4626: withdraw more than max");

        uint256 assets = previewRedeem(shares);

        _burn(msg.sender, shares);

        requestId = withdrawalQueue.requestWithdrawal(msg.sender, shares, assets);
    }

    // =================================================================================
    // RECEIVE FUNCTION
    // =================================================================================

    receive() external payable {
        // Auto-deposit ETH sent directly to the contract
        depositETH(msg.sender);
    }
}