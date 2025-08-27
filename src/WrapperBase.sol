// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";

abstract contract WrapperBase is Initializable, ERC20Upgradeable, AccessControlEnumerableUpgradeable {
    // Custom errors
    error NotAllowListed(address user);
    error AlreadyAllowListed(address user);
    error NotInAllowList(address user);
    error ZeroDeposit();
    error InvalidReceiver();
    error NoMintingCapacityAvailable();
    error ZeroStvShares();
    error TransferNotAllowed();
    error InvalidWithdrawalType();

    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    bytes32 public constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    bytes32 public constant REQUEST_VALIDATOR_EXIT_ROLE = keccak256("REQUEST_VALIDATOR_EXIT_ROLE");
    bytes32 public constant TRIGGER_VALIDATOR_WITHDRAWAL_ROLE = keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");

    bool public immutable ALLOW_LIST_ENABLED;

    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    /// @custom:storage-location erc7201:wrapper.base.storage
    struct WrapperBaseStorage {
        WithdrawalQueue withdrawalQueue;
        bool vaultDisconnected;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.base.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_BASE_STORAGE_LOCATION = 0xa66cc928b5edb82af9bd49922954155ab7b0942694bea4ce44661d9a8736c600;

    function _getWrapperBaseStorage() private pure returns (WrapperBaseStorage storage $) {
        assembly {
            $.slot := WRAPPER_BASE_STORAGE_LOCATION
        }
    }

    function withdrawalQueue() public view returns (WithdrawalQueue) {
        return _getWrapperBaseStorage().withdrawalQueue;
    }

    function vaultDisconnected() public view returns (bool) {
        return _getWrapperBaseStorage().vaultDisconnected;
    }

    event VaultFunded(uint256 amount);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amounts);
    event Deposit(
        address indexed sender,
        address indexed receiver,
        uint256 assets,
        uint256 stvETHShares
    );

    event AllowListAdded(address indexed user);
    event AllowListRemoved(address indexed user);
    event VaultDisconnected(address indexed initiator);
    event ConnectDepositClaimed(address indexed recipient, uint256 amount);

    constructor(
        address _dashboard,
        bool _allowListEnabled
    ) {
        ALLOW_LIST_ENABLED = _allowListEnabled;
        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());

        // Disable initializers since we only support proxy deployment
        _disableInitializers();
    }

    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol
    ) public virtual initializer {
        __ERC20_init(_name, _symbol);
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(ALLOWLIST_MANAGER_ROLE, _owner);

        _setRoleAdmin(ALLOWLIST_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(DEPOSIT_ROLE, ALLOWLIST_MANAGER_ROLE);

        // Initial vault balance must include the connect deposit
        // Minting shares for it to have clear shares math
        // The shares are withdrawable only upon vault disconnection
        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        uint256 connectDeposit = VAULT_HUB.CONNECT_DEPOSIT();
        assert(initialVaultBalance >= connectDeposit);
        // _mint(address(this), _convertToShares(connectDeposit));
    }

    // // =================================================================================
    // // NON-TRANSFERRABLE TOKEN FUNCTIONALITY
    // // =================================================================================

    // function transfer(address, uint256) public pure override returns (bool) {
    //     revert TransferNotAllowed();
    // }

    // function transferFrom(address, address, uint256) public pure override returns (bool) {
    //     revert TransferNotAllowed();
    // }

    // function approve(address, uint256) public pure override returns (bool) {
    //     revert TransferNotAllowed();
    // }

    // =================================================================================
    // CORE VAULT FUNCTIONS
    // =================================================================================

    function totalAssets() public view returns (uint256) {
        return DASHBOARD.maxLockableValue();
    }

    function _convertToShares(uint256 _assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return _assets; // 1:1 for the first deposit
        }
        return Math.mulDiv(_assets, supply, totalAssets(), Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return _getCorrespondingShare(_shares, totalAssets());
    }

    function _getCorrespondingShare(uint256 _shares, uint256 _assets) internal view returns (uint256) {
        // TODO: check supply
        uint256 supply = totalSupply();
        if (supply == 0) {
            return _shares; // 1:1 for the first deposit. TODO: add stone
        }
        return Math.mulDiv(_shares, _assets, supply, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 _assets) public view returns (uint256) {
        return _convertToShares(_assets);
    }

    function previewWithdraw(uint256 _assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return _assets;
        }
        return Math.mulDiv(_assets, supply, totalAssets(), Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 _shares) public view returns (uint256) {
        return _convertToAssets(_shares);
    }

    /**
     * @notice Convenience function to deposit ETH to msg.sender
     */
    function depositETH() public payable returns (uint256) {
        return depositETH(msg.sender);
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Implementation depends on specific wrapper configuration
     * @param _receiver Address to receive the minted shares
     * @return shares Number of stvETH shares minted
     */
    function depositETH(address _receiver) public payable virtual returns (uint256 shares);

    // =================================================================================
    // WITHDRAWAL SYSTEM
    // =================================================================================

    /**
     * @notice Claim finalized withdrawal request
     * @param _requestId The withdrawal request ID to claim
     */
    function claimWithdrawal(uint256 _requestId) external virtual {
        WithdrawalQueue wq = withdrawalQueue();
        WithdrawalQueue.WithdrawalRequestStatus memory status = wq.getWithdrawalStatus(_requestId);

        _burn(address(wq), status.amountOfShares);
        wq.claimWithdrawal(_requestId);
    }

    function burnShares(uint256 _shares) external {
        _burn(msg.sender, _shares);
    }

    // TODO: remove this function
    function setWithdrawalQueue(address _withdrawalQueue) external {
        _getWrapperBaseStorage().withdrawalQueue = WithdrawalQueue(payable(_withdrawalQueue));
    }

    // =================================================================================
    // VAULT MANAGEMENT
    // =================================================================================

    /**
     * @notice Initiates voluntary vault disconnection from VaultHub
     * @dev Can only be called by admin. Vault must have no outstanding stETH liabilities.
     */
    function disconnectVault() external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Start the disconnection process
        // This requires: no liabilityShares, all obligations settled
        DASHBOARD.voluntaryDisconnect();

        // Mark vault as in disconnection process
        // The actual disconnect completes during next oracle report
        emit VaultDisconnected(msg.sender);
    }

    /**
     * @notice Claims the connect deposit after vault has been disconnected
     * @dev Can only be called by admin after successful disconnection
     * @param _recipient Address to receive the connect deposit
     */
    function claimConnectDeposit(address _recipient) external {
        _checkRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Check if vault has been disconnected
        if (STAKING_VAULT == address(DASHBOARD.stakingVault())) {
            revert("Vault not disconnected yet");
        }

        _getWrapperBaseStorage().vaultDisconnected = true;

        // After disconnection, the connect deposit is available in the vault
        uint256 vaultBalance = address(STAKING_VAULT).balance;
        if (vaultBalance > 0) {
            DASHBOARD.withdraw(_recipient, vaultBalance);
            emit ConnectDepositClaimed(_recipient, vaultBalance);
        }
    }

    // =================================================================================
    // RECEIVE FUNCTION
    // =================================================================================

    receive() external payable {
        // Auto-deposit ETH sent directly to the contract
        depositETH(msg.sender);
    }

    // =================================================================================
    // ALLOWLIST MANAGEMENT
    // =================================================================================

    /**
     * @notice Add an address to the allowlist
     * @param _user Address to add to allowlist
     */
    function addToAllowList(address _user) external {
        _checkRole(ALLOWLIST_MANAGER_ROLE, msg.sender);
        if (isAllowListed(_user)) revert AlreadyAllowListed(_user);

        grantRole(DEPOSIT_ROLE, _user);

        emit AllowListAdded(_user);
    }

    /**
     * @notice Remove an address from the allowlist
     * @param _user Address to remove from allowlist
     */
    function removeFromAllowList(address _user) external {
        _checkRole(ALLOWLIST_MANAGER_ROLE, msg.sender);
        if (!isAllowListed(_user)) revert NotInAllowList(_user);

        revokeRole(DEPOSIT_ROLE, _user);

        emit AllowListRemoved(_user);
    }

    /**
     * @notice Check if an address is allowlisted
     * @param _user Address to check
     * @return bool True if allowlisted
     */
    function isAllowListed(address _user) public view returns (bool) {
        return hasRole(DEPOSIT_ROLE, _user);
    }

    /**
     * @notice Get the current allowlist size
     * @return uint256 Number of addresses in allowlist
     */
    function getAllowListSize() external view returns (uint256) {
        return getRoleMemberCount(DEPOSIT_ROLE);
    }

    /**
     * @notice Get all allowlisted addresses
     * @return address[] Array of allowlisted addresses
     */
    function getAllowListAddresses() public view returns (address[] memory) {
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


    // =================================================================================
    // EMERGENCY WITHDRAWAL FUNCTIONS
    // =================================================================================

    function triggerValidatorWithdrawals(
        bytes calldata _pubkeys,
        uint64[] calldata _amounts,
        address _refundRecipient
    ) external payable onlyRoleOrEmergencyExit(TRIGGER_VALIDATOR_WITHDRAWAL_ROLE) {
        DASHBOARD.triggerValidatorWithdrawals{value: msg.value}(_pubkeys, _amounts, _refundRecipient);
    }

    /// @notice Modifier to check role or Emergency Exit
    modifier onlyRoleOrEmergencyExit(bytes32 role) {
        if (!_getWrapperBaseStorage().withdrawalQueue.isEmergencyExitActivated()) {
            _checkRole(role, msg.sender);
        }
        _;
    }

    // =================================================================================
    // INTERNAL HELPER FUNCTIONS FOR SUBCLASSES
    // =================================================================================

    function _checkAllowList() internal view {
        if (ALLOW_LIST_ENABLED && !hasRole(DEPOSIT_ROLE, msg.sender)) {
            revert NotAllowListed(msg.sender);
        }
    }

    function _mintMaximumStETH(address _receiver, uint256 _stvShares) internal returns (uint256 stETHAmount) {
        uint256 totalMintingCapacity = DASHBOARD.totalMintingCapacityShares();
        uint256 userTotalMintingCapacity = _getCorrespondingShare(_stvShares, totalMintingCapacity);
        stETHAmount = Math.min(userTotalMintingCapacity, DASHBOARD.remainingMintingCapacityShares(0));

        if (stETHAmount == 0) revert NoMintingCapacityAvailable();

        DASHBOARD.mintShares(_receiver, stETHAmount);
    }
}