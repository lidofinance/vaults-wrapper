// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {console} from "forge-std/Test.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {AllowList} from "./AllowList.sol";

// TODO: move whitelist to a separate contract
// TODO: likely we can get rid of the base and move all to WrapperA
abstract contract WrapperBase is Initializable, ERC20Upgradeable, AllowList {
    // Custom errors
    error ZeroDeposit();
    error InvalidReceiver();
    error NoMintingCapacityAvailable();
    error ZeroStvShares();
    error TransferNotAllowed();
    error InvalidWithdrawalType();
    error NotOwner(address caller, address owner);
    error NotWithdrawalQueue();

    bytes32 public constant REQUEST_VALIDATOR_EXIT_ROLE = keccak256("REQUEST_VALIDATOR_EXIT_ROLE");
    bytes32 public constant TRIGGER_VALIDATOR_WITHDRAWAL_ROLE = keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");

    uint256 public immutable DECIMALS = 27;
    uint256 public immutable ASSET_DECIMALS = 18;
    uint256 public immutable EXTRA_DECIMALS_BASE = 10 ** (DECIMALS - ASSET_DECIMALS);
    uint256 public immutable TOTAL_BASIS_POINTS = 100_00;


    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    /// @custom:storage-location erc7201:wrapper.base.storage
    struct WrapperBaseStorage {
        WithdrawalQueue withdrawalQueue;
        bool vaultDisconnected;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.base.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_BASE_STORAGE_LOCATION = 0x8405b42399982e28cdd42aed39df9522715c70c841209124c7b936e15fd30300;

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
        address indexed referral,
        uint256 assets,
        uint256 stvETHShares
    );

    event VaultDisconnected(address indexed initiator);
    event ConnectDepositClaimed(address indexed recipient, uint256 amount);
    event WithdrawalClaimed(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 amountOfETH
    );

    constructor(
        address _dashboard,
        bool _allowListEnabled
    ) AllowList(_allowListEnabled) {
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
        _initializeAllowList(_owner);

        // Initial vault balance must include the connect deposit
        // Minting shares for it to have clear shares math
        // The shares are withdrawable only upon vault disconnection
        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        uint256 connectDeposit = VAULT_HUB.CONNECT_DEPOSIT();
        assert(initialVaultBalance >= connectDeposit);

        // TODO: need to mint because NO must be able to withdraw CONNECT_DEPOSIT and rewards accumulated on it
        _mint(address(this), _convertToShares(connectDeposit));
    }

    // =================================================================================
    // CORE VAULT FUNCTIONS
    // =================================================================================

    function totalAssets() public view returns (uint256) {
        return DASHBOARD.maxLockableValue(); // don't subtract CONNECT_DEPOSIT because we mint stShares for it
    }

    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }

    function _convertToShares(uint256 _assetsE18) internal view returns (uint256) {
        uint256 supplyE27 = totalSupply();
        if (supplyE27 == 0) {
            return _assetsE18 * EXTRA_DECIMALS_BASE; // 1:1 for the first deposit
        }
        return Math.mulDiv(_assetsE18, supplyE27, totalAssets(), Math.Rounding.Floor);
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256) {
        return _getAssetsShare(_shares, totalAssets());
    }

    function _getAssetsShare(uint256 _shares, uint256 _assets) internal view returns (uint256) {
        // TODO: check supply
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        // TODO: review this Math.Rounding.Ceil
        uint256 assetsShare = Math.mulDiv(_shares * EXTRA_DECIMALS_BASE, _assets, supply, Math.Rounding.Ceil);
        return assetsShare / EXTRA_DECIMALS_BASE;
    }

    function previewDeposit(uint256 _assets) public view returns (uint256) {
        return _convertToShares(_assets);
    }

    // TODO: get rid of this in favor of previewRedeem?
    // function previewWithdraw(uint256 _assets) public view returns (uint256) {
    //     uint256 supply = totalSupply();
    //     if (supply == 0) {
    //         return 0;
    //     }
    //     return Math.mulDiv(_assets, totalAssets(), supply, Math.Rounding.Ceil);
    // }

    function previewRedeem(uint256 _shares) external view returns (uint256) {
        return _convertToAssets(_shares);
    }

    /**
     * @notice Convenience function to deposit ETH to msg.sender
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _referral) public payable returns (uint256 stvShares) {
        return depositETH(msg.sender, _referral);
    }

    /**
     * @notice Convenience function to deposit ETH to msg.sender without referral
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH() public payable returns (uint256 stvShares) {
        return depositETH(msg.sender, address(0));
    }

    /**
     * @notice Deposit native ETH and receive stvETH shares
     * @dev Implementation depends on specific wrapper configuration
     * @param _receiver Address to receive the minted shares
     * @return stvShares Amount of stvETH shares minted
     */
    function depositETH(address _receiver, address _referral) public payable virtual returns (uint256 stvShares);

    function _deposit(address _receiver, address _referral) internal returns (uint256 stvShares) {
        if (msg.value == 0) revert WrapperBase.ZeroDeposit();
        if (_receiver == address(0)) revert WrapperBase.InvalidReceiver();
        _checkAllowList();

        stvShares = previewDeposit(msg.value);
        console.log("_deposit stvShares", stvShares);
        _mint(_receiver, stvShares);
        DASHBOARD.fund{value: msg.value}();

        emit Deposit(msg.sender, _receiver, _referral, msg.value, stvShares);
    }

    // =================================================================================
    // WITHDRAWAL SYSTEM
    // =================================================================================

    /**
     * @notice Claim finalized withdrawal request
     * @param _requestId The withdrawal request ID to claim
     * @param _recipient The address to receive the claimed ether
     */
    function claimWithdrawal(uint256 _requestId, address _recipient) external virtual {
        WithdrawalQueue wq = withdrawalQueue();
        WithdrawalQueue.WithdrawalRequestStatus memory status = wq.getWithdrawalStatus(_requestId);

        if (msg.sender != status.owner) revert NotOwner(msg.sender, status.owner);
        if (_recipient == address(0)) _recipient = msg.sender;

        uint256 ethClaimed = wq.claimWithdrawal(_requestId, _recipient);

        emit WithdrawalClaimed(_requestId, msg.sender, _recipient, ethClaimed);
    }

    function burnSharesForWithdrawalQueue(uint256 _shares) external {
        if (msg.sender != address(withdrawalQueue())) revert NotWithdrawalQueue();
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
        depositETH(msg.sender, address(0));
    }

    function requestValidatorExit(
        bytes calldata _pubkeys
    ) external {
        _checkOnlyRoleOrEmergencyExit(REQUEST_VALIDATOR_EXIT_ROLE);
        DASHBOARD.requestValidatorExit(_pubkeys);
    }


    // =================================================================================
    // EMERGENCY WITHDRAWAL FUNCTIONS
    // =================================================================================

    function triggerValidatorWithdrawals(
        bytes calldata _pubkeys,
        uint64[] calldata _amounts,
        address _refundRecipient
    ) external payable {
        _checkOnlyRoleOrEmergencyExit(TRIGGER_VALIDATOR_WITHDRAWAL_ROLE);
        DASHBOARD.triggerValidatorWithdrawals{value: msg.value}(_pubkeys, _amounts, _refundRecipient);
    }

    /// @notice Modifier to check role or Emergency Exit
    function _checkOnlyRoleOrEmergencyExit(bytes32 _role) internal view {
        if (!_getWrapperBaseStorage().withdrawalQueue.isEmergencyExitActivated()) {
            _checkRole(_role, msg.sender);
        }
    }


}