// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Escrow} from "./Escrow.sol";
import {ExampleStrategy} from "./ExampleStrategy.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";


interface IStETH is IERC20 {
    function sharesOf(address account) external view returns (uint256);
}

contract Wrapper is ERC4626 {

    uint256 public constant E27_PRECISION_BASE = 1e27;

    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    WithdrawalQueue public withdrawalQueue;
    Escrow public ESCROW;

    uint256 public totalLockedStvShares;

    bool public autoLeverageEnabled = true;
    address public escrowAddress; // Temporary storage for escrow address
    mapping(address => uint256) public lockedStvSharesByUser;


    event VaultFunded(uint256 amount);
    event AutoLeverageExecuted(address indexed user, uint256 shares);
    event DefaultStrategyUpdated(address indexed strategy);
    event AutoLeverageToggled(bool enabled);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);
    event ImmediateWithdrawal(address indexed user, uint256 shares, uint256 assets);
    event EscrowDeposit(address indexed escrow, uint256 amount, uint256 shares);
    event TransferAttempt(address from, address to, uint256 amount, uint256 allowance);

    event Debug(string message, uint256 value1, uint256 value2);

    constructor(
        address _dashboard,
        address _escrow,
        address _initialBalanceOwner,
        string memory name_,
        string memory symbol_
    ) payable
        ERC20(name_, symbol_)
        // The asset is native ETH. We pass address(0) as a placeholder for the ERC20 asset token.
        // This is safe because we override all functions that would interact with the asset
        // (totalAssets, deposit, withdraw, redeem) to use our own ETH-based logic.
        ERC4626(ERC20(address(0)))
    {
        // TODO: check _initialBalanceOwner

        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());
        if (_escrow != address(0)) {
            ESCROW = Escrow(_escrow);
            escrowAddress = _escrow;
        }

        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        if (initialVaultBalance > 0) {
            uint256 shares = previewDeposit(initialVaultBalance);
            _mint(_initialBalanceOwner, shares);
        }

    }

    // =================================================================================
    // ERC4626 OVERRIDES FOR NATIVE ETH
    // =================================================================================

    function totalAssets() public view override returns (uint256) {
        return VAULT_HUB.totalValue(STAKING_VAULT);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        // TODO: replace in favor of the stone?
        if (supply == 0) {
            return assets; // 1:1 for the first deposit
        }
        return super.previewDeposit(assets);
    }

    // TODO?: implement maxRedeem, previewWithdraw, previewRedeem, withdraw, redeem, mint, maxMint, mintPreview

    /**
     * @notice Returns the maximum amount of underlying assets that can be withdrawn for a given owner
     * @param owner The address to check withdrawal limits for
     * @return Maximum withdrawable assets
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @notice Standard ERC4626 deposit function - DISABLED for this ETH wrapper
     * @dev This function is overridden to revert, as this wrapper only accepts native ETH
     */
    function deposit(uint256 /*assets*/, address /*receiver*/) public pure override returns (uint256 /*shares*/) {
        revert("Use depositETH() for native ETH deposits");
    }


    /**
     * @notice Convenience function to deposit ETH to msg.sender
     */
    function depositETH() public payable returns (uint256) {
        return depositETH(msg.sender);
    }

    /**
     * @notice Deposit native ETH and receive stvToken shares
     * @param receiver Address to receive the minted shares
     * @return shares Number of shares minted
     */
    function depositETH(address receiver) public payable returns (uint256 shares) {
        require(msg.value > 0, "Zero deposit");
        require(receiver != address(0), "Invalid receiver");

        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupplyBefore = totalSupply();

        // Calculate shares to be minted based on the assets value BEFORE this deposit.
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard. This increases the totalAssets value.
        DASHBOARD.fund{value: msg.value}();
        // DEV: there is check inside that Wrapper is the Vault owner
        // NB: emit no VaultFunded event because it is emitted in Vault contract

        _mint(receiver, shares);

        // // Auto-leverage
        // // if (autoLeverageEnabled && address(defaultStrategy) != address(0) && address(escrow) != address(0)) {
        // //     _autoExecuteLeverage(receiver, shares);
        // // }
        emit Deposit(msg.sender, receiver, msg.value, shares);
        assert(totalAssets() == totalAssetsBefore + msg.value);
        assert(totalSupply() == totalSupplyBefore + shares);
        return shares;
    }

    // =================================================================================
    // WITHDRAWAL SYSTEM WITH EXTERNAL QUEUE
    // =================================================================================

    function burnShares(uint256 shares) external {
        _burn(msg.sender, shares);
    }

    function setWithdrawalQueue(address _withdrawalQueue) external {
        withdrawalQueue = WithdrawalQueue(payable(_withdrawalQueue));
    }

    /**
     * @notice Set the escrow address after construction
     * @dev This is needed to resolve circular dependency
     */
    function setEscrowAddress(address _escrow) external {
        require(escrowAddress == address(0), "Escrow already set");
        require(_escrow != address(0), "Invalid escrow address");
        ESCROW = Escrow(_escrow);
        escrowAddress = _escrow;
    }


    // =================================================================================
    // RECEIVE FUNCTION
    // =================================================================================

    receive() external payable {
        // Auto-deposit ETH sent directly to the contract
        depositETH(address(this));
    }
}
