// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Escrow} from "./Escrow.sol";
import {ExampleStrategy} from "./ExampleStrategy.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

interface IStETH is IERC20 {
    function sharesOf(address account) external view returns (uint256);
}

contract Wrapper is ERC4626, AccessControlEnumerable {
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
    event ImmediateWithdrawal(
        address indexed user,
        uint256 shares,
        uint256 assets
    );
    event EscrowDeposit(address indexed escrow, uint256 amount, uint256 shares);
    event TransferAttempt(
        address from,
        address to,
        uint256 amount,
        uint256 allowance
    );

    event Debug(string message, uint256 value1, uint256 value2);

    constructor(
        address _dashboard,
        address _escrow,
        address _owner,
        string memory name_,
        string memory symbol_
    )
        payable
        ERC20(name_, symbol_)
        // The asset is native ETH. We pass address(0) as a placeholder for the ERC20 asset token.
        // This is safe because we override all functions that would interact with the asset
        // (totalAssets, deposit, withdraw, redeem) to use our own ETH-based logic.
        ERC4626(ERC20(address(0)))
    {
        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());

        if (_escrow != address(0)) {
            ESCROW = Escrow(_escrow);
            escrowAddress = _escrow;
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);

        // Fund the vault with 100 wei to ensure totalAssets is never 0
        // This allows the ERC4626 share calculation logic to work correctly
        // DASHBOARD.fund{value: 100 wei}(); // REMOVED
    }

    // =================================================================================
    // ERC4626 OVERRIDES FOR NATIVE ETH
    // =================================================================================

    function totalAssets() public view override returns (uint256) {
        return VAULT_HUB.totalValue(STAKING_VAULT);
    }

    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        uint256 supply = totalSupply();
        // TODO: replace in favor of the stone?
        if (supply == 0) {
            return assets; // 1:1 for the first deposit
        }
        return super.previewDeposit(assets);
    }

    /**
     * @notice Standard ERC4626 deposit function - DISABLED for this ETH wrapper
     * @dev This function is overridden to revert, as this wrapper only accepts native ETH
     */
    function deposit(
        uint256 /*assets*/,
        address /*receiver*/
    ) public pure override returns (uint256 /*shares*/) {
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
    function depositETH(
        address receiver
    ) public payable returns (uint256 shares) {
        require(msg.value > 0, "Zero deposit");
        require(receiver != address(0), "Invalid receiver");

        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupplyBefore = totalSupply();
        emit Debug("depositETH", totalAssetsBefore, totalSupplyBefore);

        // Calculate shares to be minted based on the assets value BEFORE this deposit.
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard. This increases the totalAssets value.
        DASHBOARD.fund{value: msg.value}();
        // DEV: there is check inside that Wrapper is the Vault owner
        // NB: emit no VaultFunded event because it is emitted in Vault contract

        // Mint the pre-calculated shares to the receiver.
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

    function mintStETHForEscrow(
        uint256 stvShares,
        address stethReceiver
    ) external returns (uint256 mintedStethShares) {
        _transfer(address(ESCROW), address(this), stvShares);
        totalLockedStvShares += stvShares;

        uint256 userEthInPool = _convertToAssets(
            stvShares,
            Math.Rounding.Floor
        );
        uint256 remainingMintingCapacity = DASHBOARD
            .remainingMintingCapacityShares(0);

        // TODO: not all minting capacity is for the user!
        emit Debug(
            "remainingMintingCapacity",
            remainingMintingCapacity,
            userEthInPool
        );

        mintedStethShares = remainingMintingCapacity;
        DASHBOARD.mintShares(stethReceiver, mintedStethShares);
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

    /**
     * @notice Mint stETH from stvToken shares for strategy operations
     * @dev This function is called by the Strategy contract during looping
     * @param stvTokenShares Number of stvToken shares to use for minting
     * @param stethToken Address of the stETH token
     * @return mintedSteth Amount of stETH minted
     */
    function mintStETHFromShares(
        uint256 stvTokenShares,
        address stethToken
    ) external returns (uint256 mintedSteth) {
        require(msg.sender == address(ESCROW), "Only escrow can call");
        require(
            stvTokenShares <= balanceOf(address(ESCROW)),
            "Insufficient stvToken shares"
        );

        // Log allowance before transfer
        uint256 allowance = IERC20(address(this)).allowance(
            address(ESCROW),
            address(this)
        );
        emit TransferAttempt(
            address(ESCROW),
            address(this),
            stvTokenShares,
            allowance
        );

        // Transfer stvToken shares from Escrow to Wrapper
        _transfer(address(ESCROW), address(this), stvTokenShares);

        uint256 stethBeforeMint = IERC20(stethToken).balanceOf(address(ESCROW));
        VAULT_HUB.mintShares(STAKING_VAULT, address(ESCROW), stvTokenShares);
        uint256 stethAfterMint = IERC20(stethToken).balanceOf(address(ESCROW));
        mintedSteth = stethAfterMint - stethBeforeMint;

        return mintedSteth;
    }

    event MintStETHStep(
        string step,
        uint256 value1,
        uint256 value2,
        address addr1,
        address addr2
    );

    event MintStETHCompleted(
        address indexed user,
        uint256 initialShares,
        uint256 totalShares,
        uint256 totalBorrowed
    );

    // =================================================================================
    // RECEIVE FUNCTION
    // =================================================================================

    receive() external payable {
        // Auto-deposit ETH sent directly to the contract
        depositETH(address(this));
    }

    // =================================================================================
    // MANAGEMENT FUNCTIONS
    // =================================================================================

    function setConfirmExpiry(
        uint256 _newConfirmExpiry
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool) {
        return DASHBOARD.setConfirmExpiry(_newConfirmExpiry);
    }

    function setNodeOperatorFeeRate(
        uint256 _newNodeOperatorFeeRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool) {
        return DASHBOARD.setNodeOperatorFeeRate(_newNodeOperatorFeeRate);
    }
}
