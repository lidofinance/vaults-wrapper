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


// Custom errors
error NotWhitelisted(address user);
error WhitelistFull();
error AlreadyWhitelisted(address user);
error NotInWhitelist(address user);
error ZeroDeposit();
error InvalidReceiver();
error NoMintingCapacityAvailable();
error ZeroStvShares();
error MintingMustBeAllowedForStrategy();
error OnlyStrategyCanCall();

contract Wrapper is ERC4626, AccessControlEnumerable {
    uint256 public constant E27_PRECISION_BASE = 1e27;
    uint256 public constant MAX_WHITELIST_SIZE = 1000;

    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    bytes32 public constant REQUEST_VALIDATOR_EXIT_ROLE = keccak256("REQUEST_VALIDATOR_EXIT_ROLE");
    bytes32 public constant TRIGGER_VALIDATOR_WITHDRAWAL_ROLE = keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");

    bool public immutable WHITELIST_ENABLED;
    bool public immutable MINTING_ALLOWED;

    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    WithdrawalQueue public withdrawalQueue;
    IStrategy public STRATEGY;

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

    event WhitelistAdded(address indexed user);
    event WhitelistRemoved(address indexed user);

    constructor(
        address _dashboard,
        address _owner,
        string memory _name,
        string memory _symbol,
        bool _whitelistEnabled,
        bool _mintingEnabled,
        address _strategy
    )
        ERC20(_name, _symbol)
        // The asset is native ETH. We pass address(0) as a placeholder for the ERC20 asset token.
        // This is safe because we override all functions that would interact with the asset
        // (totalAssets, deposit, withdraw, redeem) to use our own ETH-based logic.
        ERC4626(ERC20(address(0)))
    {
        WHITELIST_ENABLED = _whitelistEnabled;
        MINTING_ALLOWED = _mintingEnabled;

        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());

        if (_strategy != address(0)) {
            if (!_mintingEnabled) {
                revert MintingMustBeAllowedForStrategy();
            }
            STRATEGY = IStrategy(_strategy);
        }

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
        uint256 _assets
    ) public view override returns (uint256) {
        uint256 supply = totalSupply();
        // TODO: replace in favor of the stone?
        if (supply == 0) {
            return _assets; // 1:1 for the first deposit
        }
        return super.previewDeposit(_assets);
    }

    // TODO?: implement maxRedeem, previewWithdraw, previewRedeem, withdraw, redeem, mint, maxMint, mintPreview

    /**
     * @notice Returns the maximum amount of underlying assets that can be withdrawn for a given owner
     * @param _owner The address to check withdrawal limits for
     * @return Maximum withdrawable assets
     */
    function maxWithdraw(address _owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(_owner));
    }

    /**
     * @notice Standard ERC4626 deposit function - DISABLED for this ETH wrapper
     * @dev This function is overridden to revert, as this wrapper only accepts native ETH
     */
    function deposit(
        uint256 /*_assets*/,
        address /*_receiver*/
    ) public pure override returns (uint256 /*_shares*/) {
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
     * @param _receiver Address to receive the minted shares
     * @return shares Number of shares minted
     */
    function depositETH(
        address _receiver
    ) public payable returns (uint256 shares) {
        if (msg.value == 0) revert ZeroDeposit();
        if (_receiver == address(0)) revert InvalidReceiver();

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

        _mint(_receiver, shares);

        // // Auto-leverage
        // // if (autoLeverageEnabled && address(defaultStrategy) != address(0) && address(escrow) != address(0)) {
        // //     _autoExecuteLeverage(receiver, shares);
        // // }
        emit Deposit(msg.sender, _receiver, msg.value, shares);
        assert(totalAssets() == totalAssetsBefore + msg.value);
        assert(totalSupply() == totalSupplyBefore + shares);
        return shares;
    }

    /**
     * @notice Enhanced deposit that automatically mints stETH for strategies
     * @dev Only callable by the configured strategy
     * @param user The end user who will receive stvToken shares
     * @return shares Number of stvToken shares minted to user
     * @return stETHAmount Amount of stETH minted to the strategy
     */
    function mintStETHForStrategy(address user) external payable returns (uint256 shares, uint256 stETHAmount) {
        if (msg.sender != address(STRATEGY)) revert OnlyStrategyCanCall();
        if (msg.value == 0) revert ZeroDeposit();
        if (user == address(0)) revert InvalidReceiver();
        if (!MINTING_ALLOWED) revert MintingMustBeAllowedForStrategy();

        uint256 totalAssetsBefore = totalAssets();
        uint256 totalSupplyBefore = totalSupply();

        // Calculate shares to be minted based on the assets value BEFORE this deposit
        shares = previewDeposit(msg.value);

        // Fund vault through Dashboard. This increases the totalAssets value.
        DASHBOARD.fund{value: msg.value}();

        // Mint stvToken shares to the user (not the strategy)
        _mint(user, shares);

        // Lock stvToken shares and mint stETH to strategy
        if (shares == 0) revert ZeroStvShares();

        _transfer(user, address(this), shares);
        lockedStvSharesByUser[user] += shares;

        uint256 remainingMintingCapacity = DASHBOARD.remainingMintingCapacityShares(0);
        uint256 totalMintingCapacity = DASHBOARD.totalMintingCapacityShares();
        assert(remainingMintingCapacity <= totalMintingCapacity);

        uint256 userEthInPool = convertToAssets(shares);
        uint256 totalVaultAssets = totalAssets();
        uint256 userTotalMintingCapacity = (userEthInPool * totalMintingCapacity) / totalVaultAssets;

        // User can mint up to their fair share, limited by remaining capacity
        stETHAmount = userTotalMintingCapacity < remainingMintingCapacity ? userTotalMintingCapacity : remainingMintingCapacity;

        if (stETHAmount == 0) revert NoMintingCapacityAvailable();

        DASHBOARD.mintShares(msg.sender, stETHAmount);

        emit Deposit(msg.sender, user, msg.value, shares);

        assert(totalAssets() == totalAssetsBefore + msg.value);
        assert(totalSupply() == totalSupplyBefore + shares);

        return (shares, stETHAmount);
    }

    // =================================================================================
    // WITHDRAWAL SYSTEM WITH EXTERNAL QUEUE
    // =================================================================================

    function burnShares(uint256 _shares) external {
        _burn(msg.sender, _shares);
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

    function openPosition(uint256 _stvShares) external {
        if (address(STRATEGY) != address(0)) {
            // Strategy is set - strategy will handle its own deposits via depositPlus
            assert(MINTING_ALLOWED);
            STRATEGY.execute(msg.sender, 0); // Strategy handles its own deposits now
        } else if (MINTING_ALLOWED) {
            // No strategy but minting enabled - mint stETH directly for user
            mintStETH(_stvShares);
        }
        // If no strategy and no minting - do nothing
    }

    function closePosition(uint256 _stvShares) external {
        revert("not implemented");
    }

    function mintStETH(uint256 _stvShares) public returns (uint256 mintedStethShares) {
        if (_stvShares == 0) revert ZeroStvShares();

        _transfer(msg.sender, address(this), _stvShares);
        lockedStvSharesByUser[msg.sender] += _stvShares;

        uint256 remainingMintingCapacity = DASHBOARD.remainingMintingCapacityShares(0);
        uint256 totalMintingCapacity = DASHBOARD.totalMintingCapacityShares();
        assert(remainingMintingCapacity <= totalMintingCapacity);

        uint256 userEthInPool = convertToAssets(_stvShares);
        uint256 totalVaultAssets = totalAssets();
        uint256 userTotalMintingCapacity = (userEthInPool * totalMintingCapacity) / totalVaultAssets;

        // User can mint up to their fair share, limited by remaining capacity
        mintedStethShares = userTotalMintingCapacity < remainingMintingCapacity ? userTotalMintingCapacity : remainingMintingCapacity;

        if (mintedStethShares == 0) revert NoMintingCapacityAvailable();

        DASHBOARD.mintShares(msg.sender, mintedStethShares);
    }

    function getUserLockedStvShares(address _user) external view returns (uint256) {
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
    // WHITELIST MANAGEMENT
    // =================================================================================

    /**
     * @notice Add an address to the whitelist
     * @param _user Address to whitelist
     */
    function addToWhitelist(address _user) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (isWhitelisted(_user)) revert AlreadyWhitelisted(_user);
        if (getRoleMemberCount(DEPOSIT_ROLE) >= MAX_WHITELIST_SIZE) revert WhitelistFull();

        grantRole(DEPOSIT_ROLE, _user);

        emit WhitelistAdded(_user);
    }

    /**
     * @notice Remove an address from the whitelist
     * @param _user Address to remove from whitelist
     */
    function removeFromWhitelist(address _user) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (!isWhitelisted(_user)) revert NotInWhitelist(_user);

        revokeRole(DEPOSIT_ROLE, _user);

        emit WhitelistRemoved(_user);
    }

    /**
     * @notice Check if an address is whitelisted
     * @param _user Address to check
     * @return bool True if whitelisted
     */
    function isWhitelisted(address _user) public view returns (bool) {
        return hasRole(DEPOSIT_ROLE, _user);
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

    function requestValidatorExit(
        bytes calldata _pubkeys
    ) external onlyRoleOrEmergencyExit(REQUEST_VALIDATOR_EXIT_ROLE) {
        DASHBOARD.requestValidatorExit(_pubkeys);
    }

    function triggerValidatorWithdrawals(
        bytes calldata _pubkeys, 
        uint64[] calldata _amounts, 
        address _refundRecipient
    ) external payable onlyRoleOrEmergencyExit(TRIGGER_VALIDATOR_WITHDRAWAL_ROLE) {
        DASHBOARD.triggerValidatorWithdrawals{value: msg.value}(_pubkeys, _amounts, _refundRecipient);
    }

    /// @notice Modifier to check role or Emergency Exit
    modifier onlyRoleOrEmergencyExit(bytes32 role) {
        if (!withdrawalQueue.isEmergencyExitActivated()) {
            _checkRole(role, msg.sender);
        }
        _;
    }
}
