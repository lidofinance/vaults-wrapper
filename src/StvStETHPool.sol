// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {BasePool} from "./BasePool.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IStETH} from "./interfaces/IStETH.sol";
import {IVaultHub} from "./interfaces/IVaultHub.sol";

/**
 * @title StvStETHPool
 * @notice Configuration B: Minting, no strategy - stv + maximum stETH minting for user
 */
contract StvStETHPool is BasePool {
    using EnumerableSet for EnumerableSet.UintSet;

    event StethSharesMinted(address indexed account, uint256 stethShares);
    event StethSharesBurned(address indexed account, uint256 stethShares);
    event StethSharesRebalanced(address indexed account, uint256 stethShares, uint256 stvBurned);
    event SocializedLoss(uint256 stv, uint256 assets);
    event VaultParametersUpdated(uint256 newReserveRatioBP, uint256 newForcedRebalanceThresholdBP);

    error InsufficientMintingCapacity();
    error InsufficientStethShares();
    error InsufficientBalance();
    error InsufficientReservedBalance();
    error InsufficientMintedShares();
    error InsufficientStv();
    error ZeroArgument();
    error MintingForThanTargetStSharesShareIsNotAllowed();
    error ArraysLengthMismatch(uint256 firstArrayLength, uint256 secondArrayLength);
    error InvalidReserveRatioGap(uint256 reserveRatioGapBP);
    error NothingToRebalance();
    error VaultReportStale();
    error UndercollateralizedAccount();
    error CollateralizedAccount();

    bytes32 public immutable LOSS_SOCIALIZER_ROLE = keccak256("LOSS_SOCIALIZER_ROLE");

    /// @notice The gap between the reserve ratio in Staking Vault and Pool (in basis points)
    uint256 public immutable RESERVE_RATIO_GAP_BP;

    /// @notice Sentinel value for depositETH to mint maximum available stETH shares for the deposit
    uint256 public constant MAX_MINTABLE_AMOUNT = type(uint256).max;

    /// @custom:storage-location erc7201:pool.b.storage
    struct StvStETHPoolStorage {
        mapping(address => uint256) mintedStethShares;
        uint256 totalMintedStethShares;
        uint256 reserveRatioBP;
        uint256 forcedRebalanceThresholdBP;
    }

    // keccak256(abi.encode(uint256(keccak256("pool.b.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STV_STETH_POOL_STORAGE_LOCATION =
        0x68280b7606a1a98bf19dd7ad4cb88029b355c2c81a554f53b998c73f934e4400;

    function _getStvStETHPoolStorage() internal pure returns (StvStETHPoolStorage storage $) {
        assembly {
            $.slot := STV_STETH_POOL_STORAGE_LOCATION
        }
    }

    constructor(
        address _dashboard,
        bool _allowListEnabled,
        uint256 _reserveRatioGapBP,
        address _withdrawalQueue
    ) BasePool(_dashboard, _allowListEnabled, _withdrawalQueue) {
        if (_reserveRatioGapBP >= TOTAL_BASIS_POINTS) revert InvalidReserveRatioGap(_reserveRatioGapBP);
        RESERVE_RATIO_GAP_BP = _reserveRatioGapBP;
    }

    function initialize(address _owner, string memory _name, string memory _symbol) public override initializer {
        _initializeBasePool(_owner, _name, _symbol);

        // Approve max stETH to the Dashboard for burning
        STETH.approve(address(DASHBOARD), type(uint256).max);

        // Sync reserve ratio and forced rebalance threshold from the VaultHub
        syncVaultParameters();
    }

    function wrapperType() external pure virtual override returns (string memory) {
        return "StvStETHPool";
    }

    // =================================================================================
    // DEPOSIT
    // =================================================================================

    /**
     * @notice Deposit native ETH and receive stv, optionally minting stETH shares
     * @param _receiver Address to receive the minted shares
     * @param _referral Address of the referral (if any)
     * @param _stethSharesToMint Amount of stETH shares to mint (up to maximum capacity for this deposit)
     *                           Pass MAX_MINTABLE_AMOUNT to mint maximum available for this deposit
     * @return stv Amount of stv minted
     */
    function depositETH(
        address _receiver,
        address _referral,
        uint256 _stethSharesToMint
    ) public payable virtual returns (uint256 stv) {
        stv = _deposit(_receiver, _referral);

        if (_stethSharesToMint > 0) {
            // If MAX_MINTABLE_AMOUNT is passed, calculate max mintable for this deposit
            uint256 sharesToMint = _stethSharesToMint == MAX_MINTABLE_AMOUNT
                ? calcStethSharesToMintForAssets(msg.value)
                : _stethSharesToMint;

            if (sharesToMint > 0) {
                _mintStethShares(_receiver, sharesToMint);
            }
        }
    }

    // =================================================================================
    // WITHDRAWALS
    // =================================================================================

    /**
     * @notice Calculate the amount of ETH that can be withdrawn by burning a specific amount of stETH shares
     * @param _account The address of the account
     * @param _stethSharesToBurn The amount of stETH shares to burn
     * @return ethAmount The amount of ETH that can be withdrawn (18 decimals)
     */
    function withdrawableEthOf(address _account, uint256 _stethSharesToBurn) public view returns (uint256 ethAmount) {
        uint256 mintedStethShares = mintedStethSharesOf(_account);
        if (mintedStethShares < _stethSharesToBurn) revert InsufficientStethShares();

        uint256 mintedStethSharesAfter = mintedStethShares - _stethSharesToBurn;
        uint256 minLockedAssetsAfter = calcAssetsToLockForStethShares(mintedStethSharesAfter);
        uint256 currentAssets = assetsOf(_account);
        ethAmount = Math.saturatingSub(currentAssets, minLockedAssetsAfter);
    }

    /**
     * @notice Calculate the amount of ETH that can be withdrawn by an account
     * @param _account The address of the account
     * @return ethAmount The amount of ETH that can be withdrawn (18 decimals)
     * @dev Overridden method to include locked assets
     */
    function withdrawableEthOf(address _account) public view override returns (uint256 ethAmount) {
        ethAmount = withdrawableEthOf(_account, 0);
    }

    /**
     * @notice Calculate the amount of stv that can be withdrawn by an account
     * @param _account The address of the account
     * @param _stethSharesToBurn The amount of stETH shares to burn
     * @return stv The amount of stv that can be withdrawn (18 decimals)
     */
    function withdrawableStvOf(address _account, uint256 _stethSharesToBurn) public view returns (uint256 stv) {
        stv = _convertToStv(withdrawableEthOf(_account, _stethSharesToBurn), Math.Rounding.Floor);
    }

    /**
     * @notice Calculate the amount of stv that can be withdrawn by an account
     * @param _account The address of the account
     * @return stv The amount of stv that can be withdrawn (18 decimals)
     * @dev Overridden method to include locked assets
     */
    function withdrawableStvOf(address _account) public view override returns (uint256 stv) {
        stv = withdrawableStvOf(_account, 0);
    }

    /**
     * @notice Calculate the amount of stETH shares required for a given amount of stv to withdraw
     * @param _stv The amount of stv to withdraw
     * @return stethShares The corresponding amount of stETH shares needed to burn (18 decimals)
     */
    function stethSharesForWithdrawal(address _account, uint256 _stv) public view returns (uint256 stethShares) {
        if (_stv == 0) return 0;

        uint256 currentBalance = balanceOf(_account);
        if (currentBalance < _stv) revert InsufficientBalance();

        uint256 balanceAfter = currentBalance - _stv;
        uint256 maxStethSharesAfter = calcStethSharesToMintForStv(balanceAfter);
        stethShares = Math.saturatingSub(mintedStethSharesOf(_account), maxStethSharesAfter);
    }

    /**
     * @notice Request a withdrawal by specifying the amount of stv to withdraw, burning stETH shares and rebalancing
     * @param _stvToWithdraw The amount of stv to withdraw (27 decimals)
     * @param _stethSharesToBurn The amount of stETH shares to burn to repay user's liabilities (18 decimals)
     * @param _stethSharesToRebalance The amount of stETH shares to rebalance (18 decimals)
     * @return requestId The ID of the withdrawal request
     */
    function requestWithdrawal(
        uint256 _stvToWithdraw,
        uint256 _stethSharesToBurn,
        uint256 _stethSharesToRebalance,
        address _receiver
    ) public virtual returns (uint256 requestId) {
        if (_stvToWithdraw == 0) revert BasePool.ZeroStv();

        if (_stethSharesToBurn > 0) {
            _burnStethShares(msg.sender, _stethSharesToBurn);
        }

        if (_stethSharesToRebalance > 0) {
            _checkMinStvToLock(_stvToWithdraw, _stethSharesToRebalance);
            _transferStethSharesLiability(msg.sender, address(WITHDRAWAL_QUEUE), _stethSharesToRebalance);
        }

        _transfer(msg.sender, address(WITHDRAWAL_QUEUE), _stvToWithdraw);
        address receiver = _receiver == address(0) ? msg.sender : _receiver;
        requestId = WITHDRAWAL_QUEUE.requestWithdrawal(_stvToWithdraw, _stethSharesToRebalance, receiver);
    }

    /**
     * @notice Request multiple withdrawals by specifying the amounts of stv to withdraw, burning stETH shares and rebalancing
     * @param _stvToWithdraw The array of amounts of stv to withdraw (27 decimals)
     * @param _stethSharesToBurn The amount of stETH shares to burn to repay user's liabilities (18 decimals)
     * @param _stethSharesToRebalance The array of amounts of stETH shares to rebalance (18 decimals)
     * @param _receiver The address to receive the claimed ether, or address(0)
     * @return requestIds The array of IDs of the created withdrawal requests
     */
    function requestWithdrawals(
        uint256[] calldata _stvToWithdraw,
        uint256[] calldata _stethSharesToRebalance,
        uint256 _stethSharesToBurn,
        address _receiver
    ) public virtual returns (uint256[] memory requestIds) {
        address receiver = _receiver == address(0) ? msg.sender : _receiver;

        if (_stethSharesToBurn > 0) {
            _burnStethShares(msg.sender, _stethSharesToBurn);
        }

        if (_stvToWithdraw.length != _stethSharesToRebalance.length) {
            revert ArraysLengthMismatch(_stvToWithdraw.length, _stethSharesToRebalance.length);
        }

        uint256 totalStvToTransfer;
        uint256 totalStethSharesToTransfer;

        for (uint256 i = 0; i < _stvToWithdraw.length; ++i) {
            if (_stethSharesToRebalance[i] > 0) {
                _checkMinStvToLock(_stvToWithdraw[i], _stethSharesToRebalance[i]);
                totalStethSharesToTransfer += _stethSharesToRebalance[i];
            }

            totalStvToTransfer += _stvToWithdraw[i];
        }

        if (totalStethSharesToTransfer > 0) {
            _transferStethSharesLiability(msg.sender, address(WITHDRAWAL_QUEUE), totalStethSharesToTransfer);
        }

        _transfer(msg.sender, address(WITHDRAWAL_QUEUE), totalStvToTransfer);
        requestIds = WITHDRAWAL_QUEUE.requestWithdrawals(_stvToWithdraw, _stethSharesToRebalance, receiver);
    }

    function _checkMinStvToLock(uint256 _stv, uint256 _stethShares) internal view {
        uint256 minStvAmountToLock = calcStvToLockForStethShares(_stethShares);
        if (_stv < minStvAmountToLock) revert InsufficientStv();
    }

    // =================================================================================
    // ASSETS
    // =================================================================================

    /**
     * @notice Total assets managed by the pool
     * @return assets Total assets (18 decimals)
     * @dev Includes total assets + total exceeding minted stETH
     */
    function totalAssets() public view override returns (uint256 assets) {
        uint256 exceedingMintedSteth = totalExceedingMintedSteth();

        /// total assets = nominal assets + exceeding minted steth - unassigned liability steth
        ///
        /// exceeding minted steth = minted steth on wrapper - liability on vault
        /// unassigned liability steth = liability on vault - minted steth on wrapper
        /// so only one of these values can be > 0 at any time
        if (exceedingMintedSteth > 0) {
            assets = totalNominalAssets() + exceedingMintedSteth;
        } else {
            assets = Math.saturatingSub(totalNominalAssets(), totalUnassignedLiabilitySteth());
        }
    }

    /**
     * @notice Assets of a specific account
     * @param _account The address of the account
     * @return assets Assets of the account (18 decimals)
     */
    function assetsOf(address _account) public view override returns (uint256 assets) {
        /// As a result of the rebalancing initiated in the Staking Vault, bypassing the Wrapper,
        /// part of the total liability can be reduced at the expense of the Staking Vault's assets.
        ///
        /// As a result of this operation, the total liabilityShares on the Staking Vault will decrease,
        /// while mintedStethShares will remain the same, as will the users' debts on these obligations.
        /// The difference between these two values is the stETH that users owe to Wrapper, but which
        /// should not be returned to Staking Vault, but should be distributed among all participants
        /// in exchange for the withdrawn ETH.
        ///
        /// Thus, in rare situations, Staking Vault may have two assets: ETH and stETH, which are
        /// distributed among all users in proportion to their shares.
        assets = _convertToAssets(balanceOf(_account));
    }

    // =================================================================================
    // MINTED STETH SHARES
    // =================================================================================

    /**
     * @notice Total stETH shares minted by the pool
     * @return stethShares Total stETH shares minted (18 decimals)
     */
    function totalMintedStethShares() public view returns (uint256 stethShares) {
        stethShares = _getStvStETHPoolStorage().totalMintedStethShares;
    }

    /**
     * @notice Amount of stETH shares minted by the pool for a specific account
     * @param _account The address of the account
     * @return stethShares Amount of stETH shares minted (18 decimals)
     */
    function mintedStethSharesOf(address _account) public view returns (uint256 stethShares) {
        stethShares = _getStvStETHPoolStorage().mintedStethShares[_account];
    }

    /**
     * @notice Total Staking Vault minting capacity in stETH shares
     * @return stethShares Total minting capacity in stETH shares
     */
    function totalMintingCapacityShares() public view returns (uint256 stethShares) {
        stethShares = DASHBOARD.totalMintingCapacityShares();
    }

    /**
     * @notice Remaining Staking Vault minting capacity in stETH shares
     * @return stethShares Remaining minting capacity in stETH shares
     * @dev Can be limited by Vault's max capacity
     */
    function remainingMintingCapacityShares(uint256 _ethToFund) public view returns (uint256 stethShares) {
        stethShares = DASHBOARD.remainingMintingCapacityShares(_ethToFund);
    }

    /**
     * @notice Calculate the minting capacity in stETH shares for a specific account
     * @param _account The address of the account
     * @return stethSharesCapacity The minting capacity in stETH shares
     */
    function mintingCapacitySharesOf(address _account) public view returns (uint256 stethSharesCapacity) {
        uint256 stethSharesForAssets = calcStethSharesToMintForAssets(assetsOf(_account));
        stethSharesCapacity = Math.saturatingSub(stethSharesForAssets, mintedStethSharesOf(_account));
    }

    /**
     * @notice Mint stETH shares up to the user's minting capacity
     * @param _stethShares The amount of stETH shares to mint
     */
    function mintStethShares(uint256 _stethShares) public {
        _mintStethShares(msg.sender, _stethShares);
    }

    function _mintStethShares(address _account, uint256 _stethShares) internal {
        if (_stethShares == 0) revert ZeroArgument();
        if (mintingCapacitySharesOf(_account) < _stethShares) revert InsufficientMintingCapacity();

        DASHBOARD.mintShares(_account, _stethShares);

        StvStETHPoolStorage storage $ = _getStvStETHPoolStorage();
        $.totalMintedStethShares += _stethShares;
        $.mintedStethShares[_account] += _stethShares;

        emit StethSharesMinted(_account, _stethShares);
    }

    /**
     * @notice Burn stETH shares to reduce the user's minted stETH obligation
     * @param _stethShares The amount of stETH shares to burn
     */
    function burnStethShares(uint256 _stethShares) public {
        _burnStethShares(msg.sender, _stethShares);
    }

    function _burnStethShares(address _account, uint256 _stethShares) internal {
        _decreaseMintedStethShares(_account, _stethShares);

        STETH.transferSharesFrom(_account, address(this), _stethShares);
        DASHBOARD.burnShares(_stethShares);
    }

    function _decreaseMintedStethShares(address _account, uint256 _stethShares) internal {
        StvStETHPoolStorage storage $ = _getStvStETHPoolStorage();

        if (_stethShares == 0) revert ZeroArgument();
        if ($.mintedStethShares[_account] < _stethShares) revert InsufficientMintedShares();

        $.totalMintedStethShares -= _stethShares;
        $.mintedStethShares[_account] -= _stethShares;

        emit StethSharesBurned(_account, _stethShares);
    }

    function _transferStethSharesLiability(address _from, address _to, uint256 _stethShares) internal {
        StvStETHPoolStorage storage $ = _getStvStETHPoolStorage();

        if (_stethShares == 0) revert ZeroArgument();
        if ($.mintedStethShares[_from] < _stethShares) revert InsufficientMintedShares();

        $.mintedStethShares[_from] -= _stethShares;
        $.mintedStethShares[_to] += _stethShares;

        emit StethSharesBurned(_from, _stethShares);
        emit StethSharesMinted(_to, _stethShares);
    }

    /**
     * @notice Calculate the amount of stETH shares to mint for a given amount of assets
     * @param _assets The amount of assets (18 decimals)
     * @return stethShares The corresponding amount of stETH shares to mint (18 decimals)
     */
    function calcStethSharesToMintForAssets(uint256 _assets) public view returns (uint256 stethShares) {
        uint256 maxStethToMint = Math.mulDiv(
            _assets,
            TOTAL_BASIS_POINTS - reserveRatioBP(),
            TOTAL_BASIS_POINTS,
            Math.Rounding.Floor
        );

        stethShares = STETH.getSharesByPooledEth(maxStethToMint);
    }

    /**
     * @notice Calculate the amount of stETH shares to mint for a given amount of stv
     * @param _stv The amount of stv (27 decimals)
     * @return stethShares The corresponding amount of stETH shares to mint (18 decimals)
     */
    function calcStethSharesToMintForStv(uint256 _stv) public view returns (uint256 stethShares) {
        stethShares = calcStethSharesToMintForAssets(_convertToAssets(_stv));
    }

    /**
     * @notice Calculate the min amount of assets to lock for a given amount of stETH shares
     * @param _stethShares The amount of stETH shares (18 decimals)
     * @return assetsToLock The min amount of assets to lock (18 decimals)
     * @dev Use the ceiling rounding to ensure enough assets are locked
     */
    function calcAssetsToLockForStethShares(uint256 _stethShares) public view returns (uint256 assetsToLock) {
        if (_stethShares == 0) return 0;

        assetsToLock = Math.mulDiv(
            STETH.getPooledEthBySharesRoundUp(_stethShares),
            TOTAL_BASIS_POINTS,
            TOTAL_BASIS_POINTS - reserveRatioBP(),
            Math.Rounding.Ceil
        );
    }

    /**
     * @notice Calculate the min amount of stv to lock for a given amount of stETH shares
     * @param _stethShares The amount of stETH shares (18 decimals)
     * @return stvToLock The min amount of stv to lock (27 decimals)
     */
    function calcStvToLockForStethShares(uint256 _stethShares) public view returns (uint256 stvToLock) {
        uint256 assetsToLock = calcAssetsToLockForStethShares(_stethShares);
        stvToLock = _convertToStv(assetsToLock, Math.Rounding.Ceil);
    }

    // =================================================================================
    // VAULT PARAMETERS
    // =================================================================================

    /**
     * @notice Reserve ratio in basis points with the gap applied
     * @return reserveRatio The reserve ratio in basis points
     */
    function reserveRatioBP() public view returns (uint256 reserveRatio) {
        reserveRatio = _getStvStETHPoolStorage().reserveRatioBP;
    }

    /**
     * @notice Forced rebalance threshold in basis points
     * @return threshold The forced rebalance threshold in basis points
     */
    function forcedRebalanceThresholdBP() public view returns (uint256 threshold) {
        threshold = _getStvStETHPoolStorage().forcedRebalanceThresholdBP;
    }

    /**
     * @notice Sync reserve ratio and forced rebalance threshold from VaultHub
     * @dev Permissionless method to keep reserve ratio and forced rebalance threshold in sync with VaultHub
     * @dev Adds a gap defined by RESERVE_RATIO_GAP_BP to VaultHub's values
     * @dev Reverts if the new reserve ratio or forced rebalance threshold is invalid (>= TOTAL_BASIS_POINTS)
     */
    function syncVaultParameters() public {
        IVaultHub.VaultConnection memory connection = DASHBOARD.vaultConnection();

        uint256 maxReserveRatioBP = TOTAL_BASIS_POINTS - 1;

        /// Invariants from the OperatorGrid
        assert(connection.reserveRatioBP > 0);
        assert(connection.reserveRatioBP <= maxReserveRatioBP);
        assert(connection.forcedRebalanceThresholdBP > 0);
        assert(connection.forcedRebalanceThresholdBP <= connection.reserveRatioBP);

        uint256 newReserveRatioBP = Math.min(connection.reserveRatioBP + RESERVE_RATIO_GAP_BP, maxReserveRatioBP);
        uint256 newThresholdBP = Math.min(
            connection.forcedRebalanceThresholdBP + RESERVE_RATIO_GAP_BP,
            maxReserveRatioBP
        );

        StvStETHPoolStorage storage $ = _getStvStETHPoolStorage();

        if (newReserveRatioBP == $.reserveRatioBP && newThresholdBP == $.forcedRebalanceThresholdBP) return;

        $.reserveRatioBP = newReserveRatioBP;
        $.forcedRebalanceThresholdBP = newThresholdBP;

        emit VaultParametersUpdated(newReserveRatioBP, newThresholdBP);
    }

    // =================================================================================
    // EXCEEDING MINTED STETH
    // =================================================================================

    /**
     * @notice Amount of minted stETH shares exceeding the Staking Vault's liability
     * @return stethShares Amount of exceeding stETH shares (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function totalExceedingMintedStethShares() public view returns (uint256 stethShares) {
        stethShares = Math.saturatingSub(totalMintedStethShares(), DASHBOARD.liabilityShares());
    }

    /**
     * @notice Amount of minted stETH exceeding the Staking Vault's liability
     * @return steth Amount of exceeding stETH (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function totalExceedingMintedSteth() public view override returns (uint256 steth) {
        steth = STETH.getPooledEthByShares(totalExceedingMintedStethShares());
    }

    /**
     * @notice Amount of stETH shares exceeding the Staking Vault's liability for a specific account
     * @param _account The address of the account
     * @return stethShares Amount of exceeding stETH shares (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function exceedingMintedStethSharesOf(address _account) public view returns (uint256 stethShares) {
        uint256 totalExceeding = totalExceedingMintedStethShares();
        uint256 totalSupply = totalSupply();

        if (totalExceeding == 0 || totalSupply == 0) return 0;
        stethShares = Math.mulDiv(totalExceeding, balanceOf(_account), totalSupply, Math.Rounding.Floor);
    }

    /**
     * @notice Amount of stETH exceeding the Staking Vault's liability for a specific account
     * @param _account The address of the account
     * @return steth Amount of exceeding stETH (18 decimals)
     * @dev May occur if rebalancing happens on the Staking Vault bypassing the Wrapper
     */
    function exceedingMintedStethOf(address _account) public view returns (uint256 steth) {
        steth = STETH.getPooledEthByShares(exceedingMintedStethSharesOf(_account));
    }

    // =================================================================================
    // UNASSIGNED LIABILITY
    // =================================================================================

    /**
     * @notice Total unassigned liability shares in the Staking Vault
     * @return unassignedLiabilityShares Total unassigned liability shares (18 decimals)
     * @dev Overridden method from BasePool to include unassigned liability shares
     * @dev May occur if liability was transferred from another Staking Vault
     */
    function totalUnassignedLiabilityShares() public view override returns (uint256 unassignedLiabilityShares) {
        unassignedLiabilityShares = Math.saturatingSub(DASHBOARD.liabilityShares(), totalMintedStethShares());
    }

    // =================================================================================
    // REBALANCE
    // =================================================================================

    /**
     * @notice Rebalance the user's minted stETH shares by burning stv
     * @param _stethShares The amount of stETH shares to rebalance
     * @param _maxStvToBurn The maximum amount of stv to burn for rebalancing
     * @return stvBurned The actual amount of stv burned for rebalancing
     * @dev First, rebalances internally by burning stv, which decreases exceeding shares (if any)
     * @dev Second, if there are remaining liability shares, rebalances Staking Vault
     * @dev Requires fresh oracle report, which is checked in the Withdrawal Queue
     */
    function rebalanceMintedStethShares(
        uint256 _stethShares,
        uint256 _maxStvToBurn
    ) public returns (uint256 stvBurned) {
        _checkOnlyWithdrawalQueue();
        stvBurned = _rebalanceMintedStethShares(msg.sender, _stethShares, _maxStvToBurn);
    }

    /**
     * @notice Force rebalance the user's minted stETH shares if the reserve ratio threshold is breached
     * @param _account The address of the account to rebalance
     * @return stvBurned The actual amount of stv burned for rebalancing
     * @dev Permissionless method to rebalance any account that breached the health threshold
     * @dev Requires fresh oracle report to price stv accurately
     */
    function forceRebalance(address _account) public returns (uint256 stvBurned) {
        (uint256 stethShares, uint256 stv, bool isUndercollateralized) = previewForceRebalance(_account);

        if (stethShares == 0) revert NothingToRebalance();
        if (isUndercollateralized) revert UndercollateralizedAccount();

        stvBurned = _rebalanceMintedStethShares(_account, stethShares, stv);
    }

    /**
     * @notice Force rebalance undercollateralized account and socialize the remaining loss to all pool participants
     * @param _account The address of the account to rebalance
     * @return stvBurned The actual amount of stv burned for rebalancing
     * @dev Requires fresh oracle report to price stv accurately
     */
    function forceRebalanceAndSocializeLoss(address _account) public returns (uint256 stvBurned) {
        _checkRole(LOSS_SOCIALIZER_ROLE, msg.sender);

        (uint256 stethShares, uint256 stv, bool isUndercollateralized) = previewForceRebalance(_account);
        if (!isUndercollateralized) revert CollateralizedAccount();

        stvBurned = _rebalanceMintedStethShares(_account, stethShares, stv);
    }

    /**
     * @notice Preview the amount of stETH shares and stv needed to force rebalance the user's position
     * @param _account The address of the account to preview
     * @return stethShares The amount of stETH shares to rebalance, limited by available assets
     * @return stv The amount of stv needed to burn in exchange for the stETH shares, limited by user's stv balance
     * @return isUndercollateralized True if the user's assets are insufficient to cover the liability
     * @dev Requires fresh oracle report to price stv accurately
     */
    function previewForceRebalance(
        address _account
    ) public view returns (uint256 stethShares, uint256 stv, bool isUndercollateralized) {
        _checkFreshReport();

        uint256 stethSharesLiability = mintedStethSharesOf(_account);
        uint256 stvBalance = balanceOf(_account);
        uint256 assets = assetsOf(_account);

        /// Position is healthy, nothing to rebalance
        if (!_isThresholdBreached(assets, stethSharesLiability)) return (0, 0, false);

        /// Rebalance (swap steth liability for stv at the current rate) user to the reserve ratio level
        ///
        /// To calculate how much eth to rebalance to reach the target reserve ratio, we can set up the equation:
        /// (1 - reserveRatio) = (liability - x) / (assets - x)
        ///
        /// Rearranging the equation to solve for x gives us:
        /// x = (liability - (1 - reserveRatio) * assets) / reserveRatio
        uint256 reserveRatioBP_ = reserveRatioBP();
        uint256 stethLiability = STETH.getPooledEthBySharesRoundUp(stethSharesLiability);
        uint256 targetStethToRebalance = Math.ceilDiv(
            /// Shouldn't underflow as threshold breach is already checked
            stethLiability * TOTAL_BASIS_POINTS - (TOTAL_BASIS_POINTS - reserveRatioBP_) * assets,
            reserveRatioBP_
        );

        /// If the target rebalance amount exceeds the liability itself, the user is undercollateralized
        if (targetStethToRebalance > stethLiability) {
            targetStethToRebalance = stethLiability;
            isUndercollateralized = true;
        }

        /// Limit rebalance to available assets
        ///
        /// First, the rebalancing will use exceeding minted steth, bringing the vault closer to minted steth == liability,
        /// then the rebalancing mechanism on the vault, which is limited by available balance in the staking vault
        uint256 stethToRebalance = totalExceedingMintedSteth() + STAKING_VAULT.availableBalance();
        stethToRebalance = Math.min(targetStethToRebalance, stethToRebalance);

        uint256 stvRequired = _convertToStv(stethToRebalance, Math.Rounding.Ceil);

        stethShares = STETH.getSharesByPooledEth(stethToRebalance); // TODO: round up, can it exceed liability?
        stv = Math.min(stvRequired, stvBalance);
        isUndercollateralized = isUndercollateralized || stvRequired > stvBalance;
    }

    /**
     * @notice Check if the user's minted stETH shares are healthy (not breaching the threshold)
     * @param _account The address of the account to check
     * @return isHealthy True if the account is healthy, false if the forced rebalance threshold is breached
     */
    function isHealthyOf(address _account) public view returns (bool isHealthy) {
        isHealthy = !_isThresholdBreached(assetsOf(_account), mintedStethSharesOf(_account));
    }

    /**
     * @dev Requires fresh oracle report to price stv accurately
     */
    function _rebalanceMintedStethShares(
        address _account,
        uint256 _stethShares,
        uint256 _maxStvToBurn
    ) internal returns (uint256 stvToBurn) {
        if (_stethShares == 0) revert ZeroArgument();
        if (_stethShares > mintedStethSharesOf(_account)) revert InsufficientMintedShares();

        uint256 exceedingStethShares = totalExceedingMintedStethShares();
        uint256 remainingStethShares = Math.saturatingSub(_stethShares, exceedingStethShares);
        uint256 ethToRebalance = STETH.getPooledEthBySharesRoundUp(_stethShares);
        stvToBurn = _convertToStv(ethToRebalance, Math.Rounding.Ceil);

        if (remainingStethShares > 0) DASHBOARD.rebalanceVaultWithShares(remainingStethShares);

        // TODO: Add sanity check for loss socialization
        if (stvToBurn > _maxStvToBurn) {
            emit SocializedLoss(stvToBurn - _maxStvToBurn, ethToRebalance - _convertToAssets(_maxStvToBurn));
            stvToBurn = _maxStvToBurn;
        }

        emit StethSharesRebalanced(_account, _stethShares, stvToBurn);

        _decreaseMintedStethShares(_account, _stethShares);
        _burnUnsafe(_account, stvToBurn);
    }

    function _isThresholdBreached(uint256 _assets, uint256 _stethShares) internal view returns (bool isBreached) {
        if (_stethShares == 0) return false;

        uint256 assetsThreshold = Math.mulDiv(
            STETH.getPooledEthBySharesRoundUp(_stethShares),
            TOTAL_BASIS_POINTS,
            TOTAL_BASIS_POINTS - forcedRebalanceThresholdBP(),
            Math.Rounding.Ceil
        );

        isBreached = _assets < assetsThreshold;
    }

    function _checkFreshReport() internal view {
        if (!VAULT_HUB.isReportFresh(address(STAKING_VAULT))) revert VaultReportStale();
    }

    // =================================================================================
    // TRANSFER WITH LIABILITY
    // =================================================================================

    /**
     * @notice Transfer stv along with stETH shares liability
     * @param _to The address to transfer to
     * @param _stv The amount of stv to transfer
     * @param _stethShares The amount of stETH shares liability to transfer
     * @return success True if the transfer was successful
     * @dev Ensures that the transferred stv covers the minimum required to lock for the transferred stETH shares liability
     */
    function transferWithLiability(address _to, uint256 _stv, uint256 _stethShares) public returns (bool success) {
        _checkMinStvToLock(_stv, _stethShares);

        _transferStethSharesLiability(msg.sender, _to, _stethShares);
        _transfer(msg.sender, _to, _stv);
        success = true;
    }

    // =================================================================================
    // ERC20 OVERRIDES
    // =================================================================================

    /**
     * @dev Overridden method from ERC20 to include reserve ratio check
     * @dev Ensures that after any transfer, the sender still has enough reserved balance for their minted stETH shares
     */
    function _update(address _from, address _to, uint256 _value) internal override {
        super._update(_from, _to, _value);

        // Skip checks for burning from Withdrawal Queue
        if (_from == address(WITHDRAWAL_QUEUE) && _to == address(0)) return;

        uint256 mintedStethShares = mintedStethSharesOf(_from);
        if (mintedStethShares == 0) return;

        uint256 stvToLock = calcStvToLockForStethShares(mintedStethShares);

        if (balanceOf(_from) < stvToLock) revert InsufficientReservedBalance();
    }

    /**
     * @dev Unsafe burn that skips reserved balance check
     */
    function _burnUnsafe(address _account, uint256 _value) internal {
        if (_account == address(0)) revert ERC20InvalidSender(address(0));
        super._update(_account, address(0), _value);
    }
}
