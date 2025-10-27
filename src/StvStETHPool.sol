// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {BasePool} from "./BasePool.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {WithdrawalQueue} from "./WithdrawalQueue.sol";

import {IStETH} from "./interfaces/IStETH.sol";

/**
 * @title StvStETHPool
 * @notice Configuration B: Minting, no strategy - stv + maximum stETH minting for user
 */
contract StvStETHPool is BasePool {
    using EnumerableSet for EnumerableSet.UintSet;

    event StethSharesMinted(address indexed account, uint256 stethShares);
    event StethSharesBurned(address indexed account, uint256 stethShares);
    event StethSharesRebalanced(uint256 stethShares, uint256 stvBurned);
    event SocializedLoss(uint256 stv, uint256 assets);

    error InsufficientMintingCapacity();
    error InsufficientStethShares();
    error InsufficientBalance();
    error InsufficientReservedBalance();
    error InsufficientMintedShares();
    error InsufficientStv();
    error ZeroArgument();
    error MintingForThanTargetStSharesShareIsNotAllowed();
    error ArraysLengthMismatch(uint256 firstArrayLength, uint256 secondArrayLength);

    uint256 public immutable WRAPPER_RR_BP; // vault's reserve ratio plus gap for pool

    /// @notice Sentinel value for depositETH to mint maximum available stETH shares for the deposit
    uint256 public constant MAX_MINTABLE_AMOUNT = type(uint256).max;

    /// @custom:storage-location erc7201:pool.b.storage
    struct StvStETHPoolStorage {
        mapping(address => uint256) mintedStethShares;
        uint256 totalMintedStethShares;
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
        address _withdrawalQueue,
        address _distributor
    ) BasePool(_dashboard, _allowListEnabled, _withdrawalQueue, _distributor) {
        uint256 vaultRR = DASHBOARD.vaultConnection().reserveRatioBP;
        require(_reserveRatioGapBP < TOTAL_BASIS_POINTS - vaultRR, "Reserve ratio gap too high");
        WRAPPER_RR_BP = vaultRR + _reserveRatioGapBP;
    }

    function initialize(
        address _owner,
        string memory _name,
        string memory _symbol
    ) public override initializer {
        _initializeBasePool(_owner, _name, _symbol);

        // Approve max stETH to the Dashboard for burning
        STETH.approve(address(DASHBOARD), type(uint256).max);
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
        assets = nominalAssetsOf(_account) + exceedingMintedStethOf(_account);
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
            TOTAL_BASIS_POINTS - WRAPPER_RR_BP,
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
        uint256 steth = STETH.getPooledEthBySharesRoundUp(_stethShares);
        assetsToLock = Math.mulDiv(steth, TOTAL_BASIS_POINTS, TOTAL_BASIS_POINTS - WRAPPER_RR_BP, Math.Rounding.Ceil);
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
     * @return stvToBurn The actual amount of stv burned for rebalancing
     * @dev First, rebalances internally by burning stv, which decreases exceeding shares (if any)
     * @dev Second, if there are remaining liability shares, rebalances Staking Vault
     * @dev Requires fresh oracle report, which is checked in the Withdrawal Queue
     */
    function rebalanceMintedStethShares(
        uint256 _stethShares,
        uint256 _maxStvToBurn
    ) public returns (uint256 stvToBurn) {
        _checkOnlyWithdrawalQueue();

        if (_stethShares == 0) revert ZeroArgument();
        if (_stethShares > mintedStethSharesOf(msg.sender)) revert InsufficientMintedShares();

        uint256 exceedingStethShares = totalExceedingMintedStethShares();
        uint256 remainingStethShares = Math.saturatingSub(_stethShares, exceedingStethShares);

        if (remainingStethShares > 0) DASHBOARD.rebalanceVaultWithShares(remainingStethShares);

        uint256 ethToRebalance = STETH.getPooledEthBySharesRoundUp(_stethShares);
        stvToBurn = _convertToStv(ethToRebalance, Math.Rounding.Ceil);

        if (stvToBurn > _maxStvToBurn) {
            emit SocializedLoss(stvToBurn - _maxStvToBurn, ethToRebalance - _convertToAssets(_maxStvToBurn));
            stvToBurn = _maxStvToBurn;
        }

        emit StethSharesRebalanced(_stethShares, stvToBurn);

        _decreaseMintedStethShares(msg.sender, _stethShares);
        _burn(msg.sender, stvToBurn);
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

    // TODO: force rebalance for specific user
}
