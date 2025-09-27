// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {console} from "forge-std/Test.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {AllowList} from "./AllowList.sol";
import {ProposalUpgradable} from "./ProposalUpgradable.sol";

// TODO: move whitelist to a separate contract
// TODO: likely we can get rid of the base and move all to WrapperA
abstract contract WrapperBase is Initializable, ERC20Upgradeable, AllowList, ProposalUpgradable {
    using EnumerableSet for EnumerableSet.UintSet;

    // Custom errors
    error ZeroDeposit();
    error InvalidReceiver();
    error NoMintingCapacityAvailable();
    error ZeroStvShares();
    error TransferNotAllowed();
    error NotOwner(address caller, address owner);
    error NotWithdrawalQueue();
    error InvalidRequestType();
    error NotEnoughToRebalance();
    error UnassignedLiabilityOnVault();

    // keccak256("REQUEST_VALIDATOR_EXIT_ROLE")
    bytes32 public immutable REQUEST_VALIDATOR_EXIT_ROLE =
        0x2bbd6da7b06270fd63c039b4a14614f791d085d02c5a2e297591df95b05e4185;

    bytes32 public immutable TRIGGER_VALIDATOR_WITHDRAWAL_ROLE = keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");

    uint256 public immutable DECIMALS = 27;
    uint256 public immutable ASSET_DECIMALS = 18;
    uint256 public immutable EXTRA_DECIMALS_BASE = 10 ** (DECIMALS - ASSET_DECIMALS);
    uint256 public immutable TOTAL_BASIS_POINTS = 100_00;

    IStETH public immutable STETH;
    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    address public immutable STAKING_VAULT;

    WithdrawalQueue public immutable WITHDRAWAL_QUEUE;

    enum WithdrawalType {
        WITHDRAWAL_QUEUE,
        STRATEGY
    }

    struct WithdrawalRequest {
        uint256 requestId;
        WithdrawalType requestType;
        address owner;
        uint40 timestamp;
        uint256 amount;
    }

    /// @custom:storage-location erc7201:wrapper.base.storage
    struct WrapperBaseStorage {
        bool vaultDisconnected;
        WithdrawalRequest[] withdrawalRequests;
        mapping(address => EnumerableSet.UintSet) requestsByOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("wrapper.base.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WRAPPER_BASE_STORAGE_LOCATION =
        0x8405b42399982e28cdd42aed39df9522715c70c841209124c7b936e15fd30300;

    function _getWrapperBaseStorage() internal pure returns (WrapperBaseStorage storage $) {
        assembly {
            $.slot := WRAPPER_BASE_STORAGE_LOCATION
        }
    }

    function withdrawalQueue() public view override returns (WithdrawalQueue) {
        return WITHDRAWAL_QUEUE;
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
    event WithdrawalClaimed(uint256 requestId, address indexed owner, address indexed receiver, uint256 amountOfETH);
    event WithdrawalRequestCreated(uint256 requestId, address indexed user, uint256 amount, WithdrawalType requestType);
    event UnassignedLiabilityRebalanced(uint256 stethShares, uint256 ethAmount);

    constructor(address _dashboard, bool _allowListEnabled, address _withdrawalQueue) AllowList(_allowListEnabled) {
        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = address(DASHBOARD.stakingVault());
        WITHDRAWAL_QUEUE = WithdrawalQueue(payable(_withdrawalQueue));
        STETH = IStETH(payable(DASHBOARD.STETH()));

        // Disable initializers since we only support proxy deployment
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _upgradeConformer,
        string memory _name,
        string memory _symbol
    ) public virtual initializer {
        _initializeWrapperBase(_owner, _upgradeConformer, _name, _symbol);
    }

    function _initializeWrapperBase(
        address _owner,
        address _upgradeConformer,
        string memory _name,
        string memory _symbol
    ) internal {
        __ERC20_init(_name, _symbol);
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _initializeAllowList(_owner);
        _initializeProposalUpgradable(_owner, _upgradeConformer);

        // Initial vault balance must include the connect deposit
        // Minting shares for it to have clear shares math
        // The shares are withdrawable only upon vault disconnection
        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        uint256 connectDeposit = VAULT_HUB.CONNECT_DEPOSIT();
        assert(initialVaultBalance >= connectDeposit);

        // TODO: need to mint because NO must be able to withdraw CONNECT_DEPOSIT and rewards accumulated on it
        _mint(address(this), _convertToShares(connectDeposit, Math.Rounding.Floor));
    }

    function wrapperType() external pure virtual returns (string memory);

    // =================================================================================
    // CORE VAULT FUNCTIONS
    // =================================================================================

    /**
     * @notice Total assets managed by the wrapper
     * @return Total assets (18 decimals)
     * @dev Don't subtract CONNECT_DEPOSIT because we mint tokens for it
     */
    function totalAssets() public view returns (uint256) {
        return DASHBOARD.maxLockableValue();
    }

    /**
     * @notice Assets owned by an account
     * @param _account The account to query
     * @return assets Amount of account assets (18 decimals)
     * @dev Overridable method to include other assets if needed
     */
    function assetsOf(address _account) public view returns (uint256 assets) {
        assets = _getAssetsShare(balanceOf(_account), totalAssets());
    }

    /**
     * @notice Total effective assets managed by the wrapper
     * @return assets Total effective assets (18 decimals)
     * @dev Overridable method to include other assets if needed
     */
    function totalEffectiveAssets() public view virtual returns (uint256 assets) {
        assets = totalAssets(); /* plus other assets if any */
    }

    /**
     * @notice Effective assets owned by an account
     * @param _account The account to query
     * @return Amount of effective assets (18 decimals)
     * @dev Overridable method to include other assets if needed
     */
    function effectiveAssetsOf(address _account) public view virtual returns (uint256) {
        return assetsOf(_account); /* plus other assets if any */
    }

    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }

    function _convertToShares(uint256 _assetsE18, Math.Rounding rounding) internal view returns (uint256 shares) {
        uint256 supplyE27 = totalSupply();
        if (supplyE27 == 0) {
            return _assetsE18 * EXTRA_DECIMALS_BASE; // 1:1 for the first deposit
        }
        shares = Math.mulDiv(_assetsE18, supplyE27, totalEffectiveAssets(), rounding);
    }

    function _convertToAssets(uint256 _shares) internal view returns (uint256 assets) {
        assets = _getAssetsShare(_shares, totalEffectiveAssets());
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
        return _convertToShares(_assets, Math.Rounding.Floor);
    }

    // TODO: get rid of this in favor of previewRedeem?
    function previewWithdraw(uint256 _assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        return Math.mulDiv(_assets, supply, totalEffectiveAssets(), Math.Rounding.Ceil);
    }

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
    // LIABILITY
    // =================================================================================

    /**
     * @notice Total liability stETH shares issued to the vault
     * @return liabilityShares Total liability stETH shares (18 decimals)
     */
    function totalLiabilityShares() external view returns (uint256) {
        return DASHBOARD.liabilityShares();
    }

    /**
     * @notice Total liability stETH shares that are not assigned to any users
     * @return unassignedLiabilityShares Total unassign liability stETH shares (18 decimals)
     * @dev Overridable method to get unassigned liability shares
     * @dev Should exclude individually minted stETH shares (if any)
     */
    function totalUnassignedLiabilityShares() public view virtual returns (uint256 unassignedLiabilityShares) {
        unassignedLiabilityShares = DASHBOARD.liabilityShares(); /* minus individually minted stETH shares */
    }

    /**
     * @notice Rebalance unassigned liability by repaying it with assets held by the vault
     * @param _stethShares Amount of stETH shares to rebalance (18 decimals)
     * @dev Only unassigned liability can be rebalanced with this method, not individual liability
     * @dev Can be called by anyone if there is any unassigned liability
     * @dev Required fresh oracle report before calling
     */
    function rebalanceUnassignedLiability(uint256 _stethShares) external {
        _checkOnlyUnassignedLiabilityRebalance(_stethShares);
        DASHBOARD.rebalanceVaultWithShares(_stethShares);

        emit UnassignedLiabilityRebalanced(_stethShares, 0);
    }

    /**
     * @notice Rebalance unassigned liability by repaying it with external ether
     * @dev Only unassigned liability can be rebalanced with this method, not individual liability
     * @dev Can be called by anyone if there is any unassigned liability
     * @dev This function accepts ETH and uses it to rebalance unassigned liability
     * @dev Required fresh oracle report before calling
     */
    function rebalanceUnassignedLiabilityWithEther() external payable {
        uint256 stethShares = STETH.getSharesByPooledEth(msg.value);
        _checkOnlyUnassignedLiabilityRebalance(stethShares);
        DASHBOARD.rebalanceVaultWithEther{value: msg.value}(msg.value);

        emit UnassignedLiabilityRebalanced(stethShares, msg.value);
    }

    /**
     * @dev Checks if only unassigned liability will be rebalanced, not individual liability
     */
    function _checkOnlyUnassignedLiabilityRebalance(uint256 _stethShares) internal view {
        uint256 unassignedLiabilityShares = totalUnassignedLiabilityShares();

        if (_stethShares == 0) revert NotEnoughToRebalance();
        if (unassignedLiabilityShares < _stethShares) revert NotEnoughToRebalance();
    }

    /**
     * @dev Checks if there are no unassigned liability shares
     */
    function _checkNoUnassignedLiability() internal view {
        if (totalUnassignedLiabilityShares() > 0) revert UnassignedLiabilityOnVault();
    }

    // =================================================================================
    // ERC20 OVERRIDES
    // =================================================================================

    /**
     * @dev Overridden method from ERC20 to prevent updates if there are unassigned liability
     */
    function _update(address _from, address _to, uint256 _value) internal virtual override {
        _checkNoUnassignedLiability();
        super._update(_from, _to, _value);
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
        WithdrawalQueue wq = WITHDRAWAL_QUEUE;
        WithdrawalQueue.WithdrawalRequestStatus memory status = wq.getWithdrawalStatus(_requestId);

        if (msg.sender != status.owner) revert NotOwner(msg.sender, status.owner);
        if (_recipient == address(0)) _recipient = msg.sender;

        uint256 ethClaimed = wq.claimWithdrawal(_requestId, _recipient);

        emit WithdrawalClaimed(_requestId, msg.sender, _recipient, ethClaimed);
    }

    function burnSharesForWithdrawalQueue(uint256 _shares) external {
        if (msg.sender != address(WITHDRAWAL_QUEUE)) revert NotWithdrawalQueue();
        _burn(msg.sender, _shares);
    }

    // withdrawal queue is immutable and set in constructor

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return requestIds array of request ids
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestIds) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        return $.requestsByOwner[_owner].values();
    }

    /// @notice Returns all withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @param _start start index
    /// @param _end end index
    /// @return requestIds array of request ids
    function getWithdrawalRequests(
        address _owner,
        uint256 _start,
        uint256 _end
    ) external view returns (uint256[] memory requestIds) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        return $.requestsByOwner[_owner].values(_start, _end);
    }

    /// @notice Returns the length of the withdrawal requests that belong to the `_owner` address
    /// @param _owner address to get requests for
    /// @return length of the withdrawal requests
    function getWithdrawalRequestsLength(address _owner) external view returns (uint256) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        return $.requestsByOwner[_owner].length();
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return _getWrapperBaseStorage().withdrawalRequests[requestId];
    }

    function _addWithdrawalRequest(
        address _owner,
        uint256 _ethAmount,
        WithdrawalType _type
    ) internal returns (uint256 requestId) {
        WrapperBaseStorage storage $ = _getWrapperBaseStorage();
        requestId = $.withdrawalRequests.length;
        WithdrawalRequest memory request = WithdrawalRequest({
            requestId: requestId,
            requestType: _type,
            owner: _owner,
            timestamp: uint40(block.timestamp),
            amount: _ethAmount
        });

        $.withdrawalRequests.push(request);
        $.requestsByOwner[_owner].add(requestId);

        emit WithdrawalRequestCreated(requestId, _owner, _ethAmount, request.requestType);
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

    function requestValidatorExit(bytes calldata _pubkeys) external {
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
        if (!WITHDRAWAL_QUEUE.isEmergencyExitActivated()) {
            _checkRole(_role, msg.sender);
        }
    }
}
