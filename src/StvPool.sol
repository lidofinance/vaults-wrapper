// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WithdrawalQueue} from "./WithdrawalQueue.sol";
import {Distributor} from "./Distributor.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";
import {IDashboard} from "./interfaces/IDashboard.sol";
import {IStakingVault} from "./interfaces/IStakingVault.sol";
import {AllowList} from "./AllowList.sol";

contract StvPool is Initializable, ERC20Upgradeable, AllowList {
    // Custom errors
    error ZeroDeposit();
    error InvalidReceiver();
    error ZeroStv();
    error NotWithdrawalQueue();
    error InvalidRequestType();
    error NotEnoughToRebalance();
    error UnassignedLiabilityOnVault();

    bytes32 public constant REQUEST_VALIDATOR_EXIT_ROLE = keccak256("REQUEST_VALIDATOR_EXIT_ROLE");
    bytes32 public constant TRIGGER_VALIDATOR_WITHDRAWAL_ROLE = keccak256("TRIGGER_VALIDATOR_WITHDRAWAL_ROLE");

    uint256 public constant TOTAL_BASIS_POINTS = 100_00;

    uint256 private constant DECIMALS = 27;
    uint256 private constant ASSET_DECIMALS = 18;
    uint256 private constant EXTRA_DECIMALS_BASE = 10 ** (DECIMALS - ASSET_DECIMALS);

    IStETH public immutable STETH;
    IDashboard public immutable DASHBOARD;
    IVaultHub public immutable VAULT_HUB;
    IStakingVault public immutable STAKING_VAULT;

    WithdrawalQueue public immutable WITHDRAWAL_QUEUE;
    Distributor public immutable DISTRIBUTOR;

    /// @custom:storage-location erc7201:pool.storage.BasePool
    struct BasePoolStorage {
        bool vaultDisconnected;
    }

    // keccak256(abi.encode(uint256(keccak256("pool.storage.BasePool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BASE_POOL_STORAGE_LOCATION =
        0xc4110d6af9d6cc8ebf3d109653462ebdabed38a4baebe6d0d7e79af4f6479900;

    function _getBasePoolStorage() internal pure returns (BasePoolStorage storage $) {
        assembly {
            $.slot := BASE_POOL_STORAGE_LOCATION
        }
    }

    function vaultDisconnected() public view returns (bool) {
        return _getBasePoolStorage().vaultDisconnected;
    }

    event VaultFunded(uint256 amount);
    event ValidatorExitRequested(bytes pubkeys);
    event ValidatorWithdrawalsTriggered(bytes pubkeys, uint64[] amountsInGwei);
    event Deposit(
        address indexed sender,
        address indexed receiver,
        address indexed referral,
        uint256 assets,
        uint256 stv
    );

    event VaultDisconnected(address indexed initiator);
    event ConnectDepositClaimed(address indexed recipient, uint256 amount);
    event UnassignedLiabilityRebalanced(uint256 stethShares, uint256 ethAmount);

    constructor(
        address _dashboard,
        bool _allowListEnabled,
        address _withdrawalQueue,
        address _distributor
    ) AllowList(_allowListEnabled) {
        DASHBOARD = IDashboard(payable(_dashboard));
        VAULT_HUB = IVaultHub(DASHBOARD.VAULT_HUB());
        STAKING_VAULT = IStakingVault(DASHBOARD.stakingVault());
        WITHDRAWAL_QUEUE = WithdrawalQueue(payable(_withdrawalQueue));
        STETH = IStETH(payable(DASHBOARD.STETH()));
        DISTRIBUTOR = Distributor(_distributor);

        // Disable initializers since we only support proxy deployment
        _disableInitializers();
    }

    function initialize(address _owner, string memory _name, string memory _symbol) public virtual initializer {
        _initializeBasePool(_owner, _name, _symbol);
    }

    function _initializeBasePool(address _owner, string memory _name, string memory _symbol) internal {
        __ERC20_init(_name, _symbol);
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _initializeAllowList(_owner);

        // Initial vault balance must include the connect deposit
        // Minting stv for it to have clear stv math
        // The stv are withdrawable only upon vault disconnection
        uint256 initialVaultBalance = address(STAKING_VAULT).balance;
        uint256 connectDeposit = VAULT_HUB.CONNECT_DEPOSIT();
        assert(initialVaultBalance >= connectDeposit);

        _mint(address(this), _convertToStv(connectDeposit, Math.Rounding.Floor));
    }

    // =================================================================================
    // ASSETS
    // =================================================================================

    /**
     * @notice Total nominal assets managed by the pool
     * @return assets Total nominal assets (18 decimals)
     * @dev Don't subtract CONNECT_DEPOSIT because we mint tokens for it
     */
    function totalNominalAssets() public view returns (uint256 assets) {
        assets = DASHBOARD.maxLockableValue();
    }

    /**
     * @notice Nominal assets owned by an account
     * @param _account The account to query
     * @return assets Amount of account assets (18 decimals)
     */
    function nominalAssetsOf(address _account) public view returns (uint256 assets) {
        assets = _getAssetsShare(balanceOf(_account), totalNominalAssets());
    }

    /**
     * @notice Total assets managed by the pool
     * @return assets Total assets (18 decimals)
     * @dev Overridable method to include other assets if needed
     * @dev Subtract unassigned liability stETH from total nominal assets
     */
    function totalAssets() public view virtual returns (uint256 assets) {
        assets = Math.saturatingSub(
            totalNominalAssets(),
            totalUnassignedLiabilitySteth()
        ); /* plus other assets if any */
    }

    /**
     * @notice Assets owned by an account
     * @param _account The account to query
     * @return assets Amount of assets (18 decimals)
     * @dev Overridable method to include other assets if needed
     */
    function assetsOf(address _account) public view virtual returns (uint256 assets) {
        assets = nominalAssetsOf(_account); /* plus other assets if any */
    }

    // =================================================================================
    // CONVERSION
    // =================================================================================

    function _convertToStv(uint256 _assetsE18, Math.Rounding _rounding) internal view returns (uint256 stv) {
        uint256 totalAssetsE18 = totalAssets();
        uint256 totalSupplyE27 = totalSupply();

        if (totalSupplyE27 == 0) return _assetsE18 * EXTRA_DECIMALS_BASE; // 1:1 for the first deposit
        if (totalAssetsE18 == 0) return 0;

        stv = Math.mulDiv(_assetsE18, totalSupplyE27, totalAssetsE18, _rounding);
    }

    function _convertToAssets(uint256 _stv) internal view returns (uint256 assets) {
        assets = _getAssetsShare(_stv, totalAssets());
    }

    function _getAssetsShare(uint256 _stv, uint256 _assetsE18) internal view returns (uint256 assets) {
        uint256 supplyE27 = totalSupply();
        if (supplyE27 == 0) return 0;

        // TODO: review this Math.Rounding.Ceil
        uint256 assetsShare = Math.mulDiv(_stv * EXTRA_DECIMALS_BASE, _assetsE18, supplyE27, Math.Rounding.Ceil);
        assets = assetsShare / EXTRA_DECIMALS_BASE;
    }

    // =================================================================================
    // PREVIEW
    // =================================================================================

    /**
     * @notice Preview the amount of stv that would be received for a given asset amount
     * @param _assets Amount of assets to deposit (18 decimals)
     * @return stv Amount of stv that would be minted (27 decimals)
     */
    function previewDeposit(uint256 _assets) public view returns (uint256 stv) {
        stv = _convertToStv(_assets, Math.Rounding.Floor);
    }

    /**
     * @notice Preview the amount of stv that would be burned for a given asset withdrawal
     * @param _assets Amount of assets to withdraw (18 decimals)
     * @return stv Amount of stv that would be burned (27 decimals)
     */
    function previewWithdraw(uint256 _assets) public view returns (uint256 stv) {
        stv = _convertToStv(_assets, Math.Rounding.Ceil);
    }

    /**
     * @notice Preview the amount of assets that would be received for a given stv amount
     * @param _stv Amount of stv to redeem (27 decimals)
     * @return assets Amount of assets that would be received (18 decimals)
     */
    function previewRedeem(uint256 _stv) external view returns (uint256 assets) {
        assets = _convertToAssets(_stv);
    }

    // =================================================================================
    // DEPOSIT
    // =================================================================================

    receive() external payable {
        // Auto-deposit ETH sent directly to the contract
        depositETH(msg.sender, address(0));
    }

    /**
     * @notice Deposit native ETH and receive stv
     * @param _recipient Address to receive the minted shares
     * @param _referral Address of the referral (if any)
     * @return stv Amount of stv minted
     */
    function depositETH(address _recipient, address _referral) public payable returns (uint256 stv) {
        stv = _deposit(_recipient, _referral);
    }

    function _deposit(address _recipient, address _referral) internal returns (uint256 stv) {
        if (msg.value == 0) revert ZeroDeposit();
        if (_recipient == address(0)) revert InvalidReceiver();
        _checkAllowList();

        stv = previewDeposit(msg.value);
        _mint(_recipient, stv);
        DASHBOARD.fund{value: msg.value}();

        emit Deposit(msg.sender, _recipient, _referral, msg.value, stv);
    }

    // =================================================================================
    // LIABILITY
    // =================================================================================

    /**
     * @notice Total liability stETH shares issued to the vault
     * @return liabilityShares Total liability stETH shares (18 decimals)
     */
    function totalLiabilityShares() public view returns (uint256) {
        return DASHBOARD.liabilityShares();
    }

    /**
     * @notice Total liability stETH shares that are not assigned to any users
     * @return unassignedLiabilityShares Total unassign liability stETH shares (18 decimals)
     * @dev Overridable method to get unassigned liability shares
     * @dev Should exclude individually minted stETH shares (if any)
     */
    function totalUnassignedLiabilityShares() public view virtual returns (uint256 unassignedLiabilityShares) {
        unassignedLiabilityShares = totalLiabilityShares(); /* minus individually minted stETH shares */
    }

    /**
     * @notice Total unassigned liability in stETH
     */
    function totalUnassignedLiabilitySteth() public view returns (uint256 unassignedLiabilitySteth) {
        unassignedLiabilitySteth = STETH.getPooledEthBySharesRoundUp(totalUnassignedLiabilityShares());
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
        uint256 stethShares = _getSharesByPooledEth(msg.value);
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
    // STETH HELPERS
    // =================================================================================

    function _getSharesByPooledEth(uint256 _ethAmount) internal view returns (uint256 stethShares) {
        stethShares = STETH.getSharesByPooledEth(_ethAmount);
    }

    function _getPooledEthByShares(uint256 _stethShares) internal view returns (uint256 ethAmount) {
        ethAmount = STETH.getPooledEthByShares(_stethShares);
    }

    function _getPooledEthBySharesRoundUp(uint256 _stethShares) internal view returns (uint256 ethAmount) {
        ethAmount = STETH.getPooledEthBySharesRoundUp(_stethShares);
    }

    // =================================================================================
    // ERC20 OVERRIDES
    // =================================================================================

    /**
     * @notice Returns the number of decimals used to get its user representation.
     * @return Number of decimals (27)
     */
    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }

    /**
     * @dev Overridden method from ERC20 to prevent updates if there are unassigned liability
     */
    function _update(address _from, address _to, uint256 _value) internal virtual override {
        // In rare scenarios, the vault could have liability shares that are not assigned to any pool users
        // In such cases, it prevents any transfers until the unassigned liability is rebalanced
        _checkNoUnassignedLiability();
        super._update(_from, _to, _value);
    }

    // =================================================================================
    // WITHDRAWALS
    // =================================================================================

    /**
     * @notice Transfer stv from user to WithdrawalQueue contract when enqueuing withdrawal requests
     * @param _from Address of the user
     * @param _stv Amount of stv to transfer (27 decimals)
     * @dev Can only be called by the WithdrawalQueue contract
     */
    function transferFromForWithdrawalQueue(address _from, uint256 _stv) external {
        _checkOnlyWithdrawalQueue();
        _transfer(_from, address(WITHDRAWAL_QUEUE), _stv);
    }

    /**
     * @notice Burn stv from WithdrawalQueue contract when finalizing withdrawal requests
     * @param _stv Amount of stv to burn (27 decimals)
     * @dev Can only be called by the WithdrawalQueue contract
     */
    function burnStvForWithdrawalQueue(uint256 _stv) external {
        _checkOnlyWithdrawalQueue();
        _checkNoUnassignedLiability();
        _burnUnsafe(address(WITHDRAWAL_QUEUE), _stv);
    }

    function _burnUnsafe(address _account, uint256 _value) internal {
        if (_account == address(0)) revert ERC20InvalidSender(address(0));
        super._update(_account, address(0), _value);
    }

    function _checkOnlyWithdrawalQueue() internal view {
        if (address(WITHDRAWAL_QUEUE) != msg.sender) revert NotWithdrawalQueue();
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
        if (address(STAKING_VAULT) == address(DASHBOARD.stakingVault())) {
            revert("Vault not disconnected yet");
        }

        _getBasePoolStorage().vaultDisconnected = true;

        // After disconnection, the connect deposit is available in the vault
        uint256 vaultBalance = address(STAKING_VAULT).balance;
        if (vaultBalance > 0) {
            DASHBOARD.withdraw(_recipient, vaultBalance);
            emit ConnectDepositClaimed(_recipient, vaultBalance);
        }
    }

    // =================================================================================
    // EMERGENCY WITHDRAWAL FUNCTIONS
    // =================================================================================

    function triggerValidatorWithdrawals(
        bytes calldata _pubkeys,
        uint64[] calldata _amountsInGwei,
        address _refundRecipient
    ) external payable {
        _checkOnlyRoleOrEmergencyExit(TRIGGER_VALIDATOR_WITHDRAWAL_ROLE);
        DASHBOARD.triggerValidatorWithdrawals{value: msg.value}(_pubkeys, _amountsInGwei, _refundRecipient);
    }

    function requestValidatorExit(bytes calldata _pubkeys) external {
        _checkOnlyRoleOrEmergencyExit(REQUEST_VALIDATOR_EXIT_ROLE);
        DASHBOARD.requestValidatorExit(_pubkeys);
    }

    /// @notice Modifier to check role or Emergency Exit
    function _checkOnlyRoleOrEmergencyExit(bytes32 _role) internal view {
        if (!WITHDRAWAL_QUEUE.isEmergencyExitActivated()) {
            _checkRole(_role, msg.sender);
        }
    }
}
