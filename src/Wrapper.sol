// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {ExampleStrategy} from "./ExampleStrategy.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

interface IStETH is IERC20 {
    function sharesOf(address account) external view returns (uint256);
}

// Custom errors
error NotWhitelisted(address user);
error WhitelistFull();
error AlreadyWhitelisted(address user);
error NotInWhitelist(address user);
error ZeroDeposit();
error InvalidReceiver();
error NoMintingCapacityAvailable();
error ZeroStvShares();

contract Wrapper is ERC4626, AccessControlEnumerable {
    uint256 public constant E27_PRECISION_BASE = 1e27;
    uint256 public constant MAX_WHITELIST_SIZE = 1000;
    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");

    bool public immutable WHITELIST_ENABLED;

    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    WithdrawalQueue public withdrawalQueue;
    IStrategy public STRATEGY;
    IERC20 public immutable STETH;

    uint256 public totalLockedStvShares;
    uint256 public totalBorrowedAssets;
    uint256 public nextPositionId;

    bool public autoLeverageEnabled = true;
    mapping(address => uint256) public lockedStvSharesByUser;
    mapping(address => bool) public authorizedStrategies;

    struct Position {
        address user;
        uint256 stvTokenShares;
        uint256 borrowedAssets;
        uint256 positionId;
        uint256 withdrawalRequestId;
        bool isActive;
        bool isExiting;
        uint256 timestamp;
        uint256 totalStvTokenShares;
    }

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
    event TransferAttempt(
        address from,
        address to,
        uint256 amount,
        uint256 allowance
    );
    event PositionOpened(
        address indexed user,
        uint256 indexed positionId,
        uint256 stvTokenShares,
        uint256 borrowedAssets
    );
    event PositionClosing(
        address indexed user,
        uint256 indexed positionId,
        uint256 withdrawalRequestId
    );
    event PositionClaimed(
        address indexed user,
        uint256 indexed positionId,
        uint256 assets
    );
    event AllowanceSet(address indexed owner, address indexed spender, uint256 amount);

    event Debug(string message, uint256 value1, uint256 value2);
    event WhitelistAdded(address indexed user);
    event WhitelistRemoved(address indexed user);

    constructor(
        address _dashboard,
        address _strategy,
        address _steth,
        address _owner,
        string memory name_,
        string memory symbol_,
        bool _whitelistEnabled
    )
        payable
        ERC20(name_, symbol_)
        // The asset is native ETH. We pass address(0) as a placeholder for the ERC20 asset token.
        // This is safe because we override all functions that would interact with the asset
        // (totalAssets, deposit, withdraw, redeem) to use our own ETH-based logic.
        ERC4626(ERC20(address(0)))
    {
        WHITELIST_ENABLED = _whitelistEnabled;

        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());
        
        if (_strategy != address(0)) {
            STRATEGY = IStrategy(_strategy);
        }
        
        STETH = IERC20(_steth);

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);

        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        if (initialVaultBalance > 0) {
            uint256 shares = previewDeposit(initialVaultBalance);
            _mint(_owner, shares);
        }
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
        if (msg.value == 0) revert ZeroDeposit();
        if (receiver == address(0)) revert InvalidReceiver();

        // Check whitelist if enabled
        if (WHITELIST_ENABLED && !hasRole(DEPOSIT_ROLE, msg.sender)) {
            revert NotWhitelisted(msg.sender);
        }

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
     * @notice Set the strategy address after construction
     * @dev This is needed to resolve circular dependency
     */
    function setStrategy(address _strategy) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        STRATEGY = IStrategy(_strategy);
    }

    // =================================================================================
    // ESCROW FUNCTIONALITY (Moved from Escrow.sol)
    // =================================================================================

    function openPosition(uint256 stvShares) external {
        _transfer(msg.sender, address(STRATEGY), stvShares);
        STRATEGY.execute(msg.sender, stvShares);
    }

    function closePosition(uint256 stvShares) external {
        STRATEGY.finalizeExit(msg.sender);
        stvShares = stvShares; // TODO
    }

    function mintStETH(uint256 stvShares) external returns (uint256 mintedStethShares) {
        if (stvShares == 0) revert ZeroStvShares();

        _transfer(msg.sender, address(this), stvShares);
        lockedStvSharesByUser[msg.sender] += stvShares;

        uint256 remainingMintingCapacity = DASHBOARD.remainingMintingCapacityShares(0);
        uint256 totalMintingCapacity = DASHBOARD.totalMintingCapacityShares();
        assert(remainingMintingCapacity <= totalMintingCapacity);

        uint256 userEthInPool = convertToAssets(stvShares);
        uint256 totalVaultAssets = totalAssets();
        uint256 userTotalMintingCapacity = (userEthInPool * totalMintingCapacity) / totalVaultAssets;

        // User can mint up to their fair share, limited by remaining capacity
        mintedStethShares = userTotalMintingCapacity < remainingMintingCapacity ? userTotalMintingCapacity : remainingMintingCapacity;

        if (mintedStethShares == 0) revert NoMintingCapacityAvailable();

        DASHBOARD.mintShares(msg.sender, mintedStethShares);
    }

    function getUserStvShares(address _user) external view returns (uint256) {
        return lockedStvSharesByUser[_user];
    }

    function getTotalUserAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }

    function getTotalBorrowedAssets() external view returns (uint256) {
        return totalBorrowedAssets;
    }

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
    ) external returns (bool) {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        return DASHBOARD.setConfirmExpiry(_newConfirmExpiry);
    }

    function setNodeOperatorFeeRate(
        uint256 _newNodeOperatorFeeRate
    ) external returns (bool) {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        return DASHBOARD.setNodeOperatorFeeRate(_newNodeOperatorFeeRate);
    }

    // =================================================================================
    // WHITELIST MANAGEMENT
    // =================================================================================

    /**
     * @notice Add an address to the whitelist
     * @param user Address to whitelist
     */
    function addToWhitelist(address user) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (isWhitelisted(user)) revert AlreadyWhitelisted(user);
        if (getRoleMemberCount(DEPOSIT_ROLE) >= MAX_WHITELIST_SIZE) revert WhitelistFull();

        grantRole(DEPOSIT_ROLE, user);

        emit WhitelistAdded(user);
    }

    /**
     * @notice Remove an address from the whitelist
     * @param user Address to remove from whitelist
     */
    function removeFromWhitelist(address user) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (!isWhitelisted(user)) revert NotInWhitelist(user);

        revokeRole(DEPOSIT_ROLE, user);

        emit WhitelistRemoved(user);
    }

    /**
     * @notice Check if an address is whitelisted
     * @param user Address to check
     * @return bool True if whitelisted
     */
    function isWhitelisted(address user) public view returns (bool) {
        return hasRole(DEPOSIT_ROLE, user);
    }

    /**
     * @notice Get the current whitelist size
     * @return uint256 Number of addresses in whitelist
     */
    function getWhitelistSize() external view returns (uint256) {
        return getRoleMemberCount(DEPOSIT_ROLE);
    }

    /**
     * @notice Get all whitelisted addresses
     * @return address[] Array of whitelisted addresses
     */
    function getWhitelistAddresses() public view returns (address[] memory) {
        uint256 count = getRoleMemberCount(DEPOSIT_ROLE);
        address[] memory addresses = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            addresses[i] = getRoleMember(DEPOSIT_ROLE, i);
        }
        return addresses;
    }
}
